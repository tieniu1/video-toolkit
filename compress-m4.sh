#!/bin/bash
set -euo pipefail

# ================= 配置区域 =================
# 并发数：M4 媒体引擎建议设为 3，过高会拥堵
PARALLEL="${PARALLEL:-2}"
# 默认模式：speed (极致体积，针对直播录屏优化)
MODE="${MODE:-speed}"
# 最大高度：竖屏建议 1280 (即 720p)，横屏建议 720
MAX_HEIGHT="${MAX_HEIGHT:-960}"
# 音频码率：单声道 48k 足够清晰
AUDIO_BITRATE="${AUDIO_BITRATE:-48k}"
# ===========================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"
OUTPUT_DIR="$SCRIPT_DIR/compress/output"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# 检测是否为 Apple Silicon M 系列芯片环境
detect_encoder() {
  local encoders
  encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
  if echo "$encoders" | grep -q "hevc_videotoolbox"; then
    echo "hevc_videotoolbox"
  else
    # 非 M 芯片回退到 CPU 编码（极慢，不建议用此脚本）
    echo "libx264"
  fi
}

ENCODER="${ENCODER:-$(detect_encoder)}"

# 构建视频编码参数 (核心优化部分)
build_vcodec_args() {
  case "$ENCODER" in
    hevc_videotoolbox)
      # 核心逻辑解释：
      # 1. -q:v 38: 这是一个“狠”参数。
      #    - 对 VID：它会把码率压得很低 (约1000k)，维持 90% 的压缩率。
      #    - 对 SVID：因为它基于质量，遇到简单的录屏画面，它会自动降到 500k，确保也能压缩。
      # 2. -g 120: 5秒一个关键帧，专门利用“直播/口播背景不动”的特性，疯狂省空间。
      # 3. -maxrate 2M: 还是加一个上限锁，防止个别复杂镜头体积失控。
      echo "-c:v hevc_videotoolbox -q:v 38 -maxrate 2M -profile:v main -tag:v hvc1 -allow_sw 1 -g 120"
      ;;
    libx264)
      echo "-c:v libx264 -preset veryfast -crf 28"
      ;;
  esac
}
# 压缩VID开头视频可以达到90%，压缩SVID不太行。
# build_vcodec_args() {
#   case "$ENCODER" in
#     hevc_videotoolbox)
#       echo "-c:v hevc_videotoolbox -b:v 1200k -maxrate 1800k -bufsize 3600k -profile:v main -tag:v hvc1 -allow_sw 1"
#       ;;
#     libx264)
#       echo "-c:v libx264 -preset veryfast -crf 28"
#       ;;
#   esac
# }

# 构建音频编码参数 (强制单声道)
build_audio_args() {
  # 优先使用 macOS 原生 aac_at 编码器
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "aac_at"; then
    # -ac 1: 强制单声道，人声不需要立体声，节省体积
    echo "-c:a aac_at -b:a $AUDIO_BITRATE -ac 1"
  else
    echo "-c:a aac -b:a $AUDIO_BITRATE -ac 1"
  fi
}

# 构建视频滤镜 (缩放 + 降帧 + 锐化)
build_video_filter() {
  local input_path="$1"
  local filters=()
  
  local height
  height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input_path" 2>/dev/null)
  height="${height%%.*}"

  # 1. 智能缩放
  # 如果原视频高度超过限制 (例如竖屏 1920 > 1280)，则缩小
  if [ "$MAX_HEIGHT" -gt 0 ] 2>/dev/null && [ -n "$height" ] && [ "$height" -gt "$MAX_HEIGHT" ] 2>/dev/null; then
    filters+=("scale=-2:${MAX_HEIGHT}:flags=lanczos")
  fi

  # 2. 强制降帧到 24fps
  # 直播流往往帧率不稳定，统一到 24 既流畅又省空间
  filters+=("fps=24")

  local joined
  joined=$(IFS=,; echo "${filters[*]}")
  echo "-vf $joined"
}

format_size() {
  awk "BEGIN{printf \"%.2f\", $1/1048576}"
}

compress_one() {
  local filename="$1"
  local input_path="$INPUT_DIR/$filename"
  local name="${filename%.*}"
  # 输出文件名包含标识，方便区分
  local output_path="$OUTPUT_DIR/${name}_m4_opt.mp4"

  if [ ! -f "$input_path" ]; then
    echo "❌ [$filename] 错误: 文件不存在"
    return 1
  fi
  
  # 如果输出文件已存在且大小正常，跳过
  if [ -s "$output_path" ]; then
    echo "⏭️  [$filename] 跳过 (已存在)"
    return 0
  fi

  local in_size
  in_size=$(stat -f '%z' "$input_path" 2>/dev/null || stat -c '%s' "$input_path" 2>/dev/null)

  local vcodec_args
  vcodec_args=$(build_vcodec_args)
  
  local acodec_args
  acodec_args=$(build_audio_args)
  
  local vf_args
  vf_args=$(build_video_filter "$input_path")

  echo "🔥 [$filename] M4 引擎全开..."
  echo "   参数: 模式=$MODE | 高度<=$MAX_HEIGHT | 24fps | 单声道"

  local tmp_output="${output_path}.tmp.mp4"

  # 开始压缩
  # -map_metadata 0: 保留基本元数据
  # -movflags +faststart: 优化网络播放
  if ffmpeg -y -v error -stats -i "$input_path" \
    $vcodec_args \
    $vf_args \
    $acodec_args \
    -map_metadata 0 \
    -movflags +faststart \
    "$tmp_output" < /dev/null; then
      
      mv "$tmp_output" "$output_path"
      
      local out_size
      out_size=$(stat -f '%z' "$output_path" 2>/dev/null || stat -c '%s' "$output_path" 2>/dev/null)
      local ratio
      ratio=$(awk "BEGIN{printf \"%.1f\", (1-$out_size/$in_size)*100}")
      
      echo "✅ [$filename] 搞定! $(format_size "$in_size")MB → $(format_size "$out_size")MB (瘦身 ${ratio}%)"
  else
      echo "❌ [$filename] 压缩失败，请检查源文件"
      rm -f "$tmp_output"
      return 1
  fi
}

export -f compress_one format_size build_video_filter build_vcodec_args build_audio_args
export INPUT_DIR OUTPUT_DIR ENCODER AUDIO_BITRATE MAX_HEIGHT MODE

if [ "${1:-}" = "--all" ]; then
  start_ts=$(date +%s)
  
  # 查找视频文件
  shopt -s nullglob
  files=()
  for f in "$INPUT_DIR"/*.{mp4,MP4,mov,MOV,mkv,MKV}; do
    files+=("$(basename "$f")")
  done
  shopt -u nullglob

  if [ ${#files[@]} -eq 0 ]; then
    echo "📂 compress/input/ 目录下没有找到视频文件"
    exit 1
  fi

  echo "========================================="
  echo "🚀 M4 直播录屏专用压缩"
  echo "处理文件: ${#files[@]} 个 | 并行数: $PARALLEL"
  echo "========================================="

  printf '%s\n' "${files[@]}" | xargs -P "$PARALLEL" -I {} bash -c 'compress_one "$@"' _ {}

  end_ts=$(date +%s)
  cost=$((end_ts - start_ts))
  echo ""
  echo "🎉 全部完成! 总耗时: $((cost/60))分$((cost%60))秒"
else
  [ $# -lt 1 ] && { echo "用法: $0 <文件名> 或 $0 --all"; exit 1; }
  compress_one "$1"
fi
