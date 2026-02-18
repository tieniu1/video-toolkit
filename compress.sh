#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"
OUTPUT_DIR="$SCRIPT_DIR/compress/output"
PARALLEL="${PARALLEL:-4}"
MODE="${MODE:-balanced}"
MAX_HEIGHT="${MAX_HEIGHT:-960}"
TARGET_FPS="${TARGET_FPS:-30}"
CRF="${CRF:-28}"
X265_PRESET="${X265_PRESET:-medium}"
AUDIO_BITRATE="${AUDIO_BITRATE:-80k}"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

detect_encoder() {
  local encoders
  encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
  case "$MODE" in
    speed|balanced)
      if echo "$encoders" | grep -q "hevc_videotoolbox"; then
        echo "hevc_videotoolbox"
      elif echo "$encoders" | grep -q "h264_videotoolbox"; then
        echo "h264_videotoolbox"
      elif echo "$encoders" | grep -q "libx264"; then
        echo "libx264"
      elif echo "$encoders" | grep -q "libx265"; then
        echo "libx265"
      else
        echo "libx264"
      fi
      ;;
    quality|*)
      if echo "$encoders" | grep -q "libx265"; then
        echo "libx265"
      elif echo "$encoders" | grep -q "hevc_videotoolbox"; then
        echo "hevc_videotoolbox"
      elif echo "$encoders" | grep -q "libx264"; then
        echo "libx264"
      elif echo "$encoders" | grep -q "h264_videotoolbox"; then
        echo "h264_videotoolbox"
      else
        echo "libx264"
      fi
      ;;
  esac
}

ENCODER="${ENCODER:-$(detect_encoder)}"

build_vcodec_args() {
  local target_br="1200k" max_br="1800k" buf="2400k"
  case "$MODE" in
    speed) target_br="900k" max_br="1300k" buf="1800k" ;;
    balanced) target_br="1300k" max_br="2M" buf="2600k" ;;
    quality) target_br="1600k" max_br="2500k" buf="3200k" ;;
    *) target_br="1300k" max_br="2M" buf="2600k" ;;
  esac

  case "$ENCODER" in
    hevc_videotoolbox)
      echo "-c:v hevc_videotoolbox -b:v $target_br -maxrate $max_br -bufsize $buf -tag:v hvc1 -allow_sw 1" ;;
    h264_videotoolbox)
      echo "-c:v h264_videotoolbox -b:v $target_br -maxrate $max_br -bufsize $buf -allow_sw 1" ;;
    libx265)
      echo "-c:v libx265 -preset $X265_PRESET -crf $CRF -tag:v hvc1 -pix_fmt yuv420p" ;;
    libx264)
      if [ "$MODE" = "speed" ]; then
        echo "-c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p"
      elif [ "$MODE" = "balanced" ]; then
        echo "-c:v libx264 -preset faster -crf 26 -pix_fmt yuv420p"
      else
        echo "-c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p"
      fi
      ;;
  esac
}

build_fallback_vcodec_args() {
  echo "-c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p"
}

build_video_filter() {
  local input_path="$1"
  local filters=()
  local height
  height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input_path" 2>/dev/null)
  height="${height%%.*}"

  if [ "$MAX_HEIGHT" -gt 0 ] 2>/dev/null && [ -n "$height" ] && [ "$height" -gt "$MAX_HEIGHT" ] 2>/dev/null; then
    filters+=("scale=-2:${MAX_HEIGHT}:flags=lanczos")
  fi

  if [ "$TARGET_FPS" -gt 0 ] 2>/dev/null; then
    filters+=("fps=${TARGET_FPS}")
  fi

  if [ "${#filters[@]}" -gt 0 ]; then
    local joined
    joined=$(IFS=,; echo "${filters[*]}")
    echo "-vf $joined"
  fi
}

usage() {
  echo "用法:"
  echo "  ./compress.sh <文件名>     压缩单个视频"
  echo "  ./compress.sh --all        压缩 compress/input/ 下所有视频"
  echo ""
  echo "环境变量:"
  echo "  PARALLEL=N      并行数 (默认 4)"
  echo "  MODE=quality|balanced|speed   压缩模式 (默认 balanced)"
  echo "  CRF=N           libx265 的 CRF (默认 28, 越大越小但越糊)"
  echo "  X265_PRESET=slow|medium|fast  libx265 预设 (默认 medium)"
  echo "  MAX_HEIGHT=N    最大高度，0 表示不缩放 (默认 960)"
  echo "  TARGET_FPS=N    目标帧率，0 表示不改帧率 (默认 30)"
  echo "  AUDIO_BITRATE=64k|80k|96k|128k    音频码率 (默认 80k)"
  echo "  ENCODER=...     强制指定编码器 (可选)"
  echo ""
  echo "编码器: $ENCODER"
  exit 1
}

