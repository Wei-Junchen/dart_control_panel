# Dart Guidance Flutter 控制台：API 契约与迁移计划

> 目的：用 Flutter/Dart 重写当前 `..Dart_Maix/maixcdk_apps/dart_guidance_highfps_sg/host_master/dart_master.py`（Tkinter），保持板端协议和行为不变。
>
> 本文描述的是当前实现的 **newline JSON v1**，不是未来设想。协议权威实现位于
> `slave/dart_slave_daemon.py`，板端实时状态字段生成于 `main/src/main.cpp::make_debug_snapshot()`。

## 1. 系统边界与数据链

```text
Flutter app
  ├─ TCP 10.149.242.1:9000
  │    newline-delimited JSON v1
  │    ↓
  │  dart_slave_daemon.py（稳定控制面、配置持久化、worker 生命周期）
  │    └─ TCP 127.0.0.1:9001
  │         worker 私有调试协议（Flutter 不应直接连接）
  │         ↓
  │       dart_guidance_highfps_sg
  │
  └─ RTSP rtsp://10.149.242.1:8554/live
       H.264 视频；是否存在由 features.rtsp 决定
```

- Flutter 只依赖公开控制端口 `9000` 和 RTSP `8554`。
- `9001` 默认仅绑定板端回环地址，是 daemon 与 C++ worker 之间的实现细节。
- 控制协议没有认证或加密，只能用于可信局域网，不应映射到公网。
- 录像由板端直接写入 `release/recordings/`；当前 API 不提供录像文件下载。
- 视频上的识别框、ROI、帧号是板端 NV21 overlay 后再编码的，因此 Flutter 不需要重复绘制。

## 2. TCP framing

### 2.1 基本规则

- 编码：UTF-8。
- 每个 JSON object 后必须有一个 `\n`；不要依赖 TCP packet 边界。
- 单行最大 `8192` bytes。
- 每个合法请求固定产生两行响应：先 `accepted`，再 `result`。
- `id` 由客户端生成，必须是可转换为整数的值；建议使用单调递增的 Dart `int`。
- 服务器连接空闲约 30 秒后会关闭。最简单可靠的实现是“一次请求一次连接”；若复用长连接，需定期发送 `heartbeat` 并实现断线重连。
- daemon 的 `9000` 端口不主动推送状态；GUI 应每 `500 ms` 调用一次 `get_state`。
- 同一连接上应串行请求。若需要一边轮询、一边执行耗时切换，可使用独立 socket，但 UI 的 mutation queue 仍应串行化。

### 2.2 请求

```json
{"v":1,"type":"request","id":42,"op":"get_state","args":{}}
```

字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `v` | integer | 固定为 `1` |
| `type` | string | 固定发送 `request` |
| `id` | integer | 请求关联 ID |
| `op` | string | 操作名称 |
| `args` | object | 无参数时发送 `{}` |

### 2.3 正常响应

第一行立即确认请求已经解析：

```json
{"v":1,"type":"accepted","id":42,"mono_us":123456789}
```

第二行返回最终结果：

```json
{"v":1,"type":"result","id":42,"ok":true,"state":"STREAMING","config_rev":184,"payload":{}}
```

Flutter 必须同时检查：

1. 两行都能解析为 JSON object；
2. 第一行 `type == "accepted"`；
3. 第二行 `type == "result"`；
4. 两行 `id` 均与请求相同；
5. `result.ok == true`。

### 2.4 失败响应

操作执行失败：

```json
{"v":1,"type":"result","id":42,"ok":false,"state":"STREAMING","config_rev":184,"error":"gain verification failed: requested=1024/1024/1024 actual=..."}
```

请求本身无法解析时，可能只收到一行且没有 ID：

```json
{"v":1,"type":"error","message":"invalid request"}
```

不要仅凭 `accepted` 更新 UI。只有 `result.ok == true` 才算成功；失败后立即重新 `get_state`，恢复板端真实值。

## 3. 操作清单

建议应用启动后依次调用：`get_schema` → `get_profiles` → 周期性 `get_state`。

