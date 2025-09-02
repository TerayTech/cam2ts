#!/usr/bin/env bash
set -euo pipefail

########## 基本参数（可按需修改） ##########
# 输出：桌面 FIFO（命名管道）
if [ -d "$HOME/桌面" ]; then DESK="$HOME/桌面"; else DESK="$HOME/Desktop"; fi
FIFO_TS="$DESK/camera_live.ts"

# 目标输出视频规格（编码前会统一处理）
WIDTH=${WIDTH:-960}
HEIGHT=${HEIGHT:-540}
FPS=${FPS:-25}

# 码率（恒定），适配你后续DVB-T链路
VID_BR=${VID_BR:-1600k}
AUD_BR=${AUD_BR:-128k}
MUXRATE=${MUXRATE:-2000k}

# 设备（自动探测可覆盖）
VIDEO_DEV=${VIDEO_DEV:-/dev/video0}
AUDIO_DEV=${AUDIO_DEV:-hw:0}

# 对焦策略：优先自动对焦；若不支持自动对焦，则使用手动焦距值
MANUAL_FOCUS=${MANUAL_FOCUS:-120}   # 0~255 之间常见

# 运行环境修正：强制用系统 libgomp，避免旧库冲突
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libgomp.so.1
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}

command -v ffmpeg >/dev/null || { echo "请先安装：sudo apt-get update && sudo apt-get install -y ffmpeg v4l-utils alsa-utils"; exit 1; }
command -v v4l2-ctl >/dev/null || { echo "请先安装：sudo apt-get install -y v4l-utils"; exit 1; }

########## 摄像头存在性检查 ##########
if [ ! -e "$VIDEO_DEV" ]; then
  # 尝试找第一个 /dev/videoX
  CAND=$(ls /dev/video* 2>/dev/null | head -n1 || true)
  if [ -n "${CAND:-}" ]; then VIDEO_DEV="$CAND"; else echo "未找到摄像头 (/dev/videoX)"; exit 1; fi
fi

########## 创建 FIFO：若存在普通文件则改名备份 ##########
if [ -e "$FIFO_TS" ] && [ ! -p "$FIFO_TS" ]; then
  mv "$FIFO_TS" "${FIFO_TS}.bak.$(date +%s)"
fi
[ -p "$FIFO_TS" ] || mkfifo "$FIFO_TS"

########## 侦测并设置对焦/曝光/白平衡 ##########
# 列出控制项
CTL_LIST=$(v4l2-ctl -d "$VIDEO_DEV" -l 2>/dev/null || true)

# 连续自动对焦
if echo "$CTL_LIST" | grep -q '^focus_auto'; then
  v4l2-ctl -d "$VIDEO_DEV" -c focus_auto=1 || true
  echo "[i] 已尝试开启连续自动对焦 (focus_auto=1)"
elif echo "$CTL_LIST" | grep -q '^focus_automatic_continuous'; then
  v4l2-ctl -d "$VIDEO_DEV" -c focus_automatic_continuous=1 || true
  echo "[i] 已尝试开启连续自动对焦 (focus_automatic_continuous=1)"
fi

# 若没有自动对焦，但支持手动焦距
if echo "$CTL_LIST" | grep -q '^focus_absolute'; then
  # 如果确实没有任何自动对焦开关，则设定手动焦距
  if ! echo "$CTL_LIST" | grep -Eq '^(focus_auto|focus_automatic_continuous)'; then
    v4l2-ctl -d "$VIDEO_DEV" -c focus_absolute="$MANUAL_FOCUS" || true
    echo "[i] 自动对焦不可用，已设置手动焦距 focus_absolute=$MANUAL_FOCUS"
  fi
fi

# 自动曝光（尽量稳定）
if echo "$CTL_LIST" | grep -q '^exposure_auto'; then
  # 常见取值：1=Manual, 3=Aperture Priority (Auto)。取 3 让摄像头自适应。
  v4l2-ctl -d "$VIDEO_DEV" -c exposure_auto=3 || true
fi

# 自动白平衡
if echo "$CTL_LIST" | grep -q '^white_balance_temperature_auto'; then
  v4l2-ctl -d "$VIDEO_DEV" -c white_balance_temperature_auto=1 || true
fi

