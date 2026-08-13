# Task integ-005 — 端到端集成

```yaml
id: integ-005
scope: 全项目
status: pending
depends-on: [edit-003, set-004, sync-ui-003, upd-001]
```

## Objective

打通真实调用链（非 mock），验证用户可观察流程：

1. 写→存→重启→恢复：新建文档写入 300 字，重启 App 内容仍在，今日增量 = 300。
2. 侧边栏切换文档时旧文档已保存。
3. 设置持久化：改主题/目标字数后重启仍生效。
4. **双设备备份**：设备 A 上传备份 → 设备 B 下载恢复后内容一致；恢复前本地 `.bak` 生成，可找回恢复前数据。
5. **更新流程**：测试 R2 bucket 返回新清单 → 校验 sha256 → 安装路径触发（Android 模拟器 / 桌面 zip 替换）。
6. 三平台冒烟：macOS 桌面运行（主开发机）、Android 模拟器/真机、Windows 构建说明（无 Windows 机器则记录阻塞项到 backlog）。

## Context

- docs/plan/analysis/modules.md（§3 集成枚举）
- docs/app/sync.md（§8 测试）
- docs/app/update.md（§5 测试）
- docs/plan/analysis/requirements.md（S1–S9、NFR）

## Path

- `integration_test/*.dart`（如启用）
- 冒烟清单记录于 `docs/plan/reviews/integ-005-1.md`

## Verification

- 集成测试覆盖写→存→重启恢复链路与双设备同步链路。
- 三平台冒烟结果记录；阻塞项写 backlog。