| `op` | `args` 示例 | 返回 `payload` | 行为 |
|---|---|---|---|
| `get_state` | `{}` | state envelope | 读取完整状态 |
| `get_profiles` | `{}` | profile map | 读取支持的采集/视图组合 |
| `get_schema` | `{}` | ops/runtime keys/presets | 能力发现 |
| `get_logs` | `{"lines":120}` | `{"lines":[...]}` | 1–500 行 worker 日志 |
| `heartbeat` | `{}` | daemon 时间和状态 | 连接保活/延迟检测 |
| `start_worker` | `{"profile":"full_wide_640x360"}` | state envelope | 启动；无 profile 时用 last-known-good |
| `stop_worker` | `{}` | state envelope | 停止 worker |
| `restart_worker` | `{}` | state envelope | 重启当前/last-known-good |
| `camera_standby` | `{}` | state envelope | GC4653 software standby，控制面保持在线 |
| `camera_wake` | `{}` | state envelope | 快速唤醒并验证连续有效帧 |
| `apply_readout_profile` | `{"profile":"full_square_360"}` | state envelope | 事务切换，失败自动回滚 |
| `apply_runtime` | 见第 5 节 | worker result | 热更新识别/ISP/控制参数 |
| `set_uart` | `{"enabled":true}` | state envelope | UART 开关；运行中会重启 worker |
| `set_rotation` | `{"degrees":90}` | state envelope | 仅 `0/90/180/270`；运行中会重启 |
| `set_features` | 见第 6 节 | state envelope | 自定义功能组合；通常重启 worker |
| `apply_feature_preset` | `{"preset":"debug"}` | state envelope | 应用功能预设 |
| `start_recording` | `{"record_every_n":4}` | state envelope | 启动或调整录像，必要时唤醒 |
| `stop_recording` | `{}` | state envelope | 停止录像 |
| `rotate_recording` | `{}` | state envelope | 关闭当前文件并开始新文件；必须正在录像 |
| `reboot_board` | `{"confirm":true}` | reboot schedule | 仅在明确确认后使用 |

### 状态返回的双层 envelope

`get_state` 以及多数生命周期操作返回的是：

```text
result.payload                 -> state envelope
result.payload.payload         -> UI 真正使用的 DaemonState
result.payload.payload.worker  -> C++ worker 实时状态
```

不要误把 `result.payload` 直接当成 `DaemonState`。

## 4. State schema

下面是字段结构示意。数字仅为示例，客户端必须允许后端追加未知字段，并为暂时缺失的 worker 字段提供默认值。