########## 选择输入格式：优先 MJPEG，其次 YUYV ##########
FMT_CHOSEN=yuyv422
if v4l2-ctl -d "$VIDEO_DEV" --list-formats-ext 2>/dev/null | grep -q 'MJPG'; then
  FMT_CHOSEN=mjpeg
fi

# 采集分辨率/帧率：很多摄像头会强制 640x480@30，我们统一编码时再 scale/fps
CAP_SIZE=${CAP_SIZE:-640x480}
CAP_FPS=${CAP_FPS:-30}

echo "==> 摄像头: $VIDEO_DEV  采集 $CAP_SIZE@$CAP_FPS  输入格式=$FMT_CHOSEN"
if arecord -l >/dev/null 2>&1; then
  HAVE_AUDIO=1; echo "==> 麦克风: $AUDIO_DEV"
else
  HAVE_AUDIO=0; echo "==> 未检测到麦克风，将仅编码视频"
fi
echo "==> 输出到 FIFO: $FIFO_TS"
echo "   提示：在 GRC 的 File Source 里选 $FIFO_TS，Repeat=No。先跑本脚本，再启动你的接收工程。"
echo "按 Ctrl+C 结束。"

########## 启动编码（写入 FIFO） ##########
if [ "$HAVE_AUDIO" -eq 1 ]; then
  ffmpeg -hide_banner -loglevel warning -y \
  -fflags +genpts+nobuffer -flags low_delay -re \
  -use_wallclock_as_timestamps 1 \
  -thread_queue_size 4096 \
  -f v4l2 -ts mono2abs \
  -input_format yuyv422 -framerate "$CAP_FPS" -video_size "$CAP_SIZE" -i "$VIDEO_DEV" \
  -thread_queue_size 4096 \
  -f alsa -itsoffset 0.02 -i "$AUDIO_DEV" \
  -vf "scale=${WIDTH}:${HEIGHT},fps=${FPS},format=yuv420p" \
  -vsync cfr \
  -c:v libx264 -preset veryfast -profile:v baseline -level 3.1 -tune zerolatency \
  -g "$FPS" -keyint_min "$FPS" \
  -x264-params "scenecut=0:repeat-headers=1:nal-hrd=cbr" \
  -bsf:v h264_metadata=aud=insert \
  -b:v "$VID_BR" -maxrate "$VID_BR" -minrate "$VID_BR" -bufsize "$VID_BR" \
  -c:a aac -b:a "$AUD_BR" -ar 48000 -ac 2 \
  -map 0:v:0 -streamid 0:256 \
  -map 1:a:0 -streamid 1:257 \
  -f mpegts \
  -muxrate 2500k -muxpreload 0 -muxdelay 0 \
  -mpegts_flags +resend_headers+initial_discontinuity \
  -flush_packets 1 \
  -metadata service_provider="cam2ts" -metadata service_name="USB Cam" \
  "$FIFO_TS"



else
  ffmpeg -hide_banner -loglevel warning -y \
  -fflags +genpts+nobuffer -flags low_delay -re \
  -use_wallclock_as_timestamps 1 \
  -thread_queue_size 4096 \
  -f v4l2 -ts mono2abs \
  -input_format yuyv422 -framerate "$CAP_FPS" -video_size "$CAP_SIZE" -i "$VIDEO_DEV" \
  -vf "scale=${WIDTH}:${HEIGHT},fps=${FPS},format=yuv420p" \
  -vsync cfr \
  -c:v libx264 -preset veryfast -profile:v baseline -level 3.1 -tune zerolatency \
  -g "$FPS" -keyint_min "$FPS" \
  -x264-params "scenecut=0:repeat-headers=1:nal-hrd=cbr" \
  -bsf:v h264_metadata=aud=insert \
  -b:v "$VID_BR" -maxrate "$VID_BR" -minrate "$VID_BR" -bufsize "$VID_BR" \
  -map 0:v:0 -streamid 0:256 \
  -f mpegts \
  -muxrate 2200k -muxpreload 0 -muxdelay 0 \
  -mpegts_flags +resend_headers+initial_discontinuity \
  -flush_packets 1 \
  -metadata service_provider="cam2ts" -metadata service_name="USB Cam" \
  "$FIFO_TS"


fi
