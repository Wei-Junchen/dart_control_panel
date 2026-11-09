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

## 本地 H.264 离线分析

在设备管理进入飞行日志的“本地副本 / 回放”，选择录像旁的“离线分析”；有 `.raw.h264` 时优先使用原始录像。Android 版在私有缓存中临时无损封装，再由 MediaCodec 解码 YUV，通过 JNI 调用随 APK 携带的原生检测库。分析后临时文件会清理，不改写源录像或板端配置；需要足够的缓存空间。库源码版本见 `android/app/src/main/cpp/vendor/README.md`。

目前可设置五个绿色阈值并查看逐帧汇总与本机耗时；阈值默认值不是录像时的板端配置，ROI、步长、面积和跟踪半径使用检测器默认值。分析时并排显示同一帧的原画面与检测框、解码 Y 平面和颜色阈值掩码；为降低手机负载，预览抽样缩小并约每 180 ms 刷新，但检测仍处理完整分辨率的每一帧。默认放慢处理以方便观察，约 10 帧/秒并非录像真实时间轴，可关闭；阈值在一次分析期间固定，调整后需重新分析。彩色画面由 YUV 转换生成，仅用于预览；白色掩码只表示颜色阈值通过，不代表最终检测目标。

只支持当前封装器支持的逐行 I/P 帧 Annex-B H.264；B 帧、隔行、参数中途变化或解码器不提供可访问 YUV 时会报错。H.264 有损压缩、叠加画面及手机解码器的色彩处理可能使结果与板端原始 NV21 不同；耗时也不代表板端性能。

## ADB 调试与重建

Release 使用 Flutter 默认 debug 签名进行内部侧载，不用于商店正式发布；不是生产签名，也不要重新生成签名后覆盖安装而不先备份日志。

```bash
# 项目根目录：默认生成 arm64 Release APK（自动执行 flutter pub get）
./tool/build_android.sh
# 调试版（包名带 .debug，可与 Release 同时安装）
./tool/build_android.sh debug

# 也可手动编译；Gradle内存上限2GB，最多2个worker
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

离线分析可选择 `luma_ellipse`（实验性亮度椭圆检测）或 `nv21_green`。前者的亮度阈值掩码不是最终检测结果，椭圆拟合与绿色区域校验还会过滤候选；绿色阈值也用于该校验。此选项只影响本地分析，不向板端下发检测模式，板端仍使用 `nv21_green`。

Android 离线逐帧调参：点击“准备视频”后解码并缓存全分辨率 NV21 原始帧；滑动、逐帧切换或修改参数时只重算当前帧。当前帧预览会重置跟踪器；“全片统计”才从头连续跟踪，结果可能不同。帧缓存上限 1 GiB，空间不足时会报错并清理未完成的缓存；退出页面会清理缓存。Linux 参考工具路径目前没有此逐帧预览控件。

连接板子后客户端后台读取一次完整 `get_config`，在应用数据目录 `dart_control_panel/config_snapshots/<device_id 或 _unknown>/` 留存带时间和来源的 JSON 快照，并写入当前连接的遥测会话。复制板端飞行记录时，会将当前连接的快照复制为本地记录的 `board-config.json`；离线分析优先读取该文件的检测模式、阈值、ROI、跟踪半径、面积/像素阈值和采样步长。快照只反映连接时，不代表历史录像录制时的参数。自动 ROI 若能从同一配置版本的 worker 状态读到则使用该值，否则按全画面并在页面提示。旧记录没有快照时使用默认参数，不以 IP 或 unknown 自动猜测设备配置；遥测回放仍以记录本身的列和 schema 为准。离线分析逐帧检测，不能重现板端 `every_n` 跳帧和运行时调参历史。
