# Dart Control Panel

面向 LicheeRV Nano / SG2002 飞镖视觉板的 Flutter Material 3 桌面控制台，与当前 `dart_guidance_highfps_sg` JSON v1 协议同步。

## 当前功能

- **两种模式**：Ground / Flight，通过 `set_operating_mode` 原子切换。
- **Ground**：RTSP 实时优先预览；按已验证的 ffplay 参数使用 RTSP/TCP、`nobuffer`、`low_delay`、`framedrop`，禁用内存/磁盘缓存，不使用会破坏清晰度与时序的激进丢帧/untimed 配置。通过 TCP `get_profiles` 动态列出板端预设，可调 readout 和旋转。右侧 Configuration Studio 默认显示内嵌的深色 `default.json` 编辑器，可从板端重载、打开本地 JSON、格式化、复制并经确认后通过 `set_config` 上传完整配置；客户端先检查 JSON 语法和顶层对象，最终字段合法性由 daemon 校验。原有 NV21、ROI、ISP、Control、Overlay 快速控件保留在 Controls 标签页。
- **Flight**：RTSP 立即关闭，参数锁定，相机初始化后 standby；`flight_active` 打开才 wake、识别、录像、UART 和向控制客户端单播 UDP，关闭后安全收尾并回到 standby。
- **无录像功能**：客户端不再显示 preset、features 自定义组合或录像按钮。
- **UDP 遥测**：应用启动即在后台持续监听 `0.0.0.0:1347`，页面切换不停止；TCP 查询字段表后解码合法 DVT1 索引二进制包，兼容旧 FireWater。
- **可配置 UART 接收**：在 Configuration Studio 的完整 JSON 中编辑 `uart.rx_layout`，可设置包长、帧头、校验、大小端以及各字段的名称、类型和字节偏移；编辑器在上传前检查越界、重名和字段重叠。板端解出的字段以 `uart_rx_<name>` 进入实时 UDP 和飞行 `.telemetry.firewater` 记录。
- **Overlay 帧同步**：可调同帧识别 deadline，展示 matched/missed、等待耗时和当前识别帧 ID。
- **无 SSH 文件访问**：通过 HTTP `9002` 只读浏览日志/录像，日志直接预览，录像 Range 回放，下载支持 `.part` 断点续传。
- **诊断**：daemon 状态、worker 日志、schema、状态 JSON 导出。
- **单一配置协议**：支持 `get_config` / `set_config`；状态展示 daemon 的配置恢复警告，profile 列表兼容最新的 `profiles` 包装结构。
- **自动 / 高级连接**：默认从本机 DHCP IPv4 推导板端 `.1` 地址，验证 NDJSON 板端协议后连接；高级模式保留手动 IP 与 Android 系统路由选项。TCP control 固定使用 `9000`。
- **数值化遥测**：曲线保留趋势，同时显示当前值、单位、纵轴刻度和时间轴。Telemetry 页面还提供固定 300×300 的二维导引头视图：坐标范围读取 daemon 的 `worker.view.output`（已经过裁剪和旋转），按真实宽高比压缩并留黑边，不会因 profile 改变而让控件跳动；`Fade` 滑条可在 1–20 秒内调整 `target_x/y` 轨迹的保留和淡出时间，轨迹由旧到新逐渐加深。
- **自适应布局**：连接栏参与正常页面布局，不再悬浮遮挡页面内容；预览与调参区随窗口比例伸缩。

## 连接

默认自动连接：电脑或手机连接板端 AP、取得 DHCP 地址后，应用从本机 `10.b.c.x` 推导 `10.b.c.1:9000`，每 3 秒重试，验证板端 `get_state` 协议响应后建立会话、开始原有 UDP 接收记录流程。启动应用时默认查找，无需输入板端 IP。自动模式只尝试 `10.*`，不尝试 `172.*`、`192.168.*`；电脑枚举所有网卡上的 `10.*` IPv4，优先 Wi-Fi、按目标去重、排除本机 `.1`，不根据网卡名字排除，也不限制候选总数，每批最多并发 4 个。Android 只读取 Wi-Fi 地址，避免误用蜂窝网络。只探测各网段 `.1`，不扫描整个子网；找到合法板端即连接。多网卡同时连接不同板子时，可使用高级连接明确选定。这里按实际本机 IPv4 判断，不区分 DHCP 与手动配置地址。

