# Flutter 控制台对接：双模式 API v1

板端公开控制面为 TCP `10.149.242.1:9000`，使用 UTF-8 NDJSON。每个请求固定返回两行：

```json
{"v":1,"type":"request","id":1,"op":"get_state","args":{}}
{"v":1,"type":"accepted","id":1,"mono_us":123}
{"v":1,"type":"result","id":1,"ok":true,"state":"STREAMING","config_rev":8,"payload":{}}
```

客户端必须校验两行 `id`，且仅以第二行 `ok` 为操作结果。`get_state` 的实际状态位于
`result.payload.payload`，worker 实时状态位于 `result.payload.payload.worker`。

## 1. 仅有两个运行模式

| 模式 | RTSP | TCP 图像调参 | 本地 NV21 识别 | UART | UDP 遥测 | 录像 |
|---|---:|---:|---:|---:|---:|---:|
| `ground` | 开 | 允许 | 开 | 开关可调 | 开 | 永久关闭 |
| `flight` idle | 关 | 全部锁定 | standby | 不发送 | 静默 | 关 |
| `flight` active | 关 | 全部锁定 | 开 | 开 | 开 | H.264 + FireWater 日志 |

切换请求：

```json
{"v":1,"type":"request","id":2,"op":"set_operating_mode","args":{"mode":"flight"}}
```

进入 `flight` 会先终止当前 worker，从而立即拆除 RTSP 网络流，再初始化无 RTSP/overlay 的
相机与 VENC，最后进入 software standby。使用 `set_flight_active {"active":true|false}` 控制
一次飞行记录周期；退出飞行模式仍使用 `set_operating_mode` 并传 `ground`。

状态关键字段：

```json
{
  "operating_mode":"flight",
  "mode":{"name":"flight","ground":false,"flight":true,"rtsp":false,"image_settings_locked":true},
  "flight":{"active":false,"state":"IDLE","trigger_source":"","record_path":""},
  "features":{"rtsp":false,"recording":false,"overlay":false,"uart_enabled":true}
}
```

`debug/training/competition/idle` 预设以及 `set_features`、`apply_feature_preset`、
`start_recording`、`stop_recording`、`rotate_recording` 已删除。Flutter 中必须删除对应页面、按钮和 model 字段。

### 飞行模式允许的操作

```text
get_state, get_config, get_profiles, get_schema, get_telemetry_schema, get_logs, heartbeat,
set_operating_mode, set_flight_active, restart_worker, reboot_board
```

其他请求统一返回 `operation <op> is locked in flight mode`。客户端应在
`mode.image_settings_locked == true` 时直接禁用全部 profile、旋转、ISP、颜色阈值、ROI、overlay、
UART、standby 和 stop 控件，但仍以服务端拒绝为最终安全边界。

## 2. 操作清单

- 只读：`get_state`、`get_config`、`get_profiles`、`get_schema`、`get_logs`、`heartbeat`
- 生命周期：`start_worker`、`stop_worker`、`restart_worker`、`camera_standby`、`camera_wake`
- 地面配置：`set_config`、`apply_readout_profile`、`apply_runtime`、`set_uart`、`set_rotation`
- 模式：`set_operating_mode`、`set_flight_active`（仅 Flight，参数必须为 JSON boolean）
- 恢复：`reboot_board`，必须 `{"confirm":true}`

应用启动顺序：`get_schema` → `get_config` → `get_profiles` → 每 500 ms `get_state`。不要写死 schema。

`get_profiles` 中每个档位可包含 `supported_rotations` 数组；缺省为 `[0,90,180,270]`。客户端应按所选档位限制旋转选项。当前镜像的 `p4_control_vpss_640x360` 只支持 `[0,180]`；不支持的档位/旋转组合会在停止现有 worker 之前被拒绝。

### 单一 config 的读写

