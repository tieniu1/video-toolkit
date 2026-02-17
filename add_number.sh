#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
NUMBERED_DIR="$OUTPUT_DIR/numbered"
mkdir -p "$NUMBERED_DIR"

if [ $# -lt 2 ]; then
  echo "用法: ./add_number.sh <视频文件名> <数字>"
  echo ""
  echo "在视频画面下三分之一处居中显示一个数字"
  echo ""
  echo "示例:"
  echo "  ./add_number.sh SVID_20250327_203419_1_final.mp4 42"
  echo "  ./add_number.sh --all 1        按文件名顺序从1开始编号"
  exit 1
fi

add_number() {
  local input_path="$1"
  local number="$2"
  local filename="$(basename "$input_path")"
  local name="${filename%.*}"
  local ext="${filename##*.}"
  local numbered="${NUMBERED_DIR}/${name}_numbered.${ext}"

  if [ ! -f "$input_path" ]; then
    echo "错误: 文件不存在 $input_path"
    return 1
  fi

  echo "========================================="
  echo "处理: $filename  数字: $number"
  echo "========================================="

  local start_ts
  start_ts=$(date +%s)

  ffmpeg -y -i "$input_path" \
    -vf "drawtext=text='${number}':fontsize=h/12:fontcolor=white:borderw=3:bordercolor=black:x=(w-text_w)/2:y=h*2/3" \
    -c:v libx264 -preset fast -crf 28 -tune stillimage -c:a copy \
    "$numbered" 2>/dev/null

  local end_ts
  end_ts=$(date +%s)
  local cost=$((end_ts - start_ts))

  echo "完成! 耗时 $((cost / 60))分$((cost % 60))秒"
  echo "  输出: ${name}_numbered.${ext}"
  echo ""
}

if [ "$1" = "--all" ] || [ "$1" = "-all" ]; then
  start_num="${2:-1}"
  num="$start_num"
  count=0
  for f in "$OUTPUT_DIR"/*_final.mp4; do
    [ -f "$f" ] || continue
    add_number "$f" "$num"
    num=$((num + 1))
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    echo "output 目录下没有找到 _final.mp4 文件"
    exit 1
  fi
  # 重命名: 去掉 _trim_final_numbered 和 _final_numbered 后缀
  for f in "$NUMBERED_DIR"/*_numbered.mp4; do
    [ -f "$f" ] || continue
    local_name="$(basename "$f")"
    new_name="${local_name/_trim_final_numbered/}"
    new_name="${new_name/_final_numbered/}"
    if [ "$local_name" != "$new_name" ]; then
      mv "$f" "$NUMBERED_DIR/$new_name"
      echo "重命名: $local_name -> $new_name"
    fi
  done

  echo "========================================="
  echo "全部完成! 共处理 ${count} 个视频 (编号 ${start_num}-$((num - 1)))"
  echo "========================================="
else
  input_file="$1"
  if [[ "$input_file" != /* ]]; then
    input_file="$OUTPUT_DIR/$input_file"
  fi
  add_number "$input_file" "$2"
fi
