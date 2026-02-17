# 视频处理脚本优化方案

**目标：** 在不降低音质、不影响观看体验的前提下，加快生成速度、减少输出体积。

**分析日期：** 2026-02-17

---

## 一、当前流程分析

### 1.1 处理链路

```
源视频 → trim_videos.sh (可选裁剪)
       → process.sh (字幕识别 + 视频合成)
       → add_number.sh (可选编号叠加)
       → 最终输出
```

### 1.2 各脚本职责

| 脚本 | 功能 | 编码方式 |
|------|------|----------|
| `trim_videos.sh` | 视频裁剪 | copy 模式（无重编码）|
| `transcribe.py` | 语音识别生成字幕 | 无视频处理 |
| `process.sh` | 主流程：封面 + 音频 + 字幕合成 | h264_videotoolbox / libx264 |
| `add_number.sh` | 叠加数字编号 | libx264 重编码 |

### 1.3 示例视频参数

```
codec: h264
分辨率：576x1280 (竖屏)
时长：~64 分钟
```

---

## 二、瓶颈分析

### 2.1 process.sh - 主要瓶颈

**当前编码参数：**

```bash
# libx264 路径
-c:v libx264 -preset ultrafast -tune stillimage -crf 23

# h264_videotoolbox 路径
-c:v h264_videotoolbox -b:v 2500k -allow_sw 1
```

**问题：**

1. **ultrafast preset** 压缩效率最低，生成的文件比 `fast` preset 大 2-3 倍
2. **CRF 23** 对静态封面画面过高，视觉无损场景可用更高值
3. **固定码率 2500k** 对静态画面严重浪费（实际可能只需 500-800k）
4. 静态封面 +2fps 场景下，更高效的 preset 几乎不增加耗时

### 2.2 add_number.sh - 二次编码浪费

**问题：**

1. 对已编码的 `_final.mp4` 再次完整重编码
2. 使用 `ultrafast` preset，体积效率差
3. 两次编码导致画质累积损失

### 2.3 transcribe.py - 音频解码开销

**问题：**

1. 直接传入视频文件，MLX-Whisper 内部需解码音频流
2. 对长视频（>30 分钟）有额外开销

---

## 三、优化方案

### 方案 1：process.sh 编码参数优化（P0 - 最高优先级）

#### libx264 路径修改

```diff
# 当前
- vcodec_args=(-c:v libx264 -preset ultrafast -tune stillimage -crf 23)

# 改为
+ vcodec_args=(-c:v libx264 -preset fast -tune stillimage -crf 28)
```

#### h264_videotoolbox 路径修改

```diff
# 当前
- vcodec_args=(-c:v h264_videotoolbox -b:v "$VIDEO_BITRATE" -allow_sw 1)

# 改为
+ vcodec_args=(-c:v h264_videotoolbox -q:v 70 -allow_sw 1)
```

#### 预期效果

| 指标 | 改善幅度 |
|------|----------|
| 输出体积 | **减少 60-70%** |
| 编码速度 | 基本不变或略快 |
| 画质 | 视觉无损（静态画面场景） |

---

### 方案 2：语音识别前提取音频（P1 - 中优先级）

#### 修改位置：process.sh

在调用 `transcribe.py` 之前：

```bash
# 提取 16kHz 单声道 WAV（Whisper 原生输入格式）
AUDIO_WAV="/tmp/${name}_audio.wav"
ffmpeg -y -i "$input_path" -vn -acodec pcm_s16le -ar 16000 -ac 1 "$AUDIO_WAV" 2>/dev/null

# 修改 transcribe.py 调用，传入 WAV 而非视频
source "$WHISPER_ENV" && python "$TRANSCRIBE_PY" "$AUDIO_WAV" "$srt"

# 清理临时文件
rm -f "$AUDIO_WAV"
```

#### 预期效果

| 指标 | 改善幅度 |
|------|----------|
| 识别速度 | **提升 10-20%**（长视频更明显） |
| 内存占用 | 略降 |

---

### 方案 3：add_number.sh 参数优化（P2 - 低优先级）

#### 修改内容

```diff
# 当前
- ffmpeg -y -i "$input_path" \
-   -vf "drawtext=..." \
-   -c:v libx264 -preset ultrafast -c:a copy "$numbered"

# 改为
+ ffmpeg -y -i "$input_path" \
+   -vf "drawtext=..." \
+   -c:v libx264 -preset fast -crf 28 -tune stillimage -c:a copy "$numbered"
```

#### 更优方案：合并到 process.sh

将数字叠加直接合并到 `export_video` 的滤镜链，避免二次编码：

```bash
# 在 process.sh 的 -vf 中添加 drawtext
-vf "fps=${OUTPUT_FPS},ass=$ass,drawtext=text='${NUMBER}':fontsize=h/12:fontcolor=white:borderw=3:bordercolor=black:x=(w-text_w)/2:y=h*2/3"
```

#### 预期效果

| 指标 | 改善幅度 |
|------|----------|
| 输出体积 | **减少 40%** |
| 处理速度 | **提升 20%** |
| 画质 | 避免二次编码损失 |

---

### 方案 4：trim_videos.sh（无需修改）

当前使用 `-c copy` 流复制模式，无重编码，已是最优状态。