```json
{
  "v": 1,
  "type": "state",
  "seq": 101,
  "mono_us": 123456789,
  "payload": {
    "state": "STREAMING",
    "profile": "full_wide_640x360",
    "pending_profile": null,
    "rotation": 0,
    "config_rev": 184,
    "last_known_good": "full_wide_640x360",
    "last_error": "",
    "worker_pid": 363,
    "daemon_uptime_s": 3600.5,
    "restarts": 1,
    "features": {
      "preset": "debug",
      "uart_enabled": true,
      "rtsp": true,
      "recording": false,
      "overlay": true,
      "record_every_n": 1
    },
    "resources": {
      "vb_active": true,
      "vb_pool_count": 7,
      "mipi_loaded": true,
      "mipi_users": 1,
      "temperature_c": 51.2,
      "power_w": null,
      "needs_reboot": false
    },
    "worker": {
      "type": "state",
      "timestamp_ms": 123456,
      "frame_count": 9000,
      "lifecycle": {
        "state": "STREAMING",
        "sensor_standby": false,
        "reg0100": 9,
        "standby_ms": 0,
        "last_wake_ms": 34.5,
        "standby_count": 1,
        "standby_failures": 0,
        "wake_count": 1,
        "wake_failures": 0
      },
      "performance": {
        "fps": 79.8,
        "requested_fps": 80,
        "process_ms": 0.52,
        "detection_fps": 79.8,
        "process_max_ms": 0.8,
        "timeouts": 0,
        "errors": 0
      },
      "target": {
        "found": true,
        "x": 180,
        "y": 120,
        "pixels": 87,
        "area": 240,
        "rect": [170, 110, 20, 24],
        "brightness": 73.0,
        "pitch_control": 0.01,
        "yaw_control": -0.02
      },
      "vision": {
        "detector_mode": "nv21_score",
        "green_score": {
          "y_min": 20,
          "g_min": 50,
          "score_min": 60,
          "rg_min": 20,
          "gb_min": 20,
          "coarse_stride": 4,
          "refine_radius": 12
        },
        "lab": [20, 60, -128, -20, 0, 60],
        "edge_x": 0,
        "edge_y": 0,
        "detect_roi": [40, 40, 280, 160],
        "search_radius": 20,
        "area_threshold": 10,
        "pixels_threshold": 10,
        "x_stride": 1,
        "y_stride": 1,
        "detect_every_n": 1,
        "detection_frames": 8990,
        "jobs_dropped": 0,
        "detection_age_frames": 0,
        "profile_us": {
          "coarse": 30,
          "threshold": 180,
          "blob": 280,
          "coarse_samples": 3150,
          "fine_samples": 3000,
          "fine_passes": 200
        }
      },
      "camera": {
        "output": [640, 360],
        "sensor": [1280, 720],
        "format": "NV21",
        "exposure_us": 1000,
        "gain": 1024,
        "again": 1024,
        "dgain": 1024,
        "isp_dgain": 1024,
        "awb_auto": false,
        "streaming": true,
        "isp": {
          "valid": true,
          "exposure_us": 999,
          "again": 1024,
          "dgain": 1024,
          "isp_dgain": 1024,
          "iso": 100,
          "average_luma": 7,
          "awb_auto": false,
          "wb_valid": true,
          "wb_gain": [2095, 1024, 1024, 1974],
          "color_temperature": 5432
        }
      },
      "view": {
        "profile": "wide_640x360",
        "crop_enabled": false,
        "crop": [0, 0, 1280, 720],
        "pre_rotation_output": [640, 360],
        "rotation": 0,
        "visible_offset_x": 0,
        "output": [640, 360],
        "scale": [0.5, 0.5],
        "coordinate_space": "view"
      },
      "overlay": {"enabled": true, "roi": true},
      "control": {
        "mode": "angle_rad",
        "fx": 277.0,
        "fy": 277.0,
        "roll_unit": "deg",
        "roll_sign": 1.0,
        "distance": 0.0
      },
      "uart": {
        "open": true,
        "rx_bytes": 0,
        "rx_packets": 0,
        "crc_errors": 0,
        "align_drops": 0,
        "tx_packets": 8990,
        "tx_errors": 0,
        "tx_last_gap_us": 12500,
        "tx_min_gap_us": 12400,
        "tx_max_gap_us": 13000,
        "telemetry_valid": false,
        "pitch": 0.0,
        "roll": 0.0,
        "yaw": 0.0,
        "air_speed": 0.0
      },
      "stream": {
        "rtsp_enabled": true,
        "rtsp_port": 8554,
        "recording": false,
        "record_path": "",
        "record_every_n": 1,
        "record_fps": 80,
        "source_frames": 9000,
        "input_frames": 8998,
        "rtsp_clients": 1,
        "encoded_frames": 8995,
        "encoded_bytes": 10485760,
        "record_errors": 0
      },
      "debug": {"clients": 1, "accepted": 10, "commands": 3, "errors": 0}
    }
  }
}
```

### Daemon state 枚举

正常可见值包括：

```text
STOPPED, STARTING, STREAMING, STANDBY_PENDING, STANDBY,
WAKING, STOPPING, ERROR
```

UI 不应假设只有 `STREAMING/STOPPED`。在过渡状态中禁用冲突按钮，并显示进度。

### requested 与 actual 必须分开显示

- `worker.camera.again/dgain/isp_dgain/exposure_us`：请求值。
- `worker.camera.isp.*`：ISP 实际回读值。

例如 GC4653 模拟增益可能量化。是否真正生效应以 `camera.isp` 为准，不能只看请求字段。