自动模式遵循板端 AP 的 `.1` 地址约定（并非通用默认网关发现）。主动 Disconnect 会暂停自动查找，按“自动连接”可重新开始，避免刚断开就连回去。已建立会话的短暂失联沿用原有轮询重连，不新建日志。

**高级连接**：手动填写 IP/主机名，支持无线中继、跨子网等系统已经配置好路由的场景。Android 可关闭“优先绑定 Wi-Fi”，改走系统路由/VPN；客户端不修改操作系统路由表。连接模式和 Wi-Fi 绑定偏好保存在应用配置目录 `dart_control_panel/connection.json`；手动地址沿用 `addresses.json`。`DART_CTRL_HOST` 显式指定时优先手动连接，不被自动发现覆盖。

例如本机 DHCP 地址为 `10.198.137.23` 时，服务地址为：

```text
TCP control: 10.198.137.1:9000 (newline-delimited JSON v1)
RTSP:       rtsp://10.198.137.1:8554/live (Ground only)
UDP:        本机监听 0.0.0.0:1347，板端按 UART DATA 频率向客户端回传
Files:      http://10.198.137.1:9002/v1/ (Ground only)
```

自动模式不必填 IP；高级模式只填板子 IP。服务端口不在界面重复配置。

主机需允许 UDP 1347 入站。若同时运行 VOFA+ 和本程序，同一台主机上通常不能都独占监听同一 UDP 端口；请选择一个接收端，或修改其中一个监听端口/板端目的端口。

UDP 接收器属于应用级生命周期：应用启动即绑定，直到应用退出才释放；从 Telemetry 切换到 Ground Test、Mode 或 Files 不会丢失接收窗口。UDP 不依赖 TCP 连接，也不执行设备 ID 过滤。Files 仍以 TCP control 会话为入口。HTTP 服务本身是无状态的只读接口，不把 TCP 连接当作网络鉴权。

## 代码结构与职责

代码按**应用装配、跨功能基础能力、独立功能、共享控件**划分，而不是把所有页面、控制器和模型分别堆进全局目录：

```text
lib/
├── main.dart                    Flutter 入口
├── app/                        MaterialApp、导航、应用级资源生命周期
│   ├── app.dart
│   └── home_shell.dart          共享 BoardSession、状态轮询、常驻 UDP 接收器
├── core/
│   ├── board/
│   │   ├── api/                 TCP 9000 / NDJSON 编解码、daemon 命令仓库、协议错误
│   │   ├── models/              状态、profile 等协议数据解析
│   │   └── session/             连接状态、500 ms 轮询、写操作串行化与刷新
│   ├── preferences/             本机板端地址记忆
│   └── video/                   Ground / Files 共用的 RTSP/录像播放后端与视图
├── features/
│   ├── telemetry/               UDP DVT1/TCP 字段发现、采样窗口、图表、姿态、导引头视图
│   ├── ground_test/             实时预览、profile 选择、JSON 配置编辑与调参
│   ├── mode/                    Ground/Flight 与飞行状态控制
│   ├── files/                   只读 HTTP 9002 浏览、预览、断点下载
│   └── diagnostics/             daemon 状态/日志/schema 与诊断导出
└── shared/widgets/              被多个功能复用的连接栏、状态卡片等 UI

bin/dart_cli.dart                不依赖 Flutter 页面，直接复用 core/board API
test/                           按 app/core/features 镜像源码分组；fixtures/helpers 独立
tool/                           构建、打包、运行和模拟 daemon 的开发工具
```

**依赖方向**：`app` 负责组装 `features`；功能模块只依赖自身、`core` 和 `shared`，不直接引用其他功能模块；`core` 不依赖页面或共享控件。跨页面跳转由 `app/home_shell.dart` 注入回调，例如 Telemetry 打开 Diagnostics，而不是在 Telemetry 内创建 Diagnostics 页面。`test/app/module_boundaries_test.dart` 检查这些边界。

