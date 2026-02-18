#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"
OUTPUT_DIR="$SCRIPT_DIR/output"
SRT_DIR="$OUTPUT_DIR/srt"
TRANSCRIBE_PY="$SCRIPT_DIR/transcribe.py"
WHISPER_ENV="$HOME/mlx-whisper-env/bin/activate"
OUTPUT_FPS="${OUTPUT_FPS:-2}"
VIDEO_ENCODER="${VIDEO_ENCODER:-auto}"

mkdir -p "$INPUT_DIR" "$SRT_DIR"

detect_video_encoder() {
  if [ "$VIDEO_ENCODER" != "auto" ]; then
    echo "$VIDEO_ENCODER"
    return 0
  fi
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_videotoolbox"; then
    echo "h264_videotoolbox"
  else
    echo "libx264"
  fi
}

ENCODER_SELECTED="$(detect_video_encoder)"

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
  echo "  编码器: $ENCODER_SELECTED, FPS: $OUTPUT_FPS"

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

  local cover
  cover="$OUTPUT_DIR/.cover_${name}.jpg"

  ffmpeg -y -i "$input_path" -frames:v 1 "$cover" >/dev/null 2>&1

  local -a vcodec_args
  if [ "$ENCODER_SELECTED" = "h264_videotoolbox" ]; then
    vcodec_args=(-c:v h264_videotoolbox -q:v 60 -allow_sw 1)
  else
    vcodec_args=(-c:v libx264 -preset fast -tune stillimage -crf 28)
  fi

  local -a audio_args=(-c:a aac_at -b:a 64k -ac 1)
  if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "aac_at"; then
    audio_args=(-c:a aac -b:a 64k -ac 1)
  fi

  ffmpeg -y -loop 1 -i "$cover" -i "$input_path" \
  -vf "fps=${OUTPUT_FPS},ass=$ass" \
  "${vcodec_args[@]}" \
  "${audio_args[@]}" \
  -map 0:v:0 -map 1:a:0 -t "$duration_full" -shortest \
  -progress pipe:1 "$final" 2>/dev/null < /dev/null | \
  ( set +u
    while IFS='=' read -r key value; do
      if [ "$key" = "out_time_ms" ] && [[ "$value" =~ ^[0-9]+$ ]] && [ "$duration_s" -gt 0 ] 2>/dev/null; then
        elapsed_s=$((value / 1000000))
        pct=$((elapsed_s * 100 / duration_s))
        [ "$pct" -gt 100 ] && pct=100
        printf "\r  进度: %3d%%" "$pct"
      fi
    done
  ) || true
  printf "\r  进度: 100%%\n"
  rm -f "$cover"
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

  local ass="$SRT_DIR/${name}.ass"
  if [ -f "$srt" ] && [ -f "$ass" ] && [ "${FORCE_ASR:-0}" != "1" ]; then
    echo "已有字幕，跳过识别 (设置 FORCE_ASR=1 可强制重跑)"
  else
    echo "AI 语音识别生成字幕..."
    source "$WHISPER_ENV" && python "$TRANSCRIBE_PY" "$input_path" "$srt"
  fi

  echo "合成视频（封面 + 音频 + 字幕）..."
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

print_summary() {
  local start_time="$1" end_time="$2" count="$3"
  shift 3
  local input_files=("$@")

  local total_cost=$((end_time - start_time))
  echo ""
  echo "========================================="
  echo "全部完成！共处理 ${count} 个视频"
  echo "========================================="
  echo "  开始时间：$(date -r "$start_time" '+%Y-%m-%d %H:%M:%S')"
  echo "  结束时间：$(date -r "$end_time" '+%Y-%m-%d %H:%M:%S')"
  echo "  总耗时：   $((total_cost / 60))分$((total_cost % 60))秒"

  local total_input=0 total_output=0
  for f in "${input_files[@]}"; do
    local bname="${f%.*}"
    local in_file="$INPUT_DIR/$f"
    local out="$OUTPUT_DIR/${bname}_final.mp4"
    if [ -f "$in_file" ]; then
      local sz
      sz=$(stat -f '%z' "$in_file" 2>/dev/null || echo 0)
      total_input=$((total_input + sz))
    fi
    if [ -f "$out" ]; then
      local sz2
      sz2=$(stat -f '%z' "$out" 2>/dev/null || echo 0)
      total_output=$((total_output + sz2))
    fi
  done

  local input_mb output_mb ratio
  input_mb=$(awk "BEGIN{printf \"%.2f\", $total_input/1048576}")
  output_mb=$(awk "BEGIN{printf \"%.2f\", $total_output/1048576}")
  echo "  处理前大小：${input_mb}MB"
  echo "  处理后大小：${output_mb}MB"
  if [ "$total_input" -gt 0 ] && [ "$total_output" -gt 0 ]; then
    ratio=$(awk "BEGIN{printf \"%.1f\", (1-$total_output/$total_input)*100}")
    echo "  体积缩小：   ${ratio}%"
  fi
}