## 5. `apply_runtime`

示例：

```json
{
  "v": 1,
  "type": "request",
  "id": 43,
  "op": "apply_runtime",
  "args": {
    "detector_mode": "nv21_score",
    "green_y_min": 20,
    "green_g_min": 50,
    "green_score_min": 60,
    "green_rg_min": 20,
    "green_gb_min": 20,
    "coarse_stride": 4,
    "refine_radius": 12,
    "detect_roi": "40,40,280,160",
    "pixels_threshold": 10,
    "area_threshold": 10,
    "search_radius": 20,
    "x_stride": 1,
    "y_stride": 1,
    "detect_every_n": 1,
    "exposure_us": 1000,
    "again": 1024,
    "dgain": 1024,
    "isp_dgain": 1024,
    "awb_auto": false,
    "overlay": true,
    "overlay_roi": true
  }
}
```

### 5.1 字段和约束

| 字段 | JSON 类型 | 范围/格式 |
|---|---|---|
| `detector_mode` | string | `lab`, `nv21_score`；后端也接受别名 `fast` |
| `lab` | string | `Lmin,Lmax,Amin,Amax,Bmin,Bmax` |
| `l_min`, `l_max` | integer | `0..100` 且 min ≤ max |
| `a_min`, `a_max`, `b_min`, `b_max` | integer | `-128..127` 且 min ≤ max |
| `green_y_min`, `green_g_min` | integer | `0..255` |
| `green_score_min` | integer | `-510..510` |
| `green_rg_min`, `green_gb_min` | integer | `-255..255` |
| `coarse_stride` | integer | `1..16`，不能传空串或 `","` |
| `refine_radius` | integer | `1..256` |
| `detect_roi` | string | `x,y,w,h`，必须在输出画面内；也可 `off`/`none`/`legacy` |
| `edge_x` | integer | `>=0` 且 `2*edge_x < output_width` |
| `edge_y` | integer | `>=0` 且 `< output_height` |
| `search_radius` | integer | `1..max(output_width, output_height)` |
| `area_threshold`, `pixels_threshold` | integer | `1..output_width*output_height` |
| `x_stride`, `y_stride` | integer | `1..8` |
| `detect_every_n` | integer | `1..120` |
| `overlay`, `overlay_roi` | boolean | 严格布尔值；不要从 TextField 直接传字符串 |
| `control_mode` | string | `pixel` 或 `angle_rad` |
| `fx`, `fy` | number | `>0` |
| `roll_sign`, `distance` | number | 有限浮点数 |
| `roll_unit` | string | `deg` 或 `rad` |
| `exposure_us` | integer | `0`=自动；手动最大值约为 `1e6/fps-100` |
| `gain` | integer | `again` 的兼容别名 |
| `again`, `dgain`, `isp_dgain` | integer | `0`=不改；否则 `1024..262144`，`1024=1.0x` |
| `awb_auto` | boolean | `false` 会冻结切换瞬间的实际 WB gain |
| `reset_tracker` | boolean | `true` 清空跟踪状态 |

规则：

- 手动设置任一 gain 时，当前/同包 `exposure_us` 必须大于 0。
- `lab`、`detect_roi` 是 **无空格 CSV string**，不是 JSON array。
- 所有整数输入框在发包前必须完成解析与范围校验；空值不要序列化。之前 Tk GUI 的 `coarse_stride:","` 就会被后端正确拒绝。
- 可以只发送变化字段，不需要每次把整张表重发。
- 成功后再请求一次 `get_state`，用 actual ISP 值和当前 vision 值刷新只读状态。
- 编辑中的 draft 不得被 500 ms 轮询覆盖；只在首次加载、用户点击“从板端重新加载”、或成功应用后同步表单。

`apply_runtime` 成功的 daemon payload 是 worker result，而不是 state envelope，例如：

```json
{
  "v": 1,
  "type": "result",
  "id": 7,
  "ok": true,
  "message": "applied again awb_auto exposure_us"
}
```

