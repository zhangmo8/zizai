# 交付计划

## 循环

```text
pending ── 依赖完成 ──► ready ──► in-progress ──► done
                                        │
                                     blocked ──► 修复 ──► re-verify
```

1. 设计文档先行：任务开始前，`context` 指向的设计文档必须存在。
2. develop agent 只做任务文件 `objective` 定义的事，完成后运行 `flutter analyze` 与任务要求的测试。
3. verify agent 对照设计文档评审，写 `docs/plan/reviews/{id}-{seq}.md`。
   - blocking = 与设计文档 contract 不一致，或残留 stub/mock。
   - pass → merge 到 main → 全量测试 → 任务 `done`。
   - blocked → 同分支修复 → 重新评审。
4. 非阻塞发现追加到 [backlog.md](backlog.md)。

## 里程碑

| 里程碑 | 内容 | 出口标准 |
|---|---|---|
| M1 骨架 | 环境 + 脚手架 | `flutter create` 三平台目录存在，`flutter test` 通过 |
| M2 核心写流 | 存储层（含迁移链）+ 编辑器 + 自动保存 + 字数 | 新建文档→写→重启后内容仍在，字数正确 |
| M3 管理与沉浸 | 文档树、设置页、沉浸模式 | 章节增删改查 + 全屏写作闭环 |
| M4 云备份与更新 | R2 直连备份引擎 + 设置备份区 + 更新检查 | 双设备备份/恢复闭环；更新清单可安装 |
| M5 打磨打包 | 主题/字体打磨、三平台构建、上传 R2 | macOS 出 .app，Android 出 APK，Windows 构建说明 |
| M6 写作增强 | 本地版本快照、Markdown 导入、单文档大纲面板 | 快照可回滚不丢字；.md 可导入成文档；大纲可跳转 |

## 任务

见 [tasks/](tasks/)。当前状态以任务文件 `status` 字段为准。
