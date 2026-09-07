# dart_control_panel

LicheeRV Nano based guidance dart control panel (Dart Guidance Flutter console).

A Flutter desktop client for the board daemon's **newline-delimited JSON v1**
control protocol (`10.149.242.1:9000`), built from the contract in
[`AGENTS.md`](AGENTS.md). Board-side C++ / slave daemon / protocol are **not**
modified; this repo is the client only.

## Status (implemented so far)

- **P0 — protocol + fixtures**: NDJSON codec, one-request-per-connection
  client with `accepted`/`result` + same-id validation, forward-compatible
  typed models, and a pure-Dart CLI (`bin/dart_cli.dart`).
- **P1 — shell + control plane**: connection bar, `get_state` polling every
  500 ms (no pileup, slow when window inactive), exponential backoff while the
  transport is down, disconnect/reconnect.
- **P2 — modern dashboard**: Material 3 responsive shell
  (NavigationRail wide / NavigationBar narrow) that owns the **single board
  connection**: Connect/Disconnect live in the bottom-left dock and feed one
  shared `BoardSession` + one 500 ms poll to every page — switching pages
  never disconnects and never requires a second connect. Info parity with the
  old Tk GUI — daemon, performance/FPS, detection FPS, target, vision,
  requested vs actual ISP side by side with diff highlighting,
  temperature/VB/MIPI, UART, RTSP/recording, view/control. Transitional
  states (STARTING / STANDBY_PENDING / WAKING / STOPPING) show a banner +
  progress instead of implying a settled state. Layout adapts from 1024×600
  to wide desktop.
- **P3 — recognition & ISP tuning**: typed form with separate int/float/bool/
  enum controls, dirty-field tracking with only-changed submission, CSV
  composites (`lab`, `detect_roi`) edited component-wise but serialized
  space-free, full range/constraint validation (guards the historical
  `coarse_stride:","` bug). Explicit Apply / Revert local edits / Reload from
  board; success refreshes via `get_state`, failure shows the backend error and
  keeps the draft. The draft is never touched by polling.
