#!/usr/bin/env bash
set -euo pipefail

########## 基本参数（按需改） ##########
# 输出模式：fifo|udp|http|file
MODE=${MODE:-fifo}

# fifo/file 路径（给 GRC 的 File Source 用）
TS_PATH=${TS_PATH:-$HOME/桌面/camera_live.ts}

# udp/http 目标
TARGET_HOST=${TARGET_HOST:-127.0.0.1}
TARGET_PORT=${TARGET_PORT:-1234}
HTTP_PATH=${HTTP_PATH:-/cam}

# 编码前统一规格
WIDTH=${WIDTH:-960}
HEIGHT=${HEIGHT:-540}
FPS=${FPS:-25}

# 码率设置（恒定）
VID_BR=${VID_BR:-1600k}
AUD_BR=${AUD_BR:-128k}

# —— 关键：TS 的复用码率（CBR，总包率）——
# QPSK 3/4 @ Rs≈1.666Msym/s 的推荐值：
MUXRATE=${MUXRATE:-2300k}
# 若换成 QPSK 1/4，请改为： MUXRATE=750k

# 设备
VIDEO_DEV=${VIDEO_DEV:-/dev/video0}
AUDIO_DEV=${AUDIO_DEV:-hw:0}

# 环境修正（可留）
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libgomp.so.1
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}

command -v ffmpeg >/dev/null || { echo "请先安装：sudo apt-get update && sudo apt-get install -y ffmpeg v4l-utils alsa-utils"; exit 1; }
command -v v4l2-ctl >/dev/null || { echo "请先安装：sudo apt-get install -y v4l-utils"; exit 1; }

########## 摄像头检测 ##########
if [ ! -e "$VIDEO_DEV" ]; then
  CAND=$(ls /dev/video* 2>/dev/null | head -n1 || true)
  if [ -n "${CAND:-}" ]; then VIDEO_DEV="$CAND"; else echo "未找到摄像头 (/dev/videoX)"; exit 1; fi
fi

########## 关闭自动对焦/自动白平衡等以稳定时序 ##########
CTL_LIST=$(v4l2-ctl -d "$VIDEO_DEV" -l 2>/dev/null || true)
for k in focus_auto focus_automatic_continuous focus_one_push focus_oneshot autofocus; do
  if echo "$CTL_LIST" | grep -q "^$k"; then v4l2-ctl -d "$VIDEO_DEV" -c ${k}=0 || true; fi
done
if echo "$CTL_LIST" | grep -q '^exposure_auto'; then v4l2-ctl -d "$VIDEO_DEV" -c exposure_auto=1 || true; fi  # 1=Manual
if echo "$CTL_LIST" | grep -q '^white_balance_temperature_auto'; then v4l2-ctl -d "$VIDEO_DEV" -c white_balance_temperature_auto=0 || true; fi
if echo "$CTL_LIST" | grep -q '^power_line_frequency'; then v4l2-ctl -d "$VIDEO_DEV" -c power_line_frequency=1 || true; fi  # 50Hz

########## 选择采集格式 ##########
if v4l2-ctl -d "$VIDEO_DEV" --list-formats-ext 2>/dev/null | grep -q 'MJPG'; then
  IN_FMT=mjpeg
else
  IN_FMT=yuyv422
fi
CAP_SIZE=${CAP_SIZE:-640x480}
CAP_FPS=${CAP_FPS:-30}

echo "==> 摄像头: $VIDEO_DEV  采集 ${CAP_SIZE}@${CAP_FPS}  输入格式=${IN_FMT}"
if arecord -l >/dev/null 2>&1; then
  HAVE_AUDIO=1; echo "==> 麦克风: $AUDIO_DEV"
else
  HAVE_AUDIO=0; echo "==> 未检测到麦克风，将仅编码视频"
fi

