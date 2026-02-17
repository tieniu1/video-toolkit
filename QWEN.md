# Video Processing Project - Context Guide

## Project Overview

This is a **batch video processing pipeline** for vertical videos. It automates:
- Speech-to-text transcription (Chinese Mandarin) with Simplified Chinese subtitles
- SRT and ASS subtitle generation
- Video compression using static cover + original audio + burned-in subtitles
- Time-based video trimming/cropping

**Target Output:** Compressed vertical videos with burned-in subtitles, suitable for social media platforms.

## System Environment

- **Hardware:** MacBook Air 2025 (M4 chip, Apple Silicon, 16GB+512GB)
- **OS:** macOS 15.7.3 (Darwin 24.6.0, arm64)
- **Shell:** zsh
- **Python:** 3.14.3 (virtual env: `$HOME/mlx-whisper-env`)
- **FFmpeg:** 8.0 (with `h264_videotoolbox` hardware encoding)
- **Git:** 2.39.5

## Key Technologies

| Component | Technology |
|-----------|------------|
| Speech Recognition | `mlx-whisper` (Large-v3-turbo-4bit model) |
| Text Processing | `opencc-python-reimplemented` (Traditional→Simplified) |
| Video Processing | FFmpeg (h264_videotoolbox hardware encoding) |
| Scripting | Bash |

## Directory Structure

```
video/
├── input/              # Source video files (git-ignored)
├── output/
│   ├── srt/            # Generated subtitles (.srt, .ass)
│   ├── numbered/       # Videos with overlay numbers
│   └── *_final.mp4     # Final processed videos
├── 待处理/              # Additional素材 directory (not used in main flow)
├── process.sh          # Main processing script
├── transcribe.py       # Speech recognition & subtitle generation
├── trim_videos.sh      # Batch video trimming by time range
├── add_number.sh       # Add overlay numbers to videos
├── 流程.md             # Process documentation (Chinese)
└── README.md           # Detailed documentation (Chinese)
```

## Core Scripts

### `process.sh` - Main Processing Pipeline

**Modes:**
```bash
./process.sh <filename.mp4>     # Process single video
./process.sh --all              # Batch process all videos in input/
./process.sh --export           # Export only (requires existing subtitles)
```

**Workflow:**
1. Extract first frame as cover image
2. Create static video (cover + original audio)
3. Run AI speech recognition → generate Simplified Chinese subtitles
4. Burn subtitles into video (top-left position)
5. Clean up intermediate files

**Environment Variables:**
- `VIDEO_ENCODER`: `auto` (default), `h264_videotoolbox`, or `libx264`
- `VIDEO_BITRATE`: Default `2500k`
- `OUTPUT_FPS`: Default `2` (optimized for static cover)
- `WHISPER_MODEL`: Override ASR model

### `transcribe.py` - Speech Recognition

**Features:**
- Uses `mlx-whisper` with Mandarin language (`language="zh"`)
- Outputs both SRT and ASS subtitle formats
- ASS styled for vertical video (PlayResX=576, PlayResY=1280)
- Traditional→Simplified conversion via OpenCC
- Offline mode enabled (`HF_HUB_OFFLINE=1`)

**Usage:**
```bash
python transcribe.py <input_video> [output_srt] [--model <model_name>]
```

### `trim_videos.sh` - Video Trimming

Configure tasks in the script:
```bash
TASKS=(
  "video.mp4|0|00:03:00"    # filename|start|end
)
```

**Modes:**
- `copy`: Fast, stream copy (may be imprecise at non-keyframes)
- `reencode`: Slow, frame-accurate cuts

### `add_number.sh` - Number Overlay

Adds centered number overlay at bottom-third of video frame.

```bash
./add_number.sh <video.mp4> <number>
./add_number.sh --all 1     # Batch number all _final.mp4 files
```

## Common Workflows

### Standard Processing
```bash
# 1. Place videos in input/
# 2. Run batch processing
./process.sh --all

# 3. Get results from output/
#    - xxx_final.mp4 (final video)
#    - output/srt/xxx.srt (subtitles)
```

### Trim Then Process
```bash
# 1. Configure TASKS in trim_videos.sh
# 2. Trim videos
./trim_videos.sh

# 3. Process trimmed videos
./process.sh --all
```

### Export Only (Skip Transcription)
```bash
# Requires existing .ass subtitles in output/srt/
./process.sh --export
```

### Custom Model
```bash
WHISPER_MODEL=mlx-community/whisper-small-mlx ./process.sh --all
```

## Python Environment

**Virtual Env Path:** `$HOME/mlx-whisper-env/bin/activate`

**Core Packages:**
- `mlx-whisper==0.4.3`
- `opencc-python-reimplemented==0.1.7`

**Verify Environment:**
```bash
source "$HOME/mlx-whisper-env/bin/activate"
python -V
pip show mlx-whisper opencc-python-reimplemented
```

## Output Files

| File | Description |
|------|-------------|
| `output/<name>_final.mp4` | Final compressed video with burned subtitles |
| `output/srt/<name>.srt` | SRT subtitle file |
| `output/srt/<name>.ass` | ASS subtitle file (for FFmpeg) |
| `output/numbered/<name>_numbered.mp4` | Video with overlay number |

## Important Notes

1. **Virtual Environment:** Scripts assume fixed path `$HOME/mlx-whisper-env/bin/activate`
2. **Offline Mode:** Model must be downloaded locally; disable `HF_HUB_OFFLINE` for initial download
3. **Export Mode:** Requires pre-existing `.ass` subtitle files
4. **Hardware Encoding:** Auto-detects `h264_videotoolbox` on Apple Silicon for faster processing
5. **Input/Output:** Both directories are git-ignored; safe for large video files

## Quick Diagnostics

```bash
# Check system tools
ffmpeg -version && ffprobe -version

# Check Python environment
source "$HOME/mlx-whisper-env/bin/activate" && pip show mlx-whisper

# Test single file
./process.sh <video.mp4>

# Check encoder detection
VIDEO_ENCODER=auto ./process.sh --export
```
