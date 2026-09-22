# Dart Control Panel

面向 LicheeRV Nano / SG2002 飞镖视觉板的 Flutter Material 3 桌面控制台，与当前 `dart_guidance_highfps_sg` JSON v1 协议同步。

## 当前功能

- **两种模式**：Ground / Flight，通过 `set_operating_mode` 原子切换。
- **Ground**：RTSP 实时优先预览；按已验证的 ffplay 参数使用 RTSP/TCP、`nobuffer`、`low_delay`、`framedrop`，禁用内存/磁盘缓存，不使用会破坏清晰度与时序的激进丢帧/untimed 配置。通过 TCP `get_profiles` 动态列出板端预设，可调 readout 和旋转。右侧 Configuration Studio 默认显示内嵌的深色 `default.json` 编辑器，可从板端重载、打开本地 JSON、格式化、复制并经确认后通过 `set_config` 上传完整配置；客户端先检查 JSON 语法和顶层对象，最终字段合法性由 daemon 校验。原有 NV21、ROI、ISP、Control、Overlay 快速控件保留在 Controls 标签页。
- **Flight**：RTSP 立即关闭，参数锁定，相机初始化后 standby；`flight_active` 打开才 wake、识别、录像、UART 和向控制客户端单播 UDP，关闭后安全收尾并回到 standby。
- **无录像功能**：客户端不再显示 preset、features 自定义组合或录像按钮。
- **UDP 遥测**：应用启动即在后台持续监听 `0.0.0.0:1347`，页面切换不停止；合法 VOFA+ FireWater 包直接进入采样窗口。
- **可配置 UART 接收**：在 Configuration Studio 的完整 JSON 中编辑 `uart.rx_layout`，可设置包长、帧头、校验、大小端以及各字段的名称、类型和字节偏移；编辑器在上传前检查越界、重名和字段重叠。板端解出的字段以 `uart_rx_<name>` 进入实时 UDP 和飞行 `.telemetry.firewater` 记录。
- **Overlay 帧同步**：可调同帧识别 deadline，展示 matched/missed、等待耗时和当前识别帧 ID。
- **无 SSH 文件访问**：通过 HTTP `9002` 只读浏览日志/录像，日志直接预览，录像 Range 回放，下载支持 `.part` 断点续传。
- **诊断**：daemon 状态、worker 日志、schema、状态 JSON 导出。
- **单一配置协议**：支持 `get_config` / `set_config`；状态展示 daemon 的配置恢复警告，profile 列表兼容最新的 `profiles` 包装结构。
- **固定控制端口**：界面只需输入板子 IP，TCP control 固定使用 `9000`。
- **数值化遥测**：曲线保留趋势，同时显示当前值、单位、纵轴刻度和时间轴。Telemetry 页面还提供固定 300×300 的二维导引头视图：坐标范围读取 daemon 的 `worker.view.output`（已经过裁剪和旋转），按真实宽高比压缩并留黑边，不会因 profile 改变而让控件跳动；`Fade` 滑条可在 1–20 秒内调整 `target_x/y` 轨迹的保留和淡出时间，轨迹由旧到新逐渐加深。
- **自适应布局**：连接栏参与正常页面布局，不再悬浮遮挡页面内容；预览与调参区随窗口比例伸缩。

## 连接

默认板端地址：

```text
TCP control: 10.149.242.1:9000 (newline-delimited JSON v1)
RTSP:       rtsp://10.149.242.1:8554/live (Ground only)
UDP:        10.149.242.255:1347, 50 Hz (board broadcast)
Files:      http://10.149.242.1:9002/v1/ (Ground only, read-only)
```

控制面板只要求填写板子 IP；以上各服务端口由这套飞镖程序固定管理，不在界面重复配置。

主机需允许 UDP 1347 入站。若同时运行 VOFA+ 和本程序，同一台主机上通常不能都独占监听同一 UDP 端口；请选择一个接收端，或修改其中一个监听端口/板端目的端口。

UDP 接收器属于应用级生命周期：应用启动即绑定，直到应用退出才释放；从 Telemetry 切换到 Ground Test、Mode 或 Files 不会丢失接收窗口。UDP 不依赖 TCP 连接，也不执行设备 ID 过滤。Files 仍以 TCP control 会话为入口。HTTP 服务本身是无状态的只读接口，不把 TCP 连接当作网络鉴权。

## 开发与测试

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d linux
```

协议的完整字段、模式锁定规则和 UDP 数据顺序见 [`AGENTS.md`](AGENTS.md)。
