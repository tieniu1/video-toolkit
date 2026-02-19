# video — 竖屏视频批处理工具链

针对 Apple Silicon (M4) 优化的竖屏视频处理流水线：语音识别 → 字幕生成 → 字幕烧录 → 视频压缩。

## 技术栈

| 层级 | 工具 | 用途 |
|------|------|------|
| 语音识别 | `mlx-whisper` (large-v3-turbo-4bit) | MLX 加速的 Whisper，Apple Silicon 原生推理 |
| 繁简转换 | `opencc` (t2s) | Whisper 输出繁体 → 简体中文 |
| 视频处理 | `ffmpeg` / `ffprobe` | 转码、合成、字幕烧录、压缩 |
| 硬件加速 | VideoToolbox | `hevc_videotoolbox` / `h264_videotoolbox` 硬编码 |
| 运行环境 | Bash + Python 3 | 脚本编排 + AI 推理 |

## 处理流水线

```
input/*.mp4
    │
    ├─ [可选] trim_videos.sh ──→ 按时间段裁剪
    │
    ▼
process.sh ─────────────────────────────────────────────────
    │                                                       │
    │ ① 提取音频 (ffmpeg)                                    │
    │ ② 语音识别 (mlx-whisper, language=zh)                  │
    │ ③ 繁→简 (OpenCC t2s)                                   │
    │ ④ 生成 .srt + .ass 字幕                                │
    │ ⑤ 抽首帧封面 → 静态视频 + 原音频 + ASS 烧录             │
    │   编码器: h264_videotoolbox (auto) / libx264 (fallback) │
    │   帧率: OUTPUT_FPS=2 (静态封面场景)                      │
    │                                                        │
    ▼                                                        │
output/*_final.mp4 + output/srt/*.{srt,ass}                  │
─────────────────────────────────────────────────────────────

    │ [可选后处理]
    ├─ compress.sh ──→ HEVC 深度压缩 (顺序+进度条 / 并行)
    └─ add_number.sh ──→ 画面叠加序号
```

## 目录结构

```
video/
├── process-input/        # 源视频（process.sh 输入）
├── process-output/
│   ├── srt/              # .srt / .ass 字幕
│   ├── numbered/         # 叠加序号后的视频
│   └── *_final.mp4       # 成品视频
├── compress-input/       # 待压缩视频
├── compress-output/      # 压缩后的视频
├── process.sh            # 主流程：识别 + 字幕 + 合成
├── compress.sh           # M4 专用压缩
├── delete_originals.sh   # Android 设备源文件清理
├── transcribe.py         # 语音识别引擎
├── trim_videos.sh        # 批量裁剪
└── add_number.sh         # 画面叠加序号
```

## 脚本用法

### process.sh — 主流程

```bash
./process.sh video.mp4     # 单文件：识别 + 合成
./process.sh --all         # 批量处理 input/ 下所有视频
./process.sh --export      # 仅合成（需已有 .ass 字幕）
```

> **推荐默认使用 `--all`（顺序模式）**：并行压缩会导致 M4 芯片持续高负载发热，顺序模式温度更友好且带实时进度显示。

### compress.sh — M4 压缩

```bash
./compress.sh --all          # 顺序处理，带实时进度条（默认推荐）
./compress.sh --parallel     # 并行处理，速度更快
./compress.sh video.mp4      # 单文件压缩
```

M4 media engine 专用路径，`hevc_videotoolbox` 硬编（q=38），输出文件名为 `*_compressed.mp4`。并行模式默认 2 路并发，可通过 `PARALLEL` 环境变量调整。

### trim_videos.sh — 裁剪

在脚本内配置 `TASKS=("文件|开始时间|结束时间")`，支持 `copy`（快速）和 `reencode`（精确）两种模式。

### add_number.sh — 叠加序号

```bash
./add_number.sh video.mp4 42    # 单文件叠加数字
./add_number.sh --all 1         # 批量编号，从 1 开始
```

### delete_originals.sh — Android 源文件清理

通过 Termux 在 Android 设备上运行，批量删除已处理完的源视频释放手机空间。

**Termux 首次使用注意事项：**

1. **申请存储权限**（首次必须执行）：
   ```bash
   termux-setup-storage
   ```
   弹出权限对话框后点击「允许」，之后才能访问 `/sdcard/`。

2. **进入脚本所在目录后再执行**：
   ```bash
   cd /sdcard/Pictures
   bash delete_originals.sh
   ```
   脚本依赖相对路径，必须在 `/sdcard/Pictures` 目录下运行，否则路径解析会失败。

脚本内硬编码了待删除文件列表（`/sdcard/Pictures/Screenshots/` 下的视频），按需编辑文件名后运行。

## 环境配置

```bash
# 系统依赖
brew install ffmpeg

# Python 虚拟环境
python3 -m venv ~/mlx-whisper-env
source ~/mlx-whisper-env/bin/activate
pip install mlx-whisper==0.4.3 opencc-python-reimplemented==0.1.7

# 首次下载模型（之后可离线运行）
# 临时注释 transcribe.py 中的 HF_HUB_OFFLINE=1，运行一次即可缓存模型
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WHISPER_MODEL` | `mlx-community/whisper-large-v3-turbo-4bit` | 识别模型 |
| `VIDEO_ENCODER` | `auto` | 编码器 (`auto` / `h264_videotoolbox` / `libx264`) |
| `OUTPUT_FPS` | `2` | 导出帧率 |
| `MODE` | `balanced` | 压缩模式 (`speed` / `balanced` / `quality`) |
| `PARALLEL` | `2` | 并行数 (compress.sh --parallel) |
| `MAX_HEIGHT` | `960` | 压缩最大高度 |
| `AUDIO_BITRATE` | `48k`-`80k` | 音频码率 |

## 关键技术决策

- **静态封面策略**：导出时抽首帧 → `-loop 1` 生成静态视频，避免对全片做滤镜，配合低帧率 (FPS=2) 大幅提速
- **MLX 原生推理**：`mlx-whisper` 直接在 Apple Silicon Neural Engine 上运行，比 CPU Whisper 快数倍
- **离线模式**：`HF_HUB_OFFLINE=1` 避免每次启动检查模型更新
- **统一压缩入口**：`compress.sh` 合并了并行（`--parallel`）和顺序（`--all`）两种模式，顺序模式带实时进度条和全局压缩报告
- **ASS 字幕**：竖屏分辨率 576×1280，直接 `ffmpeg -vf ass=` 烧录，无需额外字体配置
