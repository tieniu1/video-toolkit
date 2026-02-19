#!/bin/bash
set -u

# ================= 配置区域 =================
MODE="${MODE:-speed}"
MAX_HEIGHT="${MAX_HEIGHT:-960}"
AUDIO_BITRATE="${AUDIO_BITRATE:-48k}"
PARALLEL="${PARALLEL:-2}"
# ===========================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/compress-input"
OUTPUT_DIR="$SCRIPT_DIR/compress-output"
TEMP_STAT_FILE="$SCRIPT_DIR/.compress_batch_stats.tmp"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

bytes_to_human() {
    local b=${1:-0}
    if [ "$b" -gt 1073741824 ]; then
        awk "BEGIN {printf \"%.2fGB\", $b/1073741824}"
    else
        awk "BEGIN {printf \"%.2fMB\", $b/1048576}"
    fi
}

detect_encoder() {
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "hevc_videotoolbox"; then
        echo "hevc_videotoolbox"
    else
        echo "libx264"
    fi
}
ENCODER="${ENCODER:-$(detect_encoder)}"

build_vcodec_args() {
    case "$ENCODER" in
        hevc_videotoolbox)
            echo "-c:v hevc_videotoolbox -q:v 38 -maxrate 2M -profile:v main -tag:v hvc1 -allow_sw 1 -g 120"
            ;;
        libx264)
            echo "-c:v libx264 -preset veryfast -crf 28"
            ;;
    esac
}

build_audio_args() {
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "aac_at"; then
        echo "-c:a aac_at -b:a $AUDIO_BITRATE -ac 1"
    else
        echo "-c:a aac -b:a $AUDIO_BITRATE -ac 1"
    fi
}

build_video_filter() {
    local input_path="$1"
    local filters=()
    local height
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input_path" 2>/dev/null)
    height="${height%%.*}"
    if [ -n "$MAX_HEIGHT" ] && [ -n "$height" ] && [ "$height" -gt "$MAX_HEIGHT" ] 2>/dev/null; then
        filters+=("scale=-2:${MAX_HEIGHT}:flags=lanczos")
    fi
    filters+=("fps=24")
    echo "-vf $(IFS=,; echo "${filters[*]}")"
}

# 顺序模式：带实时进度条
process_file() {
    local filename="$1"
    local index="$2"
    local total="$3"

    local input_path="$INPUT_DIR/$filename"
    local name="${filename%.*}"
    local output_path="$OUTPUT_DIR/${name}_compressed.mp4"
    local tmp_output="${output_path}.tmp.mp4"

    local duration_sec
    duration_sec=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_path")
    [ -z "$duration_sec" ] && duration_sec=0

    local in_size
    in_size=$(stat -f '%z' "$input_path" 2>/dev/null || stat -c '%s' "$input_path")

    if [ -s "$output_path" ]; then
        echo "⏭️  [${index}/${total}] $filename (已存在，跳过)"
        return 0
    fi

    echo "🎬 [${index}/${total}] 正在处理: $filename ($(bytes_to_human "$in_size"))"

    local start_time
    start_time=$(date +%s)

    (
        ffmpeg -y -v error -progress pipe:1 -i "$input_path" \
        $(build_vcodec_args) \
        $(build_video_filter "$input_path") \
        $(build_audio_args) \
        -map_metadata 0 -movflags +faststart \
        "$tmp_output" 2>&1
    ) | awk -v total_dur="$duration_sec" -v start_ts="$start_time" '
        function to_human(b) {
            if (b > 1073741824) return sprintf("%.2fGB", b/1073741824);
            return sprintf("%.2fMB", b/1048576);
        }
        function sec_to_str(s) {
            if (s < 0) s = 0;
            return sprintf("%02d:%02d:%02d", int(s/3600), int((s%3600)/60), int(s%60));
        }
        {
            split($0, a, "="); key=a[1]; val=a[2];
            if (key == "out_time_us") current_sec = val / 1000000;
            if (key == "total_size") current_size = val;
            if (key == "progress" && val == "continue") {
                cmd = "date +%s"; cmd | getline now; close(cmd);
                pct = (total_dur > 0) ? (current_sec / total_dur) * 100 : 0;
                if (pct > 99.9) pct = 99.9;
                printf "\r    ⏳ %5.1f%% | %s | %s / %s", pct, to_human(current_size), sec_to_str(current_sec), sec_to_str(total_dur);
            }
        }
        END {
            cmd = "date +%s"; cmd | getline now; close(cmd);
            printf "\r    ⏳ 100.0%% | %s | %s / %s \n", to_human(current_size), sec_to_str(total_dur), sec_to_str(total_dur);
        }
    '

    if [ -s "$tmp_output" ]; then
        mv "$tmp_output" "$output_path"
        local out_size
        out_size=$(stat -f '%z' "$output_path" 2>/dev/null || stat -c '%s' "$output_path")
        local ratio="0.0"
        [ "$in_size" -gt 0 ] && ratio=$(awk "BEGIN {printf \"%.1f\", (1 - $out_size / $in_size) * 100}")
        echo "$in_size $out_size" >> "$TEMP_STAT_FILE"
        echo "    ✅ 完成 | $(bytes_to_human "$in_size") → $(bytes_to_human "$out_size") (省了 ${ratio}%)"
    else
        echo "    ❌ 失败 (请检查源文件)"
        rm -f "$tmp_output"
    fi
}