- **P4 — camera lifecycle & feature scheduling**: `MutationQueue` serializes
  all mutations; `BoardSession` re-fetches daemon state after every mutation —
  including failures, so a rejected/rolled-back switch never leaves a fake
  toggle (daemon's rollback error is shown). Camera screen: start/stop/restart,
  standby/wake, transactional readout profile (from dynamic `get_profiles`),
  rotation 0/90/180/270, double-confirm reboot + `needs_reboot` suggestion
  banner. Features screen: presets (debug/training/competition/idle), custom
  features (rtsp/recording/overlay/uart/record_every_n), UART switch,
  recording start/stop/rotate. Restart-type ops show busy state and disable
  conflicting buttons during transitional states.
- **P5 — RTSP low-latency preview**: `VideoController` + `VideoBackend` seam
  with a media_kit (libmpv) backend for Linux/Windows/macOS. Low-latency
  settings mirror the verified ffplay command (`rtsp-transport=tcp`,
  `demuxer-lavf-o=fflags=nobuffer`, `vd-lavc-o=flags=low_delay`, `framedrop`,
  `cache=no`) so the preview never backpressures board recording. Video
  transport state (connecting/buffering/playing/paused/error) is shown
  separately from the control plane; a stream drop only ever offers a manual
  player rebuild — never an automatic worker restart. Preview availability is
  gated on `features.rtsp` AND `worker.stream.rtsp_enabled` (never assumed by
  port). `DART_RTSP_TRANSPORT=udp` env fallback available.
- **P6 — diagnostics, export & packaging**: Diagnostics screen with daemon
  schema viewer, worker log viewer (50/100/200/500 lines), JSON state export
  (native save dialog), one-page copy-to-clipboard diagnostics summary, and
  saved-board management (several addresses + last-used, persisted in
  `~/.config/dart_control_panel/addresses.json`, no credentials ever).
  Packaging: `tool/package_linux.sh` produces a standalone release tar.gz
  (verified to launch without env vars). CI runs `flutter analyze` + all
  headless tests on ubuntu; hardware/RTSP tests stay out of CI.
- **新导航（4 项）**：Telemetry（姿态+遥测+daemon 摘要条）、Ground Test
  （左 RTSP 实时画面 + 画面配置，右识别/ISP 调参）、Mode（Ground/Flight
  切换 + 生命周期/特征/录像/重启收纳）、Files（ssh/scp 双向文件传输：
  root+密钥、根目录浏览、书签收藏、下载到本地/上传到板端）。
  Diagnostics（schema/日志/导出/已存地址）收进 Telemetry 页右上工具菜单。
- **3D 姿态**（俯视后左视角）：固定地面系（中性色 X/Y/Z，导弹中心、不转）
  + 刚体系（随姿态旋转的 x/y/z 三色正交架）；导弹绕自身质心 3/4 侧视旋转。
- **遥测（dummy 源）**：通道勾选 + 20 s 实时多曲线（含图例色），
  `DummyTelemetrySource` 按 Ground/Flight 包线输出（飞行包线 fps=NaN）。
  接缝：`TelemetrySource` → `TelemetryController`。
- **Mode 与遥测接口提案**：见 `update.md`（set_mode + get_telemetry），
  板端实现后 GUI 无需改动即可接线。
- **Not yet**: Windows/macOS installers (flutter build windows/macos run
  locally per platform; media_kit covers both).

## Layout

```text
bin/dart_cli.dart            P0: pure-Dart CLI (get_state/get_schema/get_profiles/get_logs/heartbeat)
lib/
  protocol/                  ndjson_codec, daemon_client, protocol_exception
  models/                    daemon_state, profile, runtime_draft (P3), json_view,
                             board_address_store (P6), diagnostics_summary (P6)
  repositories/              board_repository (double-envelope unwrap, request ids,
                             apply_runtime, P4 lifecycle ops)
  controllers/               connection_controller (backoff), state_poll_controller,
                             mutation_queue (P4), board_session (P4),
                             video_controller (P5), telemetry_controller (TELE)
  telemetry/                 telemetry_source (TELE seam), dummy_telemetry_source (TELE),
                             telemetry_sample (+ channels)
  video/                     video_backend (P5 seam + rtspUrl), media_kit_backend (P5)
  screens/                   home_shell (4 项导航), telemetry_screen (TELE+工具菜单→
                             diagnostics_screen P6), ground_test_screen (视频+调参),
                             mode_screen (set_mode + 板端控制), files_screen (ssh/scp)
  widgets/                   state_dashboard (P2 cards), tuning_form (P3), video_panel (P5),
                             attitude_view (TELE 3D), telemetry_chart (TELE),
                             metric_card, connection_bar
tool/                        build_linux.sh / run_linux.sh / run_bundle.sh / bundle_libs.sh
                             (media_kit build quirks), package_linux.sh (P6 release tar.gz)
services/                    board_ssh (ssh/scp, root+密钥, 无 shell 拼接)
update.md                    板端接口提案：set_mode + get_telemetry（等待板端实现）
.github/workflows/ci.yml     flutter analyze + flutter test on ubuntu (no hardware)
test/
  fixtures/                  NDJSON exchange fixtures (ok/fail/id-mismatch/extra-fields/
                             apply_runtime/reboot/lifecycle-rejected)
  ndjson_codec_test.dart     framing: half/coalesced packets, oversize, bad UTF-8
  daemon_client_test.dart    against a local mock daemon socket
  state_model_test.dart      full fixture parse + forward-compat + defaults
  board_repository_test.dart envelope unwrap through a chunked mock server
  controllers_test.dart      fakeAsync: 500 ms cadence, no pileup, backoff, inactivity
  dashboard_widget_test.dart P2: cards render, ISP diff highlight, transitional
                              banner, responsive NavigationRail/NavigationBar
  runtime_validation_test.dart P3: dirty tracking, CSV composites, range checks
  tuning_form_widget_test.dart  P3: typed controls, dirty markers, apply/revert/reload
  mutation_queue_test.dart   P4: serialized mutations, busy flags, error recovery
  board_session_test.dart    P4: connect/refresh, rollback result + state refresh
  video_controller_test.dart P5: status machine, reconnect, no pileup (fake backend)
  video_panel_widget_test.dart P5: panel states, reconnect button, rtsp gating
  diagnostics_test.dart      P6: address store persistence, summary builder
  telemetry_controller_test.dart TELE: ring buffer, selection, series, dummy cadence
  telemetry_widget_test.dart TELE: attitude view, chart, screen run/pause
  file_controller_test.dart  文件面板：ls 解析/导航/书签/scp 下载上传（fake ssh）
  new_screens_widget_test.dart GroundTest/Mode/Files 页面 widget 测试
  mode_setup_test.dart       set_mode op + DaemonState.mode + 飞行遥测包线
```

## Run

```
启动后从左下角的 Connect 连接一次，所有页面共用同一连接。
```

On this machine media_kit's libmpv is not installed system-wide and bare
`flutter run` / `flutter build` produce a bundle that fails to launch
(`libmujs.so.1: cannot open shared object file`). Always start through the
wrappers in `tool/`:

```bash
tool/run_linux.sh                      # dev loop: flutter run -d linux (safe)
tool/build_linux.sh --debug            # build bundle, ships patched media_kit runtime
tool/run_bundle.sh                     # launch the built bundle (auto-repairs libs)
```

`tool/bundle_libs.sh` reuses `/home/litwei/projects/DartVisionReceiver/.local-deps`
for compiling and ships the pre-patched (RUNPATH=$ORIGIN) libmpv/mujs/sixel +
`libmedia_kit_video_plugin.so` from that project's bundle — without them every
fresh build writes a plugin RUNPATH that cannot resolve libmpv/libmujs.
Windows/macOS builds do not need this.

Optionally prefill/auto-connect with environment variables (used by headless
smoke tests and demos):

```bash
DART_CTRL_HOST=10.149.242.1 DART_CTRL_PORT=9000 tool/run_linux.sh
```

Without a board, run the included fixtures against a tiny mock daemon
(`test/fixtures/exchanges/*.ndjson`) and point the app at it.

## P0 CLI (no Flutter UI required)

```bash
dart run bin/dart_cli.dart --host 10.149.242.1 get_state
dart run bin/dart_cli.dart --host 10.149.242.1 get_schema
dart run bin/dart_cli.dart --host 10.149.242.1 get_profiles
dart run bin/dart_cli.dart --host 10.149.242.1 get_logs '{"lines":120}'
```

## Verification log

| command | result |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | `+163: All tests passed!` |
| `./tool/build_linux.sh --debug` | `✓ Built ...bundle/dart_control_panel` (media_kit + patched libmpv bundled, runs without env vars) |
| `./tool/package_linux.sh` | `dist/dart_control_panel-0.1.0-linux-x64.tar.gz` (13M), extracted copy launches standalone |
| CLI vs fixture mock (`get_state/get_schema/get_profiles/get_logs/heartbeat`) | all `exit=0` |
| GUI smoke under `xvfb-run` (auto-connect, 6 s) | process alive, 500 ms poll cadence, `package:media_kit_libs_linux registered` |

## Troubleshooting

- **`libmujs.so.1: cannot open shared object file` on launch** — the bundle
  was regenerated by a bare `flutter run`/`flutter build` (see above). Run
  `tool/run_bundle.sh` (auto-repairs) or rebuild with `tool/build_linux.sh`.
- **Video screen stays on "Connect to the board to preview RTSP video"** —
  make sure the connect actually succeeded (status banner/error text below the
  address bar); after success the panel swaps to the video surface.
- **Shows "RTSP is not enabled on this board"** — enable RTSP on the board via
  the Features screen (`debug` preset or the rtsp switch); preview is gated on
  `features.rtsp && worker.stream.rtsp_enabled` by design.
- **ffplay plays but the app does not** — the app mirrors the ffplay command
  (`-rtsp_transport tcp -fflags nobuffer -flags low_delay -framedrop`). If the
  board only accepts UDP: `DART_RTSP_TRANSPORT=udp tool/run_bundle.sh`. Paste
  the video strip error text if it persists.
- **Run against the mock (no board)** — `python3 tool/mock_daemon.py 19000`
  serves the JSON control plane only; there is no RTSP server on 127.0.0.1, so
  preview will not play against it.

Reproduce the mock-based checks (run from the repo root; requires Python 3):

```bash
python3 tool/run_cli_demo.py      # CLI against a fixture-replaying mock daemon
python3 tool/mock_daemon.py 19000 # standalone fixture daemon, or use tool/smoke_test.py
flutter build linux --debug && xvfb-run -a python3 tool/smoke_test.py  # headless GUI smoke test
```
