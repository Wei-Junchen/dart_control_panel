# Android 内测（横屏）

## 安装与连接

- Android 7.0 / API 24 及以上，当前发行包面向 `arm64-v8a`。启动后固定为传感器横屏（允许左右翻转）。Android 16 大屏采用平台提供的临时兼容属性；未来提高 target API 需重新验证横屏策略。
- 手机（窗口短边小于600逻辑像素）统一使用85%界面缩放，包含文字、图标、间距和弹窗；左侧导航约34dp宽，图标保持原大小并整体下移，长按显示页面名称。四页工具栏统一为28逻辑像素（缩放后约24dp）；Board Connect 收入左侧底部按钮，点按弹出地址与连接面板。横屏遥测以曲线为主、Channels 在右侧列表；姿态与目标通过顶栏按钮查看。桌面和平板保持原尺寸，系统字体缩放设置仍保留。
- 手机先手动连接板端 AP；遇到“无互联网”请选择保持连接。**AP 地址 `10.198.137.1`，TCP 9000**；电脑 USB 地址 `10.137.198.1` 不是手机应填写的地址。
- App 只把自身网络流量绑定到当前 Wi-Fi，避免板端 AP 无互联网时 TCP/UDP 误走蜂窝网络；不改变手机的全局网络配置。UDP 监听1347，文件服务9002，地面 RTSP8554。
- Connect 后可在 Mode 切 Ground，手动调整图像/识别参数，进入 Diagnostics 查看 schema、状态、worker 日志并复制诊断摘要。Flight 的调参锁定与板端保持一致。测试中不要误触 `set_flight_active`；客户端断连不影响板端本地记录。
- 保持 App 前台。当前不承诺 Android 后台常驻接收/记录；手动 Disconnect 可正常收尾客户端日志。

## 日志与存储

- 配置在应用内部 files 目录持久化；日志默认位于应用专用外部目录 `Android/data/com.litwei.dart_control_panel/files/dart_control_panel/telemetry`，不可用时回退内部目录。
- Android 的“选择目录”只浏览本应用的日志存储，避免把 SAF 的 `content://` URI 当作 `dart:io` 路径，也不申请“所有文件访问”权限。可创建子目录；不支持任意公共 Downloads 路径直写。
- Logs 支持 Ground 后自动清空目录、手动复制板端记录、本地 CSV 遥测回放、视频播放及分别确认删除。手机使用 Android 原生 MediaMuxer 无损封装板端 H.264 为 MP4，不依赖 ffmpeg；原始 H.264 / CSV 和时间 metadata 均保留。
- 复制时有可靠估计 FPS 会自动封装；否则在“本地副本 / 回放”点击“封装 MP4”，确认实际 FPS（默认80）。点击原始 H.264 的播放按钮也会先确认 FPS、生成 MP4 再全屏播放，支持容器时间轴定位。FPS 决定播放速度，不是重新编码；已有 MP4 不覆盖。
- 手机封装支持板端的 Annex-B、逐行 I/P 帧，流式处理，不整段读入内存；遇到 B 帧、隔行、缺少 SPS/PPS、编码参数中途改变等情况明确报错并删除本次临时文件，请转用桌面版处理。失败不影响原件、已下载 CSV 或遥测回放。
- Diagnostics 的状态导出保存在上述应用存储的 `exports` 子目录；也可直接复制诊断摘要。应用卸载会清除应用专用文件，请先复制备份。正常覆盖安装不清数据。

## ADB 调试与重建

Release 使用 Flutter 默认 debug 签名进行内部侧载，不用于商店正式发布；不是生产签名，也不要重新生成签名后覆盖安装而不先备份日志。

```bash
# 编译；Gradle内存上限2GB，最多2个worker
flutter build apk --release --target-platform android-arm64 --no-pub
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n com.litwei.dart_control_panel/.MainActivity
adb logcat --pid="$(adb shell pidof com.litwei.dart_control_panel | tr -d '\r')"

# 单独安装可调试版本，包名带.debug，不覆盖Release的数据
flutter build apk --debug --target-platform android-arm64 --no-pub
adb install -r build/app/outputs/flutter-apk/app-debug.apk
flutter run --debug -d <设备序列号>
```

设备系统设置中的“允许 USB 安装”或厂商安装确认需要测试人员手动允许。不要清空整机 logcat、重置网络或清除应用数据作为常规排障手段。

横屏平台兼容依据：[Android 16 行为变化](https://developer.android.com/about/versions/16/behavior-changes-16#adaptive-layouts)。

无损封装使用 [Android MediaMuxer](https://developer.android.com/reference/android/media/MediaMuxer)；FPS 由用户/CSV 提供，用于生成每帧时间戳。Debug APK 包含 ADB-only `H264RemuxSmoke` 入口，可通过 `CLASSPATH=<设备上的debug.apk> app_process / com.litwei.dart_control_panel.H264RemuxSmoke <输入.h264> <FPS>` 测试原生封装；该入口不进入 Release，不导出 Activity。

Release 和 Debug 请不要同时运行：两者使用同一个 UDP 监听端口1347。切换版本前先 Disconnect 并保存日志，再退出另一版本。测试手机的应用文件可使用 `adb pull /sdcard/Android/data/com.litwei.dart_control_panel/files/ ./phone_dart_logs/` 备份；Debug 的包名及目录多一个 `.debug` 后缀。
