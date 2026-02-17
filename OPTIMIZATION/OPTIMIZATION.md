# 视频处理脚本优化建议

## 项目流程概览

1. `trim_videos.sh` — 裁剪视频片段
2. `transcribe.py` — AI 语音识别生成 SRT/ASS 字幕
3. `process.sh` — 主流程：识别字幕 → 合成最终视频（封面图+音频+字幕）
4. `add_number.sh` — 在视频上叠加数字编号

---

## 核心瓶颈分析

### 1. process.sh 的 export_video — 最大瓶颈

当前命令：
```bash
ffmpeg -y -loop 1 -i "$cover" -i "$input_path" \
  -vf "fps=${OUTPUT_FPS},ass=$ass" \
  "${vcodec_args[@]}" -c:a copy -map 0:v:0 -map 1:a:0 -t "$duration_full" -shortest
```

问题：
- 用静态封面图 loop 作为视频源，ffmpeg 需要对每一帧都做 ASS 字幕渲染 + 编码，即使画面几乎不变
- `h264_videotoolbox` 用 CBR `2500k` 码率 — 对静态画面+字幕**严重偏高**，浪费体积
- `libx264` 用 `crf 23` + `ultrafast` — ultrafast 生成的文件体积比 medium 大 2-3 倍，对静态画面压缩效率极低

### 2. add_number.sh — 二次重编码

对已编码好的 `_final.mp4` 再做一次完整重编码，速度慢且画质损失。
`ultrafast` preset 生成体积大，没有指定 CRF 导致压缩效率差。

### 3. trim_videos.sh — 问题较小

`copy` 模式已是最优（stream copy，不重编码），无需优化。

---

## 优化建议

### P0: process.sh — 改用 CRF 模式 + 更好的 preset（影响最大）

**libx264 路径：**
```bash
# 当前
-c:v libx264 -preset ultrafast -tune stillimage -crf 23

# 建议
-c:v libx264 -preset fast -tune stillimage -crf 28
```

- `crf 23→28`：静态画面+字幕场景下视觉几乎无差别，体积减少约 40-50%
- `ultrafast→fast`：压缩效率提升显著（体积再减 30-40%），fps=2 帧数极少实际耗时增加可忽略
- 综合效果：**体积可能缩小到原来的 1/3，编码速度基本不变**

**h264_videotoolbox 路径：**
```bash
# 当前
-c:v h264_videotoolbox -b:v 2500k

# 建议
-c:v h264_videotoolbox -q:v 65 -allow_sw 1
```

- 用质量模式 `-q:v` 替代固定码率，静态画面自动降低码率

### P1: 合并 add_number 到 export_video 流程

当前流程：`process.sh` 编码一次 → `add_number.sh` 再编码一次 = 双倍时间 + 画质损失。

**推荐方案：将数字叠加合并到 export_video 的 -vf 滤镜链中**
```bash
-vf "fps=${OUTPUT_FPS},ass=$ass,drawtext=text='${number}':fontsize=h/12:fontcolor=white:borderw=3:bordercolor=black:x=(w-text_w)/2:y=h*2/3"
```
一次编码完成所有效果，省掉整个 add_number.sh 的重编码步骤。

**如果必须分开，优化 add_number.sh 编码参数：**
```bash
# 当前
-c:v libx264 -preset ultrafast

# 建议
-c:v libx264 -preset fast -crf 28 -tune stillimage
```

### P1: 识别前提取 16kHz WAV

当前直接把视频文件传给 whisper，大视频文件需要先解码音频流。

```bash
# 在 process.sh 中，识别前先提取音频
ffmpeg -y -i "$input_path" -vn -acodec pcm_s16le -ar 16000 -ac 1 "/tmp/${name}.wav"
# 然后传 wav 给 transcribe.py
```

- 16kHz 单声道 WAV 是 whisper 的原生输入格式
- 避免 whisper 内部重复解码大视频文件
- 对长视频（>10分钟）识别速度有明显提升

### P2: add_number.sh 单独优化

```bash
# 建议
-c:v libx264 -preset fast -crf 28 -tune stillimage
```

### P2: 多视频并行处理

当前 `--all` 模式串行处理，可用 `xargs -P` 并行：
```bash
find "$INPUT_DIR" -name "*.mp4" | xargs -P 2 -I {} bash -c 'process_video "$(basename "{}")"'
```
注意：whisper 模型占内存，并行数取决于可用内存，2 路并行通常可行。

---

## 优化优先级总结

| 优先级 | 优化项 | 预期效果 |
|--------|--------|----------|
| **P0** | process.sh: CRF 28 + preset fast | 体积减 60-70%，速度基本不变 |
| **P0** | process.sh: videotoolbox 改质量模式 | 体积减 50%+ |
| **P1** | 合并 add_number 到 export_video | 省掉一次完整重编码 |
| **P1** | 识别前提取 16kHz WAV | 加速语音识别 |
| **P2** | add_number.sh 单独优化 preset/crf | 体积减小，速度略提升 |
| **P2** | 多视频并行处理 | 总耗时减半（多视频场景） |
