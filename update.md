# 当前协议迁移状态

旧版 `set_mode`、LAB 识别、feature presets 与 recording 操作已经移除。
客户端当前使用：

- `set_operating_mode {"mode":"ground|flight"}`
- 唯一识别器 `nv21_green`
- `apply_runtime`（仅 Ground 可写）
- UDP VOFA+ FireWater 广播 `:1347`

完整契约见 `AGENTS.md`，不要再按此仓库历史提交中的旧提案开发。
