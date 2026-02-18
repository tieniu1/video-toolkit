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
    ├─ compress.sh / compress-m4.sh ──→ HEVC 深度压缩
    └─ add_number.sh ──→ 画面叠加序号
```

## 目录结构

```
video/
├── input/                # 源视频
├── output/
│   ├── srt/              # .srt / .ass 字幕
│   ├── numbered/         # 叠加序号后的视频
│   └── *_final.mp4       # 成品视频
├── compress/output/      # 压缩后的视频
├── process.sh            # 主流程：识别 + 字幕 + 合成
├── compress.sh           # 通用压缩 (3 种模式)
├── compress-m4.sh        # M4 专用极致压缩
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

### compress.sh — 通用压缩

```bash
./compress.sh video.mp4    # 单文件压缩
./compress.sh --all        # 批量压缩 input/ 下所有视频
```

编码器自动检测优先级：`hevc_videotoolbox` > `h264_videotoolbox` > `libx265` > `libx264`

三种模式通过 `MODE` 切换：

| 模式 | 特点 |
|------|------|
| `speed` | 硬编优先，最快 |
| `balanced` | 默认，画质/体积平衡 |
| `quality` | CPU 编码优先，最佳画质 |

### compress-m4.sh — M4 专用压缩

```bash
MODE=speed ./compress-m4.sh --all   # 直播录屏激进压缩 (q=38)
```

M4 media engine 专用路径，`hevc_videotoolbox` 硬编，CPU 占用极低。默认 3 路并行。

### trim_videos.sh — 裁剪

在脚本内配置 `TASKS=("文件|开始时间|结束时间")`，支持 `copy`（快速）和 `reencode`（精确）两种模式。

### add_number.sh — 叠加序号

```bash
./add_number.sh video.mp4 42    # 单文件叠加数字
./add_number.sh --all 1         # 批量编号，从 1 开始
```

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
| `PARALLEL` | `3`-`4` | 批量并行数 |
| `MAX_HEIGHT` | `960` | 压缩最大高度 |
| `AUDIO_BITRATE` | `48k`-`80k` | 音频码率 |

## 关键技术决策

- **静态封面策略**：导出时抽首帧 → `-loop 1` 生成静态视频，避免对全片做滤镜，配合低帧率 (FPS=2) 大幅提速
- **MLX 原生推理**：`mlx-whisper` 直接在 Apple Silicon Neural Engine 上运行，比 CPU Whisper 快数倍
- **离线模式**：`HF_HUB_OFFLINE=1` 避免每次启动检查模型更新
- **双压缩脚本**：`compress.sh` 通用兼容，`compress-m4.sh` 针对 M4 media engine 深度调参（更低码率、更激进量化）
- **ASS 字幕**：竖屏分辨率 576×1280，直接 `ffmpeg -vf ass=` 烧录，无需额外字体配置