- `get_config`：`result.payload` 直接是完整 config JSON（没有 state 的双层 payload）。飞行模式也允许读取。
- `set_config`：`args={"config": <完整 JSON>}`，仅地面允许；可从 `get_config` 结果修改后原样提交，不是局部 patch。单行请求上限 65536 字节。
- `start_worker` 不传 profile、开机 autostart、restart_worker 均按当前 config 启动，不选 profiles 第一项或旧 state。显式传 profile 则视为用户选择预设。
- `apply_readout_profile` 仅把预设 readout/view 写入 config，其余参数保留；改变视图/读出时 ROI 重置为 auto。预设只供参考，不是配置真值。
- `apply_runtime`、`set_rotation`、`set_uart`、`set_operating_mode` 成功后同步 `config/default.json` 对应字段。`gain` 是 `isp.again` 的别名；`reset_tracker` 不持久化。
- 非法请求在修改 worker 前拒绝；重启式应用失败恢复旧 config 并尝试恢复原 worker。worker 原本停止时，set_config 只保存，不擅自启动。
- `get_state` 新增 `expected={"sensor":[w,h],"output":[w,h],"fps":n}`（output 已含旋转）、`config_path`、`config_warning`。合法配置不匹配预设时 `profile="custom"`。
- 磁盘 config 损坏会在 daemon 启动时归档为 `.json.bad`（重复故障另加时间戳）并恢复代码内置默认值；在线非法请求只拒绝，不覆盖有效 config。客户端应展示非空 config_warning。
- `get_config` 仅包含用户可调字段，不包含 `sensor.*`、`capture.width/height/fps/format`、`debug.enabled`、`udp.active`、`record.path/prepare`。这些值由程序派生，`set_config` 不接受。旧磁盘配置自动迁移并保留调参；历史文件中已经废弃的 `udp.board_id` 只会在迁移时被删除，不属于当前协议。客户端请重新读取 config，不提交旧缓存结构。
- `config_rev` 是 daemon 会话内计数，重启可归零。旧 `state/config.json`、`last_known_good.json` 不再作为启动依据。

## 3. NV21 绿色识别

识别器已固定为 `nv21_green`，LAB 和检测器切换接口已删除。当前 `apply_runtime` 可调键以
`get_schema.runtime_keys` 为准，主要字段如下：

```text
green_y_min, green_g_min, green_score_min, green_rg_min, green_gb_min,
detect_roi, search_radius,
area_threshold, pixels_threshold, x_stride, y_stride, detect_every_n,
overlay, overlay_roi, overlay_sync_timeout_ms, control_mode, fx, fy, roll_sign, roll_unit, distance,
exposure_us, gain, again, dgain, isp_dgain, awb_auto, isp_adaptive_tone,
reset_tracker
```

示例（仅地面模式）：

```json
{"v":1,"type":"request","id":3,"op":"apply_runtime","args":{"green_score_min":60,"detect_roi":"40,40,280,160","exposure_us":1000,"again":1024,"dgain":1024,"isp_dgain":1024,"awb_auto":false,"isp_adaptive_tone":false}}
```

表单只发送已成功解析且发生变化的字段。`detect_roi` 是无空格的 `x,y,w,h` 字符串；
`overlay`/`awb_auto` 等必须是 JSON boolean。成功后重新 `get_state` 并以
`worker.camera.isp.*` 回读值作为实际值。

`overlay_sync_timeout_ms` 是 `1..50` 的整数，默认 `6`。`worker.overlay` 增加
`frame_sync/sync_timeout_ms/matched_frames/missed_frames/last_wait_us/max_wait_us/detection_frame_id`。
RTSP 左上角的 `F` 是编码帧 ID，`D` 是本帧使用的识别 ID；画出目标框时二者一定相等。
`D:0` 是 deadline miss，表示当帧主动放弃 overlay，而不是覆盖过期框。

`worker.vision.profile_us` 是最近一次检测的工作量与耗时：`threshold` 为 LUT
分类与流式 RLE 扫描总时间，`blob` 为连通域最终归并/过滤时间；
`coarse_samples/coarse_passes` 表示捕获路径检查的 NV21 2×2 色度块，
`fine_samples/fine_passes` 表示候选 bbox 精化或局部跟踪检查的像素样本。跟踪命中时
`coarse_passes=0`；重新捕获帧中可能同时出现 coarse 和 fine pass。

## 4. RTSP

仅 `ground` 提供 `rtsp://10.149.242.1:8554/live`。进入 `flight` 时播放器应立即释放；
回到 `ground` 并看到 `worker.stream.rtsp_enabled == true` 后再重连。板端不会录制视频。

## 4.1 文件 API（HTTP 9002）

客户端文件页不再调用 SSH/SCP，也不应存储 root 密码或读取 `known_hosts`。

```text
GET http://<board>:9002/v1/info
GET http://<board>:9002/v1/list?path=/logs
GET http://<board>:9002/v1/list?path=/recordings
GET http://<board>:9002/v1/download?path=/recordings/a.h264
```

