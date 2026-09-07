# Dart Guidance 控制台 — 板端新增接口提案（等待板端实现）

> 状态：**提案**。GUI（本仓库）已按下面的契约接线；板端实现后无需改 GUI。
> 约定：所有新增内容遵循现有 newline JSON v1 的 framing / id / accepted+result 规则，
> 客户端保持 forward-compatible —— 字段缺失时使用默认值，绝不强依赖。

## 1. `set_mode` — 地面测试 / 实战模式切换

### 1.1 动机

GUI 的"模式"页（Mode）提供一个 Ground（地面测试）↔ Flight（实战）切换入口。
板端负责真正的工作模式语义，GUI 只负责发起切换并展示结果。

### 1.2 请求

```json
{"v":1,"type":"request","id":7,"op":"set_mode","args":{"mode":"flight"}}
```

`mode` 取值：`"ground"` | `"flight"`（唯一两个合法值）。

切换语义建议（由板端最终定义）：

- **ground**：面向识别参数调试。建议 RTSP 开、录像关、overlay 开、UART 遥测按需。
- **flight**：面向实战。建议 RTSP 关、录像开（内录）、overlay 关、遥测持续记录。
  应做**事务式**切换：任何一步失败（传感器/编码器/存储）必须回滚到原模式，
  并在 `last_error` 中说明回滚原因。

切换过程可能耗时（重启 worker、切换黑盒权限等），GUI 会显示 busy 状态，
且在切换完成前不认为切换成功（与 `apply_readout_profile` 相同的 UI 契约）。

### 1.3 成功响应（同现有 state envelope）

```json
{"v":1,"type":"result","id":7,"ok":true,"state":"STREAMING","config_rev":185,
 "payload":{
   "v":1,"type":"state","seq":102,"mono_us":123456790,
   "payload":{
     "state":"STREAMING",
     "mode":"flight",
     "profile":"full_wide_640x360",
     ...
   }
 }}
```

### 1.4 state envelope 新增字段（可选，缺省使用默认值）

| 字段 | 类型 | 说明 |
|---|---|---|
| `payload.mode` | string | `"ground"` 或 `"flight"`；缺失时 GUI 默认 `"ground"`（未实现前的兼容值） |
| `payload.mode_pending` | string 或 null | 正在切换中的目标模式；切换完成/失败回滚后置 null |
| `payload.mode_transition` | boolean | 可选：切换期间为 true，GUI 据此禁用冲突按钮 |

推荐做法：`mode_transition` 期间把 `payload.state` 设为既有的过渡态之一
（`STARTING` / `STOPPING`），避免引入新枚举。

### 1.5 失败响应

```json
{"v":1,"type":"result","id":7,"ok":false,"state":"STREAMING","config_rev":185,
 "error":"mode switch failed: storage not ready; rolled back to ground"}
```

GUI 行为：展示 error 文本，立即 `get_state` 刷新真实模式，不保留假切换状态。

### 1.6 未实现时（板端现状）

板端收到未知 op 时按现有规则返回
`{"v":1,"type":"error","message":"unknown op"}`；GUI 会显示
"板端尚未实现 set_mode（见 update.md）"并保持本地可用。

## 2. 遥测接口（地面测试 / 飞行数据记录）

GUI 遥测页当前使用 **dummy 数据源**（见 `lib/telemetry/`）。
`TelemetrySource` 接口是唯一接缝；板端实现后按下面的 schema 提供数据即可。

### 2.1 方案选择：轮询 `get_telemetry`（推荐，与 9000 风格一致）

```json
{"v":1,"type":"request","id":9,"op":"get_telemetry","args":{}}
```

成功响应 payload：

```json
{"v":1,"type":"result","id":9,"ok":true,"state":"STREAMING","config_rev":185,
 "payload":{
   "pitch_deg": -3.2,
   "roll_deg": 141.5,
   "yaw_deg": 47.8,
   "air_speed_ms": 18.3,
   "altitude_m": 0.0,
   "sensor_time_ms": 88123456,
   "fps": 0
 }}
```

### 2.2 字段表

| 字段 | 类型 | 说明 |
|---|---|---|
| `pitch_deg` | number | 俯仰角（度），-180..180 |
| `roll_deg` | number | 滚转角（度），-180..180 |
| `yaw_deg` | number | 偏航角（度），-180..180 或 0..360，GUI 两种都接受 |
| `air_speed_ms` | number | 空速（m/s），地面测试可为 0 |
| `altitude_m` | number | 可选项：高度（m） |
| `fps` | number | 可选项：回传帧率（仅 ground 有意义） |
| `sensor_time_ms` | number | 板端单调时钟（可选，用于对齐多源数据） |

- 速率：GUI 将按 25–50 Hz 轮询（可在 `TelemetryController` 调整）；
  板端在该频率下应能低成本应答（读共享结构体即可）。
- 字段缺失：GUI 侧按 NaN 处理（曲线跳过、姿态显示 `--`）。
- Ground 模式下该接口应始终可用；Flight 模式下若遥测本就持续记录，
  建议同样应答（数据来自记录缓冲的最新帧），否则返回 `ok:false` 与原因，
  GUI 会显示"遥测不可用"。

### 2.3 与 GUI 的对接方式

```dart
class BoardTelemetrySource implements TelemetrySource {
  // start(): 起 Timer.periodic(40ms) 调 repository.getTelemetry()
  //          把 payload 映射为 TelemetrySample(values: {pitch,roll,yaw,air_speed,fps,...})
  // stop():  取消 Timer
}
```

```dart
// GUI 唯一改动点（预期）：
final controller = TelemetryController(source: BoardTelemetrySource(repository));
```

### 2.4 模式联动（可选增强）

板端实现 `set_mode` 后，GUI 会读取 `payload.mode`：
- `flight`：遥测页曲线保留，姿态指示器继续显示（若 FPS 帧无意义则置 `fps` NaN）；
- 若板端遥测在 flight 下不可用，GUI 显示不可用提示，不报错。

## 3. 非目标

- 文件传输：GUI 走 **ssh/scp**（root + 密钥），不需要新 JSON 接口。
- 本提案不改变 framing、不新增推送通道（保持 9000 请求/响应模型）。