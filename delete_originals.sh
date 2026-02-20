#!/bin/bash
CAM="/sdcard/DCIM/Camera"
SCR="/sdcard/DCIM/ScreenRecorder"
count=0
[ -f "$SCR/Screenrecorder-2025-03-31-21-09-21-347_m4_opt.mp4" ] && rm "$SCR/Screenrecorder-2025-03-31-21-09-21-347_m4_opt.mp4" && echo "已删除: Screenrecorder-2025-03-31-21-09-21-347_m4_opt.mp4" && count=$((count+1)) || echo "未找到: Screenrecorder-2025-03-31-21-09-21-347_m4_opt.mp4"
[ -f "$SCR/Screenrecorder-2025-05-12-20-30-23-260_m4_opt.mp4" ] && rm "$SCR/Screenrecorder-2025-05-12-20-30-23-260_m4_opt.mp4" && echo "已删除: Screenrecorder-2025-05-12-20-30-23-260_m4_opt.mp4" && count=$((count+1)) || echo "未找到: Screenrecorder-2025-05-12-20-30-23-260_m4_opt.mp4"
[ -f "$SCR/Screenrecorder-2025-05-14-20-36-05-124_m4_opt.mp4" ] && rm "$SCR/Screenrecorder-2025-05-14-20-36-05-124_m4_opt.mp4" && echo "已删除: Screenrecorder-2025-05-14-20-36-05-124_m4_opt.mp4" && count=$((count+1)) || echo "未找到: Screenrecorder-2025-05-14-20-36-05-124_m4_opt.mp4"
[ -f "$SCR/Screenrecorder-2025-05-19-20-08-24-463_m4_opt.mp4" ] && rm "$SCR/Screenrecorder-2025-05-19-20-08-24-463_m4_opt.mp4" && echo "已删除: Screenrecorder-2025-05-19-20-08-24-463_m4_opt.mp4" && count=$((count+1)) || echo "未找到: Screenrecorder-2025-05-19-20-08-24-463_m4_opt.mp4"
[ -f "$SCR/Screenrecorder-2025-05-29-07-30-40-246_m4_opt.mp4" ] && rm "$SCR/Screenrecorder-2025-05-29-07-30-40-246_m4_opt.mp4" && echo "已删除: Screenrecorder-2025-05-29-07-30-40-246_m4_opt.mp4" && count=$((count+1)) || echo "未找到: Screenrecorder-2025-05-29-07-30-40-246_m4_opt.mp4"
[ -f "$CAM/VID_20250304_203205_m4_opt.mp4" ] && rm "$CAM/VID_20250304_203205_m4_opt.mp4" && echo "已删除: VID_20250304_203205_m4_opt.mp4" && count=$((count+1)) || echo "未找到: VID_20250304_203205_m4_opt.mp4"
[ -f "$CAM/VID_20250305_202333_m4_opt.mp4" ] && rm "$CAM/VID_20250305_202333_m4_opt.mp4" && echo "已删除: VID_20250305_202333_m4_opt.mp4" && count=$((count+1)) || echo "未找到: VID_20250305_202333_m4_opt.mp4"
echo "完成，共删除 $count 个文件"
