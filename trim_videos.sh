#!/bin/bash
set -euo pipefail

# Edit this list: "filename|start|end"
# Time format supports:
# - HH:MM:SS
# - MM:SS
# - SS
TASKS=(
  "SVID_20250422_195607_1.mp4|0|2:15:41"
  "SVID_20250930_212258_1.mp4|0|0:49:19"
  "SVID_20251201_201338_1.mp4|0|1:46:26"
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"

# Output suffix for new files. Source files are never overwritten.
OUT_SUFFIX="_trim"

# ffmpeg mode:
# - copy: fast, stream copy (may be less accurate at non-keyframe boundaries)
# - reencode: slower, frame-accurate cuts
FFMPEG_MODE="copy"

time_to_seconds() {
  local t="$1"
  awk -F: '
    NF==3 { print ($1 * 3600) + ($2 * 60) + $3; next }
    NF==2 { print ($1 * 60) + $2; next }
    NF==1 { print $1; next }
    { print -1 }
  ' <<<"$t"
}

trim_one() {
  local filename="$1"
  local start="$2"
  local end="$3"
  local src="$INPUT_DIR/$filename"
  local stem="${filename%.*}"
  local ext="${filename##*.}"
  local out="$INPUT_DIR/${stem}${OUT_SUFFIX}.${ext}"

  if [ ! -f "$src" ]; then
    echo "[skip] missing source: $filename"
    return 0
  fi

  local s_sec e_sec
  s_sec="$(time_to_seconds "$start")"
  e_sec="$(time_to_seconds "$end")"
  if [ "$s_sec" -lt 0 ] || [ "$e_sec" -lt 0 ] || [ "$e_sec" -le "$s_sec" ]; then
    echo "[skip] invalid range: $filename ($start -> $end)"
    return 0
  fi

  echo "=================================================="
  echo "Trimming: $filename"
  echo "Range   : $start -> $end"
  echo "Output  : $(basename "$out")"

  if [ "$FFMPEG_MODE" = "copy" ]; then
    ffmpeg -y -i "$src" -ss "$start" -to "$end" -c copy -avoid_negative_ts make_zero "$out"
  elif [ "$FFMPEG_MODE" = "reencode" ]; then
    ffmpeg -y -i "$src" -ss "$start" -to "$end" -c:v libx264 -preset veryfast -crf 18 -c:a aac -b:a 192k "$out"
  else
    echo "[error] unknown FFMPEG_MODE: $FFMPEG_MODE"
    return 1
  fi

  local out_dur
  out_dur="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$out")"
  echo "Done. Duration(s): ${out_dur:-unknown}"
  echo ""
}

if [ "${#TASKS[@]}" -eq 0 ]; then
  echo "No tasks configured. Edit TASKS in trim_videos.sh first."
  exit 1
fi

for task in "${TASKS[@]}"; do
  IFS='|' read -r filename start end <<<"$task"
  if [ -z "${filename:-}" ] || [ -z "${start:-}" ] || [ -z "${end:-}" ]; then
    echo "[skip] invalid task entry: $task"
    continue
  fi
  trim_one "$filename" "$start" "$end"
done

echo "All tasks finished."