[ $# -lt 1 ] && usage

format_size() {
  awk "BEGIN{printf \"%.2f\", $1/1048576}"
}

compress_one() {
  local filename="$1"
  local input_path="$INPUT_DIR/$filename"
  local name="${filename%.*}"
  local output_path="$OUTPUT_DIR/${name}_compressed.mp4"

  if [ ! -f "$input_path" ]; then
    echo "[$filename] 错误: 文件不存在"
    return 1
  fi
  if [ -f "$output_path" ]; then
    echo "[$filename] 跳过 (已压缩)"
    return 0
  fi

  local in_size
  in_size=$(stat -f '%z' "$input_path" 2>/dev/null || stat -c '%s' "$input_path" 2>/dev/null)

  local vcodec_args
  vcodec_args=$(build_vcodec_args)

  echo "[$filename] 开始压缩 (模式: $MODE, 编码器: $ENCODER, 原始: $(format_size "$in_size")MB)"

  local tmp_output="${output_path}.tmp.mp4"

  local vf_args
  vf_args=$(build_video_filter "$input_path")

  # shellcheck disable=SC2086
  if ffmpeg -y -i "$input_path" \
    $vcodec_args \
    $vf_args \
    -c:a aac -b:a "$AUDIO_BITRATE" \
    -movflags +faststart \
    -threads 0 \
    "$tmp_output" 2>/dev/null </dev/null; then
    :
  elif [ "$ENCODER" = "hevc_videotoolbox" ] || [ "$ENCODER" = "h264_videotoolbox" ]; then
    local fallback_args
    fallback_args=$(build_fallback_vcodec_args)
    echo "[$filename] 硬件编码失败，回退到 libx264(veryfast)"
    # shellcheck disable=SC2086
    ffmpeg -y -i "$input_path" \
      $fallback_args \
      $vf_args \
      -c:a aac -b:a "$AUDIO_BITRATE" \
      -movflags +faststart \
      -threads 0 \
      "$tmp_output" 2>/dev/null </dev/null
  else
    return 1
  fi

  mv "$tmp_output" "$output_path"

  local out_size
  out_size=$(stat -f '%z' "$output_path" 2>/dev/null || stat -c '%s' "$output_path" 2>/dev/null)
  local ratio
  ratio=$(awk "BEGIN{printf \"%.1f\", (1-$out_size/$in_size)*100}")

  echo "[$filename] 完成! $(format_size "$in_size")MB → $(format_size "$out_size")MB (缩小 ${ratio}%)"
}

export -f compress_one format_size build_video_filter build_vcodec_args build_fallback_vcodec_args
export INPUT_DIR OUTPUT_DIR ENCODER AUDIO_BITRATE MAX_HEIGHT TARGET_FPS MODE CRF X265_PRESET

if [ "$1" = "--all" ]; then
  start_ts=$(date +%s)

  files=()
  for f in "$INPUT_DIR"/*.mp4 "$INPUT_DIR"/*.MP4 "$INPUT_DIR"/*.mov "$INPUT_DIR"/*.MOV "$INPUT_DIR"/*.avi "$INPUT_DIR"/*.AVI "$INPUT_DIR"/*.mkv "$INPUT_DIR"/*.MKV; do
    [ -f "$f" ] || continue
    files+=("$(basename "$f")")
  done

  if [ ${#files[@]} -eq 0 ]; then
    echo "compress/input/ 下没有找到视频文件"
    exit 1
  fi

  echo "========================================="
  echo "批量压缩: ${#files[@]} 个视频"
  echo "编码器: $ENCODER | 并行: $PARALLEL"
  echo "========================================="

  printf '%s\n' "${files[@]}" | xargs -P "$PARALLEL" -I {} bash -c 'compress_one "$@"' _ {}

  end_ts=$(date +%s)
  cost=$((end_ts - start_ts))

  total_in=0 total_out=0
  for f in "${files[@]}"; do
    bname="${f%.*}"
    in_f="$INPUT_DIR/$f"
    out_f="$OUTPUT_DIR/${bname}_compressed.mp4"
    [ -f "$in_f" ] && total_in=$((total_in + $(stat -f '%z' "$in_f" 2>/dev/null || echo 0)))
    [ -f "$out_f" ] && total_out=$((total_out + $(stat -f '%z' "$out_f" 2>/dev/null || echo 0)))
  done

  echo ""
  echo "========================================="
  echo "全部完成! 共 ${#files[@]} 个视频"
  echo "  耗时: $((cost/60))分$((cost%60))秒"
  echo "  压缩前: $(format_size "$total_in")MB"
  echo "  压缩后: $(format_size "$total_out")MB"
  if [ "$total_in" -gt 0 ] && [ "$total_out" -gt 0 ]; then
    echo "  缩小: $(awk "BEGIN{printf \"%.1f\", (1-$total_out/$total_in)*100}")%"
  fi
  echo "========================================="
else
  start_ts=$(date +%s)
  compress_one "$1"
  end_ts=$(date +%s)
  echo "  耗时: $(( (end_ts - start_ts) / 60 ))分$(( (end_ts - start_ts) % 60 ))秒"
fi
