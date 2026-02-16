# video 项目说明

## 1. 电脑环境（当前机器）

以下信息来自当前目录下实际命令检测结果。
- MacBook Air （2025款、M4芯片） 16G+512G
- 系统: macOS 15.7.3 (Build 24G419)
- 内核/架构: Darwin 24.6.0 / arm64 (Apple Silicon)
- Shell: `/bin/zsh`
- Git: `2.39.5 (Apple Git-154)`
- Node.js: `v25.6.1`
- npm: `11.9.0`
- pnpm: `10.17.1`
- Python: `3.14.3`
- pip: `26.0`
- FFmpeg: `8.0`
- FFprobe: `8.0`

## 2. 项目用途

本项目用于批量处理竖屏视频，目标是：

- 自动语音识别生成中文字幕（简体）
- 生成 `srt` 与 `ass` 字幕
- 将视频压缩为“静态封面 + 原音频 + 烧录字幕”的成品文件
- 支持单文件、批量处理、仅导出、按时间段裁剪

## 3. 项目依赖工具

### 3.1 系统级依赖

- `bash`（脚本执行）
- `ffmpeg`（转码、合成、烧录字幕）
- `ffprobe`（获取时长等媒体信息）

### 3.2 Python 依赖（用于 `transcribe.py`）

运行环境脚本中约定为：

- 虚拟环境激活脚本: `$HOME/mlx-whisper-env/bin/activate`

核心包：

- `mlx-whisper==0.4.3`
- `opencc-python-reimplemented==0.1.7`

说明：

- `mlx-whisper` 用于中文语音识别（当前脚本使用 `mlx-community/whisper-large-v3-turbo-4bit`）
- `opencc` 用于繁体转简体（`t2s`）
- 脚本默认设置 `HF_HUB_OFFLINE=1`，离线模式下需要本地已有模型

## 4. 目录结构

```text
video/
├── input/              # 输入视频目录
├── output/
│   ├── srt/            # 识别出的字幕（.srt/.ass）
│   └── *_final.mp4     # 最终导出视频
├── process.sh          # 主流程脚本（识别 + 合成）
├── transcribe.py       # 语音识别与字幕生成
├── trim_videos.sh      # 批量按时间段裁剪
├── 流程.md             # 流程说明文档
├── 待处理/              # 额外素材目录（非主流程必需）
└── 测试导出/            # 测试输出目录（非主流程必需）
```

## 5. 脚本说明

### 5.1 `process.sh`

功能：主处理流程。

- `./process.sh <文件名>`: 处理单个视频（字幕 + 合成）
- `./process.sh --all`: 扫描 `input/` 批量处理，跳过已完成视频
- `./process.sh --export`: 仅导出最终视频（要求已有字幕）

处理结果：

- `output/<原文件名>_final.mp4`
- `output/srt/<原文件名>.srt`
- `output/srt/<原文件名>.ass`

### 5.2 `transcribe.py`

功能：

- 调用 `mlx_whisper.transcribe()` 进行中文语音识别
- 输出 `srt` 字幕
- 同时输出 `ass` 字幕（带样式，可直接用于 `ffmpeg ass=`）

关键点：

- 语言固定 `language="zh"`
- 字幕文本经过 `OpenCC("t2s")` 转简体
- `ASS` 分辨率按竖屏样式设置 (`PlayResX=576`, `PlayResY=1280`)

### 5.3 `trim_videos.sh`

功能：

- 通过 `TASKS=("文件|开始|结束")` 配置批量裁剪任务
- 输出文件名自动追加 `_trim`
- 支持两种模式：
  - `copy`：快，关键帧边界可能不精确
  - `reencode`：慢，但切点更准

## 6. 推荐使用流程

1. 将待处理视频放入 `input/`
2. 执行：`./process.sh --all`
3. 到 `output/` 获取成品视频，到 `output/srt/` 获取字幕

如果只想先裁剪再处理：

1. 在 `trim_videos.sh` 中配置 `TASKS`
2. 执行：`./trim_videos.sh`
3. 再执行：`./process.sh --all`

## 7. 快速检查命令

```bash
# 1) 检查系统工具
ffmpeg -version
ffprobe -version

# 2) 检查 Python 虚拟环境
source "$HOME/mlx-whisper-env/bin/activate"
python -V
pip show mlx-whisper opencc-python-reimplemented

# 3) 执行主流程
./process.sh --all
```

## 8. 注意事项

- `process.sh` 使用固定虚拟环境路径：`$HOME/mlx-whisper-env/bin/activate`，若路径变化需同步修改脚本。
- 离线模式下如未提前下载模型，识别会失败；可临时注释 `transcribe.py` 的离线环境变量后下载模型。
- `--export` 模式依赖 `output/srt/<name>.ass` 已存在。