# 并行模式：简洁输出
compress_one() {
    local filename="$1"
    local input_path="$INPUT_DIR/$filename"
    local name="${filename%.*}"
    local output_path="$OUTPUT_DIR/${name}_compressed.mp4"
    local tmp_output="${output_path}.tmp.mp4"

    if [ -s "$output_path" ]; then
        echo "⏭️  [$filename] 跳过 (已存在)"
        return 0
    fi

    local in_size
    in_size=$(stat -f '%z' "$input_path" 2>/dev/null || stat -c '%s' "$input_path")

    echo "🔥 [$filename] 压缩中..."

    if ffmpeg -y -v error -i "$input_path" \
        $(build_vcodec_args) \
        $(build_video_filter "$input_path") \
        $(build_audio_args) \
        -map_metadata 0 -movflags +faststart \
        "$tmp_output" < /dev/null; then
        mv "$tmp_output" "$output_path"
        local out_size
        out_size=$(stat -f '%z' "$output_path" 2>/dev/null || stat -c '%s' "$output_path")
        local ratio
        ratio=$(awk "BEGIN {printf \"%.1f\", (1 - $out_size / $in_size) * 100}")
        echo "✅ [$filename] $(bytes_to_human "$in_size") → $(bytes_to_human "$out_size") (省了 ${ratio}%)"
    else
        echo "❌ [$filename] 压缩失败"
        rm -f "$tmp_output"
    fi
}

# ================= 主逻辑 =================

usage() {
    echo "用法:"
    echo "  ./compress.sh --all              顺序处理（带进度条）"
    echo "  ./compress.sh --parallel         并行处理（速度更快）"
    echo "  ./compress.sh <文件名>           处理单个文件"
}

collect_files() {
    shopt -s nullglob
    FILES=("$INPUT_DIR"/*.{mp4,MP4,mov,MOV,mkv,MKV})
    shopt -u nullglob
}

if [ "${1:-}" = "--all" ] || [ -z "${1:-}" ]; then
    collect_files
    total_files=${#FILES[@]}
    [ "$total_files" -eq 0 ] && { echo "📂 compress-input/ 下没有找到视频文件"; exit 1; }

    : > "$TEMP_STAT_FILE"
    echo "========================================="
    echo "🚀 顺序压缩 | 共 $total_files 个视频"
    echo "========================================="

    start_all=$(date +%s)
    count=1
    for f in "${FILES[@]}"; do
        process_file "$(basename "$f")" "$count" "$total_files"
        ((count++))
    done
    end_all=$(date +%s)
    total_cost=$((end_all - start_all))

    total_in=0; total_out=0
    if [ -f "$TEMP_STAT_FILE" ]; then
        while read -r in_s out_s; do
            total_in=$(echo "$total_in + $in_s" | bc)
            total_out=$(echo "$total_out + $out_s" | bc)
        done < "$TEMP_STAT_FILE"
    fi
    ratio=0
    [ "$total_in" -gt 0 ] && ratio=$(awk "BEGIN {printf \"%.1f\", (1 - $total_out / $total_in) * 100}")

    echo ""
    echo "📊 ============== 全局报告 =============="
    echo "⏱️  总耗时: $((total_cost/60))分$((total_cost%60))秒"
    echo "📦 原始: $(bytes_to_human "$total_in") → 压缩后: $(bytes_to_human "$total_out") (减少 ${ratio}%)"
    echo "========================================="
    rm -f "$TEMP_STAT_FILE"

elif [ "${1:-}" = "--parallel" ]; then
    collect_files
    total_files=${#FILES[@]}
    [ "$total_files" -eq 0 ] && { echo "📂 compress-input/ 下没有找到视频文件"; exit 1; }

    echo "========================================="
    echo "🚀 并行压缩 | 共 $total_files 个视频 | 并发数: $PARALLEL"
    echo "========================================="

    export -f compress_one build_vcodec_args build_audio_args build_video_filter bytes_to_human
    export INPUT_DIR OUTPUT_DIR ENCODER AUDIO_BITRATE MAX_HEIGHT MODE

    start_all=$(date +%s)
    printf '%s\n' "${FILES[@]}" | xargs -P "$PARALLEL" -I {} bash -c 'compress_one "$(basename "{}")"'
    end_all=$(date +%s)
    echo ""
    echo "🎉 全部完成! 总耗时: $(((end_all-start_all)/60))分$(((end_all-start_all)%60))秒"

else
    [ ! -f "$INPUT_DIR/$1" ] && { echo "错误: 文件不存在 compress-input/$1"; exit 1; }
    process_file "$1" 1 1
fi
