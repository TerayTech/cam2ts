# cam2ts
一个基于 **USB 摄像头 + 麦克风** 的实时 TS 流生成脚本。  
适用于 **GNU Radio DVB-T/DVB-S/DVB-S2** 演示等场景，可以将 USB 摄像头的视频和音频采集后，通过 `ffmpeg` 编码为 **MPEG-TS 格式**，并输出到桌面的 FIFO（命名管道）。  

## 功能特点

- 自动检测摄像头 (`/dev/videoX`) 和麦克风 (`hw:0`)  
- 优先使用 **MJPEG** 输入，否则回退到 **YUYV422**  
- 自动尝试开启 **连续自动对焦 / 曝光 / 白平衡**  
- 不支持自动对焦时，允许使用 **手动焦距**（默认 120，可调整）  
- 视频参数统一编码为：
  - 分辨率：960×540（可修改）
  - 帧率：25 fps（可修改）
  - 视频码率：1600 kbps（恒定码率）
  - 音频码率：128 kbps，AAC 编码
- 输出 **MPEG-TS 流** 到桌面 FIFO：  
  `~/桌面/camera_live.ts` 或 `~/Desktop/camera_live.ts`
- 兼容 **GNU Radio GRC File Source**：只需选择该 FIFO 文件，`Repeat=No`

## 使用方法

1. 克隆仓库并赋予执行权限：
   ```bash
   git clone https://github.com/yourname/cam2ts.git
   cd cam2ts
   chmod +x cam2ts.sh
   ````

2. 确保已安装依赖：

   ```bash
   sudo apt-get update
   sudo apt-get install -y ffmpeg v4l-utils alsa-utils
   ```

3. 运行脚本：

   ```bash
   ./cam2ts.sh
   ```

   输出示例：

   ```
   ==> 摄像头: /dev/video0  采集 640x480@30  输入格式=mjpeg
   ==> 麦克风: hw:0
   ==> 输出到 FIFO: /home/user/桌面/camera_live.ts
   提示：在 GRC 的 File Source 里选 /home/user/桌面/camera_live.ts，Repeat=No。先跑本脚本，再启动你的接收工程。
   ```

4. 在 **GNU Radio** 中添加 `File Source`，选择生成的 FIFO (`camera_live.ts`)，即可实时读取视频流。

5. 按 `Ctrl+C` 结束脚本。


## 可调参数

在运行脚本前，可以通过环境变量修改默认参数，例如：

```bash
WIDTH=1280 HEIGHT=720 FPS=30 VID_BR=2000k ./cam2ts.sh
```

* `WIDTH` / `HEIGHT`：输出视频分辨率（默认 960×540）
* `FPS`：输出帧率（默认 25 fps）
* `VID_BR`：视频码率（默认 1600k）
* `AUD_BR`：音频码率（默认 128k）
* `MANUAL_FOCUS`：手动焦距值（0–255，默认 120）
* `VIDEO_DEV` / `AUDIO_DEV`：设备节点（默认 `/dev/video0` 和 `hw:0`）


## 适用场景

* DVB-T/DVB-S/DVB-S2 SDR 实验
* GNU Radio 视频流演示
* 自制实时视频广播链路


## 许可证

MIT License