**运行时数据流**：`DaemonClient` 负责一条 TCP/NDJSON 连接，`BoardRepository` 封装命令，`BoardSession` 持有当前状态并串行执行修改，`HomeShell` 创建一次会话和轮询，页面只消费共享会话。UDP 遥测独立于 TCP，由 `HomeShell` 持有 `TelemetryController` 并持续接收，Telemetry 页面只呈现其采样窗口。视频走 `core/video`；文件 HTTP 访问只在 `features/files` 内。这样切换页面不会重建连接或丢掉 UDP 数据。

新增板端命令时，先改 `core/board/api` 和相关 `models`，再在对应 `features` 接入；新增页面时由 `app/home_shell.dart` 装配。不要在页面中另开 TCP 控制连接，也不要把单个功能专用的文件放进 `shared`。

## 开发与测试

### 姿态显示坐标约定

`features/telemetry/attitude_scene.dart` 定义显示用的 NED 世界坐标：`X=N`（北）、`Y=E`（东）、`Z=D`（下）。模型机体坐标为前/右/下，机头沿 `+X`；零姿态时机体系与 NED 系重合。角度仍使用 UDP 原始 degree 数据，显示旋转采用 `Rz(yaw) · Ry(pitch) · Rx(roll)`，不改变遥测数值或板端控制。