外层 daemon `result` 仍然有自己的 `id`；不要混淆两个不同层级的 ID。

## 6. Features、RTSP 与录像

### 6.1 功能预设

| preset | RTSP | recording | overlay | record_every_n |
|---|---:|---:|---:|---:|
| `debug` | true | false | true | 1 |
| `training` | true | true | true | 4 |
| `competition` | false | true | false | 4 |
| `idle` | false | false | false | 1 |

自定义示例：

```json
{"v":1,"type":"request","id":50,"op":"set_features","args":{"rtsp":true,"recording":true,"overlay":true,"uart":true,"record_every_n":2}}
```

`set_features` 仅接受：

```text
rtsp:boolean, recording:boolean, overlay:boolean,
uart:boolean, record_every_n:integer(1..120)
```

注意：

- `overlay` 同时影响 RTSP 与录像编码流。
- 功能、UART、旋转和 readout profile 切换通常会重启 worker。GUI 应显示 busy 状态，不能假装是即时 toggle。
- `idle` preset 会让传感器进入 standby；切换到其他 preset 会唤醒。
- `rotate_recording` 不是画面旋转，而是“切换到一个新的录像文件”。画面旋转使用 `set_rotation`。

### 6.2 RTSP 播放要求

- URL 默认是 `rtsp://<board-ip>:8554/live`。
- 优先使用 RTSP-over-TCP、低缓存、低延迟播放设置。
- RTSP 是否可用看 `features.rtsp` 和 `worker.stream.rtsp_enabled`，不能仅凭端口写死。
- Flutter 播放组件必须在 Linux、Windows、macOS 分别做真机验证；不要在第一阶段把视频解码和控制协议耦合。
- 断流时只重建播放器，不要自动重启板端 worker。

## 7. Profiles（当前 v1）

客户端应动态使用 `get_profiles`，不要把下面列表写死：

```text
fast_square_240
fast_square_360
fast_landscape_360x240
p4_control_vpss_640x360
p4_experimental_sensor_640x360_fullcis
full_square_240
full_square_360
full_landscape_360x240
full_wide_640x360
```

每项包含：

```json
{
  "readout": "full_1280x720_80",
  "view": "wide_640x360",
  "features": "debug",
  "status": "stable",
  "expected": {"sensor":[1280,720],"output":[640,360],"fps":80}
}
```

`status` 是可选字段。90/270 度旋转后，实际 output 宽高会交换。

## 8. Flutter 建议架构

保持依赖少、协议层可单测：

```text
  README.md
  pubspec.yaml
  lib/
    main.dart
    app.dart
    protocol/
      ndjson_codec.dart
      daemon_client.dart
      protocol_exception.dart
    models/
      daemon_state.dart
      worker_state.dart
      profile.dart
      runtime_draft.dart
    repositories/
      board_repository.dart
    controllers/
      connection_controller.dart
      state_poll_controller.dart
      mutation_controller.dart
      video_controller.dart
    screens/
      dashboard_screen.dart
      video_screen.dart
      tuning_screen.dart
      camera_screen.dart
      features_screen.dart
      diagnostics_screen.dart
    widgets/
      metric_card.dart
      target_status.dart
      runtime_form.dart
  test/
    fixtures/
    ndjson_codec_test.dart
    daemon_client_test.dart
    state_model_test.dart
    runtime_validation_test.dart
```

原则：

- `DaemonClient` 只负责 socket/framing/request ID/timeout，不包含 UI 逻辑。
- model 解析必须 forward-compatible：未知 key 忽略，缺失的嵌套 object 可为空。
- `BoardRepository` 负责双层 state envelope 解包。
- state poll 与 mutation 分开；mutation 期间可继续显示状态，但禁止重复提交相同操作。
- Runtime 使用 `draft` 与 `actual state` 两套对象，轮询绝不能改写用户正在编辑的 draft。
- 使用 Material 3、响应式 NavigationRail/NavigationBar、亮/暗主题；不要机械复刻 Tkinter 的标签页布局。
- 第一版不做板端协议改造，不引入 WebSocket，也不让 Flutter 直连 9001。

