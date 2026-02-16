#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"
OUTPUT_DIR="$SCRIPT_DIR/output"
SRT_DIR="$OUTPUT_DIR/srt"
TRANSCRIBE_PY="$SCRIPT_DIR/transcribe.py"
WHISPER_ENV="$HOME/mlx-whisper-env/bin/activate"

mkdir -p "$INPUT_DIR" "$SRT_DIR"

if [ $# -lt 1 ]; then
  echo "用法:"
  echo "  ./process.sh <文件名>        完整处理（字幕+合成）"
  echo "  ./process.sh --all           处理所有视频（跳过已完成的）"
  echo "  ./process.sh --export        仅合成视频（需已有字幕）"
  echo ""
  echo "示例: ./process.sh SVID_20260210_210732_1.mp4"
  exit 1
fi

export_video() {
  local filename="$1"
  local input_path="$INPUT_DIR/$filename"
  local name="${filename%.*}"
  local ass="$SRT_DIR/${name}.ass"
  local final="$OUTPUT_DIR/${name}_final.mp4"

  if [ ! -f "$input_path" ]; then
    echo "错误: 源视频不存在 input/$filename"
    return 1
  fi
  if [ ! -f "$ass" ]; then
    echo "错误: ASS 字幕不存在 output/srt/${name}.ass"
    return 1
  fi

  echo "  合成中..."

  local duration_full
  duration_full=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$input_path")
  if [ -z "$duration_full" ] || [ "$duration_full" = "N/A" ]; then
    duration_full=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 "$input_path")
  fi
  if [ -z "$duration_full" ] || [ "$duration_full" = "N/A" ]; then
    duration_full=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=r_frame_rate,nb_read_frames -of csv=p=0 "$input_path" | awk -F'[,/]' '{if(NF>=3 && $3>0) printf "%.2f", $1*$2/$3; else print "0"}')
  fi

  local duration_s
  duration_s=$(echo "$duration_full" | cut -d. -f1)
  if [ -z "$duration_s" ] || [ "$duration_s" -le 0 ] 2>/dev/null; then
    duration_s=0
  fi

  ffmpeg -y -i "$input_path" \
  -vf "select=eq(n\,0),setpts=PTS-STARTPTS,tpad=stop_duration=${duration_full}:stop_mode=clone,fps=5,ass=$ass" \
  -c:v libx264 -preset ultrafast -tune stillimage -c:a copy -t "$duration_full" \
  -progress pipe:1 "$final" 2>/dev/null | \
  ( set +u
    while IFS='=' read -r key value; do
      if [ "$key" = "out_time_ms" ] && [[ "$value" =~ ^[0-9]+$ ]] && [ "$duration_s" -gt 0 ] 2>/dev/null; then
        elapsed_s=$((value / 1000000))
        pct=$((elapsed_s * 100 / duration_s))
        [ "$pct" -gt 100 ] && pct=100
        printf "\r  进度: %3d%%" "$pct"
      fi
    done
  )
  printf "\r  进度: 100%%\n"
}

process_video() {
  local filename="$1"
  local input_path="$INPUT_DIR/$filename"
  local name="${filename%.*}"
  local srt="$SRT_DIR/${name}.srt"
  local final="$OUTPUT_DIR/${name}_final.mp4"

  if [ ! -f "$input_path" ]; then
    echo "错误: 文件不存在 input/$filename"
    return 1
  fi

  local start_ts
  start_ts=$(date +%s)

  echo "========================================="
  echo "处理: $filename"
  echo "========================================="

  echo "[1/2] AI 语音识别生成字幕..."
  source "$WHISPER_ENV" && python "$TRANSCRIBE_PY" "$input_path" "$srt"

  echo "[2/2] 合成视频（封面 + 音频 + 字幕）..."
  export_video "$filename"

  local end_ts
  end_ts=$(date +%s)
  local cost=$((end_ts - start_ts))
  local cost_m=$((cost / 60))
  local cost_s=$((cost % 60))

  echo ""
  echo "完成! 耗时 ${cost_m}分${cost_s}秒"
  echo "  视频: output/${name}_final.mp4"
  echo ""
}

if [ "$1" = "--all" ]; then
  round=1
  total_processed=0
  while true; do
    if [ "$round" -gt 1 ]; then
      echo ""
      echo "========================================="
      echo "第 ${round} 轮扫描: 检查新增文件..."
      echo "========================================="
    fi
    processed=0
    skipped=0
    for f in "$INPUT_DIR"/*.mp4 "$INPUT_DIR"/*.MP4 "$INPUT_DIR"/*.mov "$INPUT_DIR"/*.MOV; do
      [ -f "$f" ] || continue
      local_name="$(basename "${f%.*}")"
      if [ -f "$OUTPUT_DIR/${local_name}_final.mp4" ]; then
        echo "跳过(已处理): $(basename "$f")"
        skipped=$((skipped + 1))
        continue
      fi
      process_video "$(basename "$f")"
      processed=$((processed + 1))
    done
    total_processed=$((total_processed + processed))
    if [ "$processed" -eq 0 ]; then
      if [ "$total_processed" -eq 0 ] && [ "$skipped" -eq 0 ]; then
        echo "input 目录下没有找到视频文件"
        exit 1
      fi
      break
    fi
    round=$((round + 1))
  done
  echo "========================================="
  echo "全部完成! 共处理 ${total_processed} 个视频"
  echo "========================================="
elif [ "$1" = "--export" ]; then
  found=0
  for f in "$INPUT_DIR"/*.mp4 "$INPUT_DIR"/*.MP4 "$INPUT_DIR"/*.mov "$INPUT_DIR"/*.MOV; do
    [ -f "$f" ] || continue
    local_name="$(basename "${f%.*}")"
    local_srt="$SRT_DIR/${local_name}.srt"
    local_final="$OUTPUT_DIR/${local_name}_final.mp4"
    if [ -f "$local_final" ]; then
      echo "跳过(已存在): $(basename "$f")"
      found=1
      continue
    fi
    if [ ! -f "$local_srt" ]; then
      echo "跳过(缺少字幕): $(basename "$f")"
      found=1
      continue
    fi
    echo "========================================="
    echo "导出: $(basename "$f")"
    echo "========================================="
    local_start=$(date +%s)
    export_video "$(basename "$f")"
    local_end=$(date +%s)
    local_cost=$((local_end - local_start))
    echo ""
    echo "完成! 耗时 $((local_cost / 60))分$((local_cost % 60))秒"
    echo "  视频: output/${local_name}_final.mp4"
    echo ""
    found=1
  done
  if [ "$found" -eq 0 ]; then
    echo "没有需要导出的视频"
    exit 1
  fi
else
  process_video "$1"
fi