collect_pending_files() {
  # 返回结果到全局变量：COLLECT_FILES (数组), COLLECT_TOTAL (计数)
  COLLECT_FILES=()
  COLLECT_TOTAL=0
  for f in "$INPUT_DIR"/*.mp4 "$INPUT_DIR"/*.MP4 "$INPUT_DIR"/*.mov "$INPUT_DIR"/*.MOV; do
    [ -f "$f" ] || continue
    local bname
    bname="$(basename "${f%.*}")"
    if [ ! -f "$OUTPUT_DIR/${bname}_final.mp4" ]; then
      COLLECT_FILES+=("$(basename "$f")")
      COLLECT_TOTAL=$((COLLECT_TOTAL + 1))
    else
      echo "跳过 (已处理): $(basename "$f")"
    fi
  done
}

if [ "$1" = "--all" ]; then
  batch_start=$(date +%s)
  collect_pending_files
  pending_files=("${COLLECT_FILES[@]}")
  pending_total=$COLLECT_TOTAL

  if [ "$pending_total" -eq 0 ]; then
    has_any=0
    for f in "$INPUT_DIR"/*.mp4 "$INPUT_DIR"/*.MP4 "$INPUT_DIR"/*.mov "$INPUT_DIR"/*.MOV; do
      [ -f "$f" ] && has_any=1 && break
    done
    if [ "$has_any" -eq 0 ]; then
      echo "input 目录下没有找到视频文件"
      exit 1
    fi
    echo "========================================="
    echo "全部完成! 没有需要处理的新视频"
    echo "========================================="
    exit 0
  fi

  current=0
  processed_files=()
  for fname in "${COLLECT_FILES[@]}"; do
    current=$((current + 1))
    echo ""
    echo "[$current/$pending_total] 开始处理: $fname"
    process_video "$fname"
    processed_files+=("$fname")
  done

  batch_end=$(date +%s)
  print_summary "$batch_start" "$batch_end" "$current" "${processed_files[@]}"

elif [ "$1" = "--export" ]; then
  batch_start=$(date +%s)
  export_files=()
  export_total=0
  for f in "$INPUT_DIR"/*.mp4 "$INPUT_DIR"/*.MP4 "$INPUT_DIR"/*.mov "$INPUT_DIR"/*.MOV; do
    [ -f "$f" ] || continue
    local_name="$(basename "${f%.*}")"
    local_final="$OUTPUT_DIR/${local_name}_final.mp4"
    local_ass="$SRT_DIR/${local_name}.ass"
    if [ -f "$local_final" ]; then
      echo "跳过(已存在): $(basename "$f")"
      continue
    fi
    if [ ! -f "$local_ass" ]; then
      echo "跳过(缺少字幕): $(basename "$f")"
      continue
    fi
    export_files+=("$(basename "$f")")
    export_total=$((export_total + 1))
  done

  if [ "$export_total" -eq 0 ]; then
    echo "没有需要导出的视频"
    exit 1
  fi

  current=0
  for fname in "${export_files[@]}"; do
    current=$((current + 1))
    local_name="${fname%.*}"
    echo ""
    echo "[$current/$export_total] 导出: $fname"
    echo "========================================="
    local_start=$(date +%s)
    export_video "$fname"
    local_end=$(date +%s)
    local_cost=$((local_end - local_start))
    echo ""
    echo "完成! 耗时 $((local_cost / 60))分$((local_cost % 60))秒"
    echo "  视频: output/${local_name}_final.mp4"
    echo ""
  done

  batch_end=$(date +%s)
  print_summary "$batch_start" "$batch_end" "$export_total" "${export_files[@]}"

else
  batch_start=$(date +%s)
  echo "[1/1] 开始处理: $1"
  process_video "$1"
  batch_end=$(date +%s)
  print_summary "$batch_start" "$batch_end" 1 "$1"
fi
