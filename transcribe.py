import sys
import os
import time
import subprocess
import argparse

# 下载模型时注释掉下1行代码
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

import mlx_whisper
from opencc import OpenCC

cc = OpenCC("t2s")

DEFAULT_MODEL = os.environ.get("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo-4bit")


def parse_args():
    parser = argparse.ArgumentParser(
        description="识别视频/音频并导出 SRT + ASS 字幕（普通话加速配置）"
    )
    parser.add_argument("input_file", help="输入视频或音频文件")
    parser.add_argument(
        "output_file",
        nargs="?",
        help="输出 srt 路径（可选，默认与输入同名）",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"mlx-whisper 模型（默认: {DEFAULT_MODEL}）",
    )
    return parser.parse_args()


args = parse_args()
input_file = args.input_file
output_file = args.output_file if args.output_file else input_file.rsplit(".", 1)[0] + ".srt"

duration = ""
try:
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", input_file],
        capture_output=True, text=True,
    )
    total_s = float(r.stdout.strip())
    m, s = divmod(int(total_s), 60)
    h, m = divmod(m, 60)
    duration = f" (时长 {h:02d}:{m:02d}:{s:02d})"
except Exception:
    pass

print(f"开始识别: {os.path.basename(input_file)}{duration}")
t0 = time.time()
result = mlx_whisper.transcribe(
    input_file,
    language="zh",
    path_or_hf_repo=args.model,
    temperature=0.0,
    condition_on_previous_text=False,
)
elapsed = time.time() - t0
print(f"识别完成，耗时 {elapsed:.1f}s，已生成字幕")

with open(output_file, "w", encoding="utf-8") as f:
    for i, s in enumerate(result["segments"], 1):
        sh, sr = divmod(s["start"], 3600)
        sm, ss = divmod(sr, 60)
        eh, er = divmod(s["end"], 3600)
        em, es = divmod(er, 60)

        start = f"{int(sh):02d}:{int(sm):02d}:{ss:06.3f}".replace(".", ",")
        end = f"{int(eh):02d}:{int(em):02d}:{es:06.3f}".replace(".", ",")

        text = cc.convert(s["text"].strip())
        f.write(f"{i}\n{start} --> {end}\n{text}\n\n")

# 同时输出 ASS 字幕（用于合成视频）
ass_file = output_file.rsplit(".", 1)[0] + ".ass"

def fmt_ass_time(seconds):
    h, r = divmod(seconds, 3600)
    m, s = divmod(r, 60)
    return f"{int(h)}:{int(m):02d}:{s:05.2f}"

ASS_HEADER = """[Script Info]
ScriptType: v4.00+
PlayResX: 576
PlayResY: 1280
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,58,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,3,0,8,20,20,350

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

def wrap_text(text, max_chars=14):
    lines = []
    while len(text) > max_chars:
        lines.append(text[:max_chars])
        text = text[max_chars:]
    if text:
        lines.append(text)
    return r"\N".join(lines)

with open(ass_file, "w", encoding="utf-8") as f:
    f.write(ASS_HEADER)
    for s in result["segments"]:
        start = fmt_ass_time(s["start"])
        end = fmt_ass_time(s["end"])
        text = cc.convert(s["text"].strip())
        text = wrap_text(text)
        f.write(f"Dialogue: 0,{start},{end},Default,,0,0,0,,{text}\n")
