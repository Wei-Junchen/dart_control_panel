# 动态配置 Controls

Ground Test 的 Controls 不再使用静态 TuningForm/RuntimeDraft，已移除这两份旧实现与过时映射。

- 板端 `get_schema.config_schema`（`x-contract-version=1`）描述分组、字段、类型、范围、
  枚举、说明、单位及显示条件；没有或无法理解该描述时仅提供 JSON 编辑。
- `ConfigDocumentDraft` 保存唯一的完整配置草稿和基线。JSON 与 Controls 双向同步，
  未完成的文本不会被轮询或视图切换重置。切换设备时清除旧设备草稿，避免混用。
- `ConfigControls` 只实现通用类型控件，不含 detector/ISP/UART 的静态字段列表。
- 全部修改均有 `x-runtime-key` 且可无损传递时，可实时应用；否则上传完整配置，
  明确确认可能重启 worker。复杂 ROI 不做猜测式实时转换。
- Flight 模式锁定 Controls 与上传；JSON 可以保留本地草稿。上传失败不清空草稿。
- 点击左侧画面快捷操作前，需要先处理未上传草稿，避免快捷操作与完整 JSON 相互覆盖。
- 本地校验是提示；硬件组合、ROI、手动曝光/增益等跨字段约束仍由板端权威校验。

客户端离线夹具来自真实 daemon。完整端到端测试见视觉仓库
`tests/integration/run_config_controls_client_test.py`，不需连接或重启真实板子。