## 9. 实施 Plan

### P0 — 协议冻结与 fixture

1. 将本文请求/响应和完整 state 示例保存为测试 fixture。
2. 为成功、操作失败、非法请求、断行、半包、粘包、超时准备 fixture。
3. 确认 acceptance：Dart 单测能正确组装一行请求，并解析 accepted + result。

**完成标准：** 不启动 Flutter UI 也能用 Dart CLI 调用 `get_state/get_schema/get_profiles`。

### P1 — Flutter shell 与控制协议

1. 创建 Flutter desktop 项目，先支持 Linux，保留 Windows/macOS 构建目标。
2. 实现 `NdjsonCodec`、`DaemonClient`、typed models、repository。
3. 实现连接状态、一次请求一次连接、超时、指数退避重连。
4. `get_state` 每 500 ms 轮询；非活动窗口可降到 1–2 s。

**完成标准：** Dashboard 连续运行 30 分钟，拔网线/重连板子不会崩溃，不产生并发 poll 堆积。

### P2 — 现代 Dashboard

1. Material 3 responsive shell。
2. 状态卡：daemon/worker、FPS、检测 FPS、目标、温度、VB/MIPI、UART、RTSP/录像。
3. requested/actual ISP 并排显示，差异高亮。
4. 明确显示 STARTING/STANDBY/WAKING/ERROR 等过渡状态。

**完成标准：** 与 Tk GUI 同屏信息等价，但布局可在 1024×600 至桌面宽屏自适应。

### P3 — 识别与 ISP 调参

1. typed form + 本地验证；整数、浮点、CSV 分开控件。
2. 实现 dirty field，只提交变化项。
3. “应用”“撤销本地修改”“从板端重新加载”三个明确动作。
4. 成功后 `get_state`；失败展示后端 error 且保留用户 draft。
5. ROI 可选做视频画布上的拖拽编辑，但最终仍发送 `x,y,w,h` CSV。

**完成标准：** 用户可持续输入而不被轮询覆盖；不会再产生空 `coarse_stride` 等非法包。

### P4 — 相机生命周期与功能调度

1. profile、rotation、start/stop/restart、standby/wake。
2. presets/custom features、UART、录像 start/stop/rotate。
3. 所有重启型操作有 busy overlay、结果反馈及失败后真实状态刷新。
4. reboot 必须二次确认，且 UI 仅在 `resources.needs_reboot == true` 时主动建议。

**完成标准：** 切换失败时 UI 能显示 daemon 的 rollback 结果，不留下假 toggle 状态。

### P5 — RTSP 低延迟视频

1. 抽象 `VideoController`，再选择支持目标桌面平台 RTSP/H.264 的播放器后端。
2. RTSP-over-TCP、低缓存；连接、缓冲、断流、手动重连状态可见。
3. 视频与控制断线分别处理。
4. 验证 80/120 fps 源不会拖慢 UI；预览可降帧，但不得反压板端录像。

**完成标准：** 连续预览 30 分钟；开关 overlay/录像/profile 后播放器可恢复；控制面仍保持流畅。

### P6 — 诊断、导出与跨平台发布

1. schema/log viewer、JSON 状态导出、复制诊断摘要。
2. 保存多个板端地址和最后连接记录，但不保存敏感凭据。
3. Linux/Windows/macOS 打包；至少对 socket、RTSP native runtime、文件导出逐平台 smoke test。
4. CI 运行纯 Dart 协议/model/form 测试；硬件测试单列，不阻塞普通 CI。

**完成标准：** 可生成独立安装包；无 Python/Tk/Pillow 依赖；README 含启动和故障排查。

## 10. 不在首版范围内

- 修改板端 JSON v1 或替换 daemon。
- WebSocket/HTTP 网关。
- Flutter 直连 worker `9001`。
- 从板端下载/管理录像文件。
- 客户端重新进行目标识别。
- 手机端后台 RTSP、远程公网控制、用户认证。

这些需求应在 Flutter MVP 稳定后作为 JSON v2 或独立服务设计，避免边迁移 UI 边改协议。