摄像机固定在 `k*(-1,0,-1)`，当前 `k=5.1`，朝向原点，向上参考为 NED 的 `-Z`。NED 轴固定不动，机体轴随模型旋转；绘制深度按远到近排序。几何和摄像机约定由 `test/features/telemetry/attitude_view_test.dart` 验证。

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d linux
```

协议的完整字段、模式锁定规则和 UDP 数据顺序见 [`AGENTS.md`](AGENTS.md)。

## TCP 字段发现与 DVT1 UDP

HomeShell 连接后自动调用 `get_telemetry_schema`，查询板端当前实际串口字段名称、类型及 UDP index。实时 UDP 使用小端 DVT1 二进制值流和 CRC32，不再重复名称；最多 64 个串口字段。未知字段表会限频查询并丢弃过期包，切换页面不停止后台接收。遥测页右上角 `UART fields (TCP)` 可查看字段表。仍兼容旧 FireWater UDP；板端录像的 FireWater 文件不变。完整协议见主仓库 `docs/UDP_TELEMETRY_DVT1.md`。新板端需搭配本版上位机，VOFA+ 不支持新实时格式。

Channels 列表及曲线统一使用动态通道注册表：TCP metadata 到达即展示全部字段及类型，旧 FireWater 的未知字段也可勾选绘图；新增通道颜色稳定、不猜测未知单位。列表支持名称搜索和限高滚动，避免 64 个 UART 字段挤掉图表。

## 本地 UDP 会话缓存与区间回放

每次 Connect 探测成功后创建一个新的本地连接记录，Disconnect 后排空写盘队列并保留会话供直接回放，不弹保存选择；再次 Connect 使用新目录，不续写上一段。未连接时不记录收到的 UDP。记录独立于页面、飞行 active 和显示模式。UART DATA 的有效样本逐条保存，不按绘图刷新频率抽样；打开离线记录时仍继续接收并保存实时数据。默认目录为 Linux/macOS 的 `$XDG_DATA_HOME/dart_control_panel/telemetry`（未设置时为 `~/.local/share/dart_control_panel/telemetry`），Windows 为 `%LOCALAPPDATA%/dart_control_panel/telemetry`；可通过 `DART_TELEMETRY_DIR` 指定。

每次连接对应一个 `connection_...` 目录，其 `metadata.json` 保存连接起止时间、总时长及子段目录清单；子段内为协议元信息 `metadata.json` 和 `samples.csv`（写入中为 `samples.csv.part`）。元信息保留来源 IP、DVT1 完整 schema、临时 stream_id、字段名称/类型、最后有效样本对应的接收器统计与本地队列丢弃计数。CSV 附加 `client_elapsed_us`（客户端单调时间）与 `client_received_at`（接收日期时间），保留原始 UDP 序号、板端时间和所有解码字段。来源、schema、stream_id 或字段变化在本次连接目录内生成新子段，所有子段共用 Connect 时的单调时钟原点。UDP 静默不会结束连接记录；Disconnect 或正常退出时收尾。无有效样本的连接也保存空会话元信息。来源 IP 是网络来源，不是设备身份认证。

记录器使用 2048 项有界队列，达到 64 项或每 250 ms 异步批量写盘并 flush。队列溢出显示本地丢弃数；磁盘失败显示错误并停止记录，不反复重试。桌面正常退出请求会先等待连接记录收尾，dispose 也会尝试排空；强制结束可能损失未写入的队列数据并留下 `.part`。离线读取忽略末尾没有换行的不完整行，不补造数据。记录列表可打开正在写入的段作为当时的快照。

桌面遥测采用曲线优先三栏布局：左侧姿态/目标轨迹，中间紧凑数值条与主曲线，右侧 Channels 搜索与分组勾选（Attitude、Rates、Control、Vision、Motion、System），底部为设备状态。字段仍由协议动态发现，分组仅用于显示，不限制未知字段。右侧独立滚动，窄屏退回原有纵向布局；1280×720 和 1440×900 均有布局、搜索和勾选回归。

遥测页顶部保留“记录列表”“打开记录目录”。主曲线底部为历史滑条、当前时间/总时长，以及“暂停”“恢复”：拖动滑条可回看本次连接任意历史位置；暂停立即冻结显示和滑条总时长，UDP 接收与写盘继续；滑条始终可操作，拖动过程中节流读取历史并动态刷新曲线，不必松手。恢复直接更新最新总时长、回到最新值并跟随实时数据。底部剪刀按钮打开区间回放/截取对话框。离线回放复用曲线、姿态和目标轨迹，支持下一样本和 0.25×/1×/2×/4× 播放；播放到选区末尾自动暂停。长记录只建立每 256 行一个字节偏移的稀疏索引；活跃会话增量扫描新增字节，按需读取显示窗口，不将整份记录常驻内存。历史读取的刷盘屏障只等待调用前已接受的样本，不等待 UDP 接收队列清空，持续收包也不会阻塞回看。

“日志设置”可以选择默认保存目录、名称和逗号分隔的标签。默认配置写入 `$XDG_CONFIG_HOME/dart_control_panel/telemetry.json`（通常 `~/.config/dart_control_panel/telemetry.json`），Windows 使用 `%APPDATA%`；应用启动时自动加载。显式构造参数及 `DART_TELEMETRY_DIR` 仍可覆盖启动目录。运行中更改默认目录不会搬动正在写入的会话，下一段记录使用新目录；保存窗口也可单次选择输出目录，并勾选记住本次配置。

最终日志目录按连接开始的本地时间命名，例如 `10月12日19时45分_试飞`，重名追加 `_2`、`_3`，非法路径字符替换为下划线。`metadata.json` 增加 `log_name`、`tags`、`saved_at` 和显示时区偏移；原完整 `started_at`/`ended_at`、协议/schema 和 CSV 中的接收时间不改变。裁剪另保留 `original_range_us`、`original_duration_us`、首末样本完整 UTC 接收时间。完整日志复制并验证后才删除临时连接记录；跨磁盘路径也支持，失败时保留原记录。目录名中的简短时间不取代 metadata 的完整精度时间。

Connect 成功后默认持续接收 UDP，不再提供接收开关。Disconnect 只停止接收并收尾本次会话缓存，不弹保存确认，也不清除曲线、时间轴或历史数据；断连后可直接拖动、播放和裁剪回看。只有主动点击“保存接收日志”才打开保存窗口并正式归档；取消保存不删除会话缓存，可继续回放或稍后保存。再次 Connect 成功后开始新会话，不将两次连接的数据混合。

曲线观察交互参考 `../LogParser`：直接拖动曲线平移 X/Y；滚轮、中键斜向拖动以鼠标所在位置为中心等比缩放 X/Y，Ctrl+滚轮仅 X、Shift+滚轮仅 Y。上方提供 X+/X−、Y+/Y−、适配Y、全览；全览显示本次会话（时间窗口支持 1 毫秒至 1 小时）。悬停显示十字线和选中通道在最近样本处的读数，数据窗口跟随交点右上方，靠近图表边缘时自动避让；手机支持单指平移、双指斜向等比缩放 X/Y、长按移动读数。拖动和时间轴缩放自动暂停显示但不停止接收和缓存，播放点同步到观察焦点而非停留在实时末尾；恢复最新时回到默认窗口。断连后恢复到会话末尾仍保留离线回放状态。

点击暂停冻结最后一次实际绘制的时间范围和样本，曲线不平移；播放点放在该视窗中心，当前值对应中心时间的样本，终点仍在右侧。刚连接时视窗从零开始逐渐增长到默认窗口长度，避免暂停中心落到负时间。暂停不会停止 UDP 和会话缓存。

绘图按当前时间窗口和画布像素宽度做 min/max 包络降采样，每桶保留首点、最小值、最大值、末点，保留单样本尖峰，不使用简单每 N 点抽取。大范围历史视图缓存分桶概要，放大后重新读取更细粒度/原始数据；悬停复用绘图缓存，不反复扫描整段。概要读取分批让出 UI，过期拖动请求可取消。播放点读数来自原始 CSV 行；降采样只用于绘图，原始缓存、记录和导出不改变。

保存窗口在同一条时间轴上显示起点、播放点和终点三个拖动手柄（端点手柄略错开，重合时仍可分别拖动），强制 `起点 <= 播放点 <= 终点`。拖动任何滑条以该位置为横轴中心，图中仅用绿色、橙色竖线标记可见窗口内的起点、终点，不绘制蓝色播放线；当前值仍对应播放点，不会跟随起点/终点焦点错位。默认绘制 `y=0` 虚线作为参考，零点移出窗口时自然隐藏，不强制改变坐标轴范围。Y 轴自动范围只扩大、不缩小；滚轮上滚放大、下滚缩小，手动缩放后保持范围，双击曲线恢复自动范围。

“截取保存”选择输出父目录，创建独立 `clip_...` 子目录，导出选区全部样本与元信息（不是屏幕上抽稀后的点）。原 UDP/MCU/板端时间和序号不变，客户端相对时间减去选区起点；元信息保留原记录路径和区间，导出的目录可独立回放，原文件不修改。

注意：只保存客户端实际收到且通过解析的样本。UDP 丢包、未知 schema、断网、休眠或本地队列溢出均可能造成缺口，不能替代板端完整原始记录；不保存视频。接收器统计是截至最后有效样本的累计值，分段初始值也保留，不能把其他时段的累计丢包全算到当前段。

回归测试：`telemetry_archive_test.dart`（写盘、分段、异常恢复、索引、导出及回放期间继续记录）、`udp_archive_integration_test.dart`（真实 loopback DVT1 接收、CRC/重复包拒绝与一包一行）、`telemetry_recording_controls_test.dart`（离线控件与下一样本）。

连接会话回归见 `connection_recording_test.dart`：未连接不记录、暂停/拖动继续写盘、恢复最新、Disconnect 收尾、重连隔离、跨 schema 子段汇总、增量索引和超过 10 秒无 UDP 不结束会话。

## 板端飞行日志与离线回放

导航 **Logs** 分为“板端记录”“本地副本 / 回放”“原始文件”：

- 连接后进入 Ground 时自动扫描 `/recordings/flight_N` 并清理真正的空会话目录。不自动下载，不删除零字节文件、不完整的 `.part` 或索引，不影响飞行模式及 UDP 记录。
- “复制到本地”选择父目录，下载完整会话的 CSV / H.264 / MP4；每次建立独立目录，不覆盖既有副本。保存目录持久化到 `~/.config/dart_control_panel/flight_logs.json`（支持 `XDG_CONFIG_HOME`）。原始文件保留在板端；复制失败保留已下载部分。
- 本机安装 `ffmpeg` 后可无损封装 H.264 为 MP4（`-c:v copy`，不重新编码）。默认根据 CSV 的视觉帧号和单调时间差估计帧率；缺少可靠估计或封装失败时原件仍保存，可手动指定实际录像 FPS 重试。`DART_FFMPEG` 可指定可执行文件路径。变帧率或丢帧时恒定帧率 MP4 不等价于逐帧精准时间同步。
- “遥测回放”直接打开已有 Telemetry 页的姿态、目标轨迹、动态通道、曲线、时间轴与区间回放；回看不会停掉当前 UDP 接收/记录。读取板端 `mono_us` 建立相对时间轴，不依赖板端1970年的系统时间；原始 CSV、单调时间、来源和完整 UTC 复制时间均保留，不把复制时间误当飞行发生时间。
- “删除板端整条记录”和“删除本地副本”分别确认、分别操作，不会相互删除。板端删除仅 Ground 允许，拒绝 `.part`、符号链接、子目录及越界路径。HTTP 下载服务仍是只读；新增的删除/空目录维护走 TCP daemon API，需要同步更新板端 daemon。
- 即使断开板子，Logs 的本地副本仍可播放和回放。MP4 视频为独立播放器；本轮未实现视频与遥测游标逐帧联动。

定向测试：`flutter test --concurrency=1 test/app/flight_logs`。源码检查：`flutter analyze lib test bin`（构建诊断目录中的历史源码备份不属于源码检查范围）。

## Android 横屏内测

已加入 Android 工程、横屏声明、应用专用可写目录、HTTP/RTSP 网络权限及无互联网 AP 的应用内 Wi-Fi 路由绑定。发行/调试 APK 的构建、ADB 操作、AP 地址和当前功能边界见 [Android 内测说明](docs/ANDROID_TESTING.md)。Android 版不依赖桌面 HOME/XDG 路径，不申请全盘存储权限；MP4 封装暂留在桌面端完成。

### Android 单次日志 ZIP 分享

先在“本地副本 / 回放”选择一条飞行记录，点击分享图标“压缩并分享单次日志”。尚在板端的记录需要先复制到本地。遥测“记录列表”也有逐条分享入口；断连后的离线会话可直接点击“压缩分享”。系统分享面板打开不表示文件已发送，最后由目标应用确认。

压缩包包含选中目录的 CSV、元信息、协议子段，以及已有的 H.264/MP4；不自动转换视频，不修改原文件。压缩使用后台流式 ZIP，不整段装入内存；跳过符号链接、隐藏文件和 `.part/.tmp` 临时文件。只分享一条日志，不打包整个日志库。使用限定到分享缓存目录的 FileProvider `content://` 临时只读授权，不需要广泛存储权限。ZIP 缓存保留供接收应用读取，下次分享时清理超过 7 天的旧导出；系统也可能回收缓存，原日志仍保留。

### 曲线偏好与回放默认通道

Channels 标题旁的“曲线偏好”按钮支持“保存当前为默认”“加载默认曲线”和“恢复初始曲线”。可同时勾选任意多条曲线，默认启用“自动记住曲线选择”，关闭/重新打开应用或打开其他日志后会恢复上次选择；某日志缺少的字段不会丢失记忆，后续日志提供该字段时仍自动选中。全部取消勾选也会被保留。关闭自动记忆后仍可手动保存/加载默认选择，初始曲线为 Pitch、Roll、Yaw。

偏好保存在应用配置目录的 `dart_control_panel/telemetry_view.json`，与日志内容独立，不改写原始 CSV，也不保存某次回放的播放点或缩放范围。

手机遥测长按曲线显示十字线与浮动读数，保持按住可拖动查看，松手隐藏；单指直接拖动仍用于平移，双指用于缩放，不再提供独立读数模式按钮。打开离线日志时默认全览整段记录，播放点仍从起点开始，图中不显示蓝色播放线。手机端 Channels 使用窄栏和紧凑搜索框、时间轴/播放控制，优先保留曲线高度。Android 采用沉浸横屏，默认隐藏状态栏和底部导航提示；从屏幕边缘滑动可临时调出系统栏。
