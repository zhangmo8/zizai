# 字在（zi_zai）

本地优先的沉浸式写作工具。所见即所得，打开就写，写完就走，数据在自己手里。

单用户、纯本地存储（SQLite 单库），无账号、无服务端；云备份可选直连 Cloudflare R2。

## 特性

- **所见即所得编辑器**（flutter_quill）：斜杠菜单、Markdown 快捷语法、常驻格式工具栏、标点配对、行首自动缩进
- **专注写作**：焦点暗淡（仅高亮当前段落）、沉浸模式、打字机滚动、写作会话统计
- **自动保存 + 崩溃恢复**：任何时刻退出不丢字；未保存编辑有崩溃缓冲
- **笔记本管理**：书架（网格/列表）→ 单书工作区；分卷分组（自动推导/手动真分组）、章节拖拽排序、状态标记与章节备注
- **字数体系**：中文字符 + 英文连续词计数，按笔记本独立每日目标与今日增量，章节字数分布节奏图
- **全书搜索与替换**：跨章节匹配 + 替换预览
- **版本历史**：单文档本地快照，可预览回滚
- **导入 / 导出**：Markdown（每章一个文件）与纯文本导出；橙瓜码字 `.db` 导入
- **云备份**：全量快照直连 R2（S3 API + SigV4 自签），本地 `.bak` + R2 版本控制双兜底
- **更新检查**：启动自动检查 + 手动检查，sha256 校验后安装
- **本地 MCP 服务**：可选开启 127.0.0.1 MCP 服务，让 AI agent 读写你的书（`skills/zizai-writing`）
- **Notion 风格 UI**：扁平克制、灰阶、4/6/8px 圆角，无 iOS 痕迹（见 [design.md](design.md)）

## 平台

| 平台 | 状态 |
|---|---|
| macOS | ✅ 主平台 |
| Windows | ✅ 构建支持（构建说明见 [docs/plan/build-windows.md](docs/plan/build-windows.md)） |
| Android | ✅ 手机端（Drawer 布局） |

## 开发

```bash
flutter pub get
flutter analyze
flutter test        # 全量测试（core + UI + 集成，见 test/）
flutter run -d macos
```

工程约定、提交规范见 [agent.md](agent.md)；设计规范唯一事实源是 [design.md](design.md)。

## 文档

- [docs/app/README.md](docs/app/README.md) — 产品与架构总览（数据模型、模块划分、ADR）
- [docs/app/ui-*.md](docs/app/) — 各 UI 模块布局与交互
- [docs/app/update.md](docs/app/update.md) — 更新机制与版本体系
- [docs/app/sync.md](docs/app/sync.md) — 云备份设计
- [docs/app/import.md](docs/app/import.md) — 导入（橙瓜码字）
- [docs/plan/](docs/plan/) — 交付计划、任务与评审记录

## License

未指定。