---

## 四、实施优先级

| 优先级 | 方案 | 实施难度 | 体积收益 | 速度收益 |
|--------|------|----------|----------|----------|
| **P0** | process.sh 编码参数优化 | 低 | -60~70% | 不变 |
| **P1** | 识别前提取音频 | 中 | - | +15% |
| **P2** | add_number.sh 优化 | 低 | -40% | +20% |
| **P2** | 合并编号到主流程 | 中 | -100%* | +100%* |

> *指编号步骤的体积和耗时降为 0（避免二次编码）

---

## 五、推荐实施步骤

### 第一步：修改 process.sh 编码参数（立即实施）

修改 `process.sh` 第 22-26 行：

```bash
local -a vcodec_args
if [ "$ENCODER_SELECTED" = "h264_videotoolbox" ]; then
  vcodec_args=(-c:v h264_videotoolbox -q:v 70 -allow_sw 1)
else
  vcodec_args=(-c:v libx264 -preset fast -tune stillimage -crf 28)
fi
```

### 第二步：添加音频提取（可选）

在 `process.sh` 的 `process_video` 函数中，语音识别前添加音频提取步骤。

### 第三步：优化 add_number.sh（可选）

如需频繁使用编号功能，建议将 drawtext 滤镜合并到 process.sh。

---

## 六、测试验证

### 对比测试方法

```bash
# 1. 使用优化前参数处理一个视频
VIDEO_BITRATE=2500k ./process.sh <video.mp4>
ls -lh output/*_final.mp4

# 2. 使用优化后参数处理同一视频
./process.sh <video.mp4>
ls -lh output/*_final.mp4

# 3. 对比体积和画质
```

### 预期对比结果

| 指标 | 优化前 | 优化后 |
|------|--------|--------|
| 60 分钟视频体积 | ~800MB | ~250MB |
| 编码耗时 | 基准 | 基本不变 |
| 字幕清晰度 | 基准 | 相同 |
| 音质 | 原始 | 原始（copy） |

---

## 七、环境变量参考

```bash
# 使用 libx264（软件编码，兼容性最好）
VIDEO_ENCODER=libx264 ./process.sh --all

# 使用 videotoolbox（硬件编码，M 芯片加速）
VIDEO_ENCODER=h264_videotoolbox ./process.sh --all

# 自定义质量（仅 videotoolbox）
# q:v 范围 0-100，值越小质量越高
# 推荐 65-75（静态画面场景）

# 自定义 CRF（仅 libx264）
# CRF 范围 0-51，值越小质量越高
# 推荐 26-30（静态画面场景）
```

---

## 八、常见问题

### Q1: CRF 28 会不会画质太差？

**答：** 不会。CRF 是质量模式，对静态封面画面，CRF 28 与 CRF 23 在视觉上几乎无差别，因为：
- 画面静止，无运动模糊
- 字幕是矢量渲染，不受 CRF 影响
- FFmpeg 会自动在平坦区域使用更低码率

### Q2: preset fast 会不会很慢？

**答：** 不会明显变慢。因为：
- `OUTPUT_FPS=2`，每秒仅 2 帧
- 60 分钟视频仅 7200 帧，远低于正常视频的 10 万帧
- 静态画面编码速度远快于动态画面

### Q3: 为什么不用 265/HEVC？

**答：** 考虑兼容性。H.264 在所有设备和平台都能播放，HEVC 在部分旧设备/软件上可能无法解码。如需更小体积且确定播放环境支持，可改用 `hevc_videotoolbox` 或 `libx265`。

---

## 九、进阶优化（可选）

### 9.1 使用 HEVC 编码

```bash
# videotoolbox HEVC
vcodec_args=(-c:v hevc_videotoolbox -q:v 70 -allow_sw 1)

# libx265
vcodec_args=(-c:v libx265 -preset fast -crf 30 -tune stillimage)
```

**效果：** 体积再减少 30-40%，但兼容性下降。

### 9.2 并行处理多个视频

```bash
# 修改 process.sh 的 --all 模式，使用 xargs 并行
find "$INPUT_DIR" -name "*.mp4" -print0 | \
  xargs -0 -P 2 -I {} bash -c './process.sh "$(basename "{}")"'
```

**注意：** 并行数取决于可用内存，Whisper 模型占用约 2-4GB。

### 9.3 使用更快的 Whisper 模型

```bash
# 默认：large-v3-turbo-4bit（最准确，较慢）
# 可选：small-mlx, medium-mlx（更快，略低准确率）

WHISPER_MODEL=mlx-community/whisper-small-mlx ./process.sh --all
```

---

## 十、总结

**核心优化：**

1. ✅ **CRF 28 + preset fast** - 体积减少 60-70%，速度不变
2. ✅ **质量模式替代固定码率** - 静态画面自动降低码率
3. ✅ **提取音频再识别** - 识别速度提升 10-20%
4. ✅ **避免二次编码** - 合并编号步骤或优化参数

**实施后预期：**

- 60 分钟视频从 ~800MB 降至 **~250MB**
- 处理速度 **基本不变或略快**
- 音质 **完全保留**（音频流 copy）
- 画质 **视觉无损**（静态画面 + 字幕场景）