`/v1/info` 返回 `hostname`、`available`、`read_only`、`range` 等服务信息。
文件服务使用当前 TCP 连接配置的主机地址，不执行额外设备身份匹配。下载中断时保留
`.part` 并用 `Range: bytes=<size>-` 续传。录像可直接把 download URL 交给 media player。
该 API 仅暴露 `/logs` 与 `/recordings`，是只读的；Flight 中列表和下载返回 HTTP 423。

## 5. UDP 遥测 / TCP 字段发现

当前实时 UDP 是 DVT1 索引二进制；FireWater 仅用于板端本地记录及兼容旧板端。
TCP `get_telemetry_schema` 返回实际 MCU 注册或配置生效的名称/类型/index、schema_id 和 UART ready 状态。
此操作为只读，Flight 也允许；不要从 legacy rx_layout 猜测 telemetry_v1 的实际字段。

包格式（小端）：`DVT1 | schema_id:u32 | seq:u32 | stream_id:u32 | count:u16 |
(index:u8 + typed-value)*count | CRC32/IEEE:u32`。最多 26+64 字段，上限 1024 字节。
UART 原始类型保持；固定板端指标 float64。无 board_id。完整协议见主仓库
`docs/UDP_TELEMETRY_DVT1.md`。

HomeShell 持有 schema loader 和持续运行的 UDP 源。TCP 连接后查询；未知 schema 包先校验 CRC，
随后限频刷新（1 秒/最多一个请求），立即丢包而不排队。schema 指纹必须匹配，类型、索引、
长度、CRC 都要验证；同流去重/乱序过滤，序号支持回绕，worker 重启用临时 stream_id 区分。
不要把接收或查询生命周期放到 Telemetry/Ground Test 页面。

### UART 接收布局和录制

完整配置的 `uart.rx_layout` 控制板端如何对齐、校验和解码串口接收包：

```json
{
  "packet_size": 123,
  "header": 246,
  "checksum": "sum8",
  "checksum_offset": 122,
  "byte_order": "little",
  "fields": [
    {"name":"pitch", "type":"float32", "offset":1},
    {"name":"roll", "type":"float32", "offset":5},
    {"name":"yaw", "type":"float32", "offset":9},
    {"name":"air_speed", "type":"float32", "offset":13},
    {"name":"flight_data_flag", "type":"uint8", "offset":121}
  ]
}
```

`checksum` 为 `sum8` 时，除 `checksum_offset` 本身外的整个包逐字节求和并取低 8 位；`none` 不检查校验。`byte_order` 为 `little` 或 `big`。字段类型支持 `uint8/int8/uint16/int16/uint32/int32/float32/float64`，最多 64 项，包长 2..2048 字节。字段不得占用第 0 字节帧头、`sum8` 校验字节、越界或互相重叠，名称必须匹配 `[A-Za-z_][A-Za-z0-9_]{0,31}`。

上位机通过 `get_config` 读取并在 JSON 编辑器修改布局，再以完整 `set_config` 上传。该操作仅在 Ground 允许，会校验、原子保存并重启 worker；失败恢复旧配置。worker 状态的 `uart.rx_layout` 回显实际布局，`uart.values` 返回最近一次成功解出的全部值，`decode_errors` 统计校验通过但字段无法解码的包。

飞行记录期间，动态字段随每个 FireWater 样本写入配套的 `.telemetry.firewater`，名称为 `uart_rx_<name>`。这不是写入 H.264 码流；视频与遥测仍是同一飞行会话产生的两个文件。
服务启动前可通过环境变量改目的地址、端口和频率：

```sh
DART_UDP_TELEMETRY_HOST=10.149.242.2 DART_UDP_TELEMETRY_PORT=1347 \
DART_UDP_TELEMETRY_HZ=50 /etc/init.d/S99dart-slave restart
```

## 6. Flutter 精简任务

1. 删除 Preset/Recording/LAB/Detector mode 的状态、表单和请求。
2. 顶栏只保留 `Ground` / `Flight` 二段切换，飞行模式用醒目的锁定状态。
3. Ground 页面保留 RTSP、profile/rotation、NV21 阈值、ROI、ISP、UART。
4. Flight 页面只展示目标、FPS、UART、UDP、温度与错误，所有画面设置不可操作。
5. 解析 model 时忽略未知字段；mutation 串行执行，轮询不得覆盖用户正在编辑的 draft。