########## FFmpeg 输入与编码参数 ##########
FFIN_COMMON=(
  -hide_banner -loglevel warning -y
  -fflags +genpts+nobuffer -flags low_delay -re
  -use_wallclock_as_timestamps 1
  -thread_queue_size 4096
  -f v4l2 -ts mono2abs
  -input_format "${IN_FMT}" -framerate "${CAP_FPS}" -video_size "${CAP_SIZE}" -i "${VIDEO_DEV}"
)
if [ "$HAVE_AUDIO" -eq 1 ]; then
  FFIN_AUD=(-thread_queue_size 4096 -f alsa -itsoffset 0.02 -i "${AUDIO_DEV}")
  MAP_AUD=(-map 1:a:0 -streamid 1:257 -c:a aac -b:a "${AUD_BR}" -ar 48000 -ac 2)
else
  FFIN_AUD=()
  MAP_AUD=()
fi

FFENC_COMMON=(
  -vf "scale=${WIDTH}:${HEIGHT},fps=${FPS},format=yuv420p"
  -vsync cfr
  -c:v libx264 -preset veryfast -profile:v baseline -level 3.1 -tune zerolatency
  -g "${FPS}" -keyint_min "${FPS}"
  -x264-params "scenecut=0:repeat-headers=1:nal-hrd=cbr"
  -bsf:v h264_metadata=aud=insert
  -b:v "${VID_BR}" -maxrate "${VID_BR}" -minrate "${VID_BR}" -bufsize "${VID_BR}"
  -map 0:v:0 -streamid 0:256
  "${MAP_AUD[@]}"
  -f mpegts
  # ——TS层稳态设置——
  -muxpreload 0 -muxdelay 0
  -mpegts_flags +resend_headers+initial_discontinuity
  -pat_period 0.2 -pmt_period 0.2     # 表周期 200 ms
  -pcr_period 20                      # PCR 周期 20 ms
  -metadata service_provider="cam2net" -metadata service_name="USB Cam"
)

########## 输出 ##########
case "$MODE" in
  fifo)
    # 给 GRC 的 File Source 用（Repeat=No；Unbuffered=On 更好）
    mkdir -p "$(dirname "$TS_PATH")"
    [ -p "$TS_PATH" ] || { rm -f "$TS_PATH" 2>/dev/null || true; mkfifo "$TS_PATH"; }
    echo "==> 输出到 FIFO: $TS_PATH  (muxrate=${MUXRATE})"
    ffmpeg "${FFIN_COMMON[@]}" "${FFIN_AUD[@]}" \
      "${FFENC_COMMON[@]}" -muxrate "${MUXRATE}" \
      -pkt_size 1316 -f mpegts "file:$TS_PATH"
    ;;
  file)
    echo "==> 输出到文件: $TS_PATH  (muxrate=${MUXRATE})"
    ffmpeg "${FFIN_COMMON[@]}" "${FFIN_AUD[@]}" \
      "${FFENC_COMMON[@]}" -muxrate "${MUXRATE}" \
      -pkt_size 1316 -y "$TS_PATH"
    ;;
  udp)
    echo "==> 推流：UDP 到 udp://${TARGET_HOST}:${TARGET_PORT} (pkt_size=1316, muxrate=${MUXRATE})"
    ffmpeg "${FFIN_COMMON[@]}" "${FFIN_AUD[@]}" \
      "${FFENC_COMMON[@]}" -muxrate "${MUXRATE}" \
      "udp://${TARGET_HOST}:${TARGET_PORT}?pkt_size=1316&fifo_size=67108864&overrun_nonfatal=1"
    ;;
  http)
    echo "==> 推流：HTTP 到 http://${TARGET_HOST}:${TARGET_PORT}${HTTP_PATH} (muxrate=${MUXRATE})"
    ffmpeg "${FFIN_COMMON[@]}" "${FFIN_AUD[@]}" \
      "${FFENC_COMMON[@]}" -muxrate "${MUXRATE}" \
      -listen 1 "http://${TARGET_HOST}:${TARGET_PORT}${HTTP_PATH}"
    ;;
  *)
    echo "不支持的 MODE=${MODE}，可用：fifo | file | udp | http"; exit 1;;
esac
