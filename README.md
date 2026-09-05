<p align="center">
  <img src="assets/logo.png" width="88" alt="字在" />
</p>

<h1 align="center">字在</h1>

<p align="center"><strong>安静的写作工具。</strong></p>

<p align="center">
  打开就写，所见即所得；写完就走，数据在自己手里。<br />
  macOS · Windows · Android
</p>

---

## 为什么是字在

写作软件本该简单：打开就是空白页，光标在等你。

可市面上的工具却越来越吵——账号、云同步、会员、社交、激励、花哨的主题。它们在你动笔之前，先跟你谈条件。

字在把这些全部拿走。它是一款**本地优先的沉浸式写作工具**，为长文而作：小说、连载、任何需要专注的长内容。没有账号、没有服务端、没有订阅；你的文字只存在于你的设备上，卸载也不会带走一句。

「字在」——字在笔下，人在自在。

## 设计主张

- **打开就写。** 所见即所得，没有模式切换，没有配置向导。新建一本书，光标已经在第一行等你。
- **写得进去。** 焦点暗淡只高亮当前段落，沉浸模式、打字机滚动——屏幕上只剩你和文字。
- **写得下去。** 每次按键都在自动保存，任何时刻退出都不丢字；每本书有独立的每日目标，字数节奏图让你看见自己一天天靠近终点。
- **长文有结构。** 书架、单书工作区、分卷分组、章节拖拽排序、状态标记与备注——结构服务于长篇，而不是反过来。

## 顺手之处

- **编辑器**：斜杠菜单、Markdown 快捷语法、标点配对、行首自动缩进
- **字数体系**：中文字符 + 英文连续词计数，按笔记本独立目标与今日增量
- **全书搜索与替换**：跨章节匹配，替换前先预览
- **版本历史**：本地快照，随时回滚到任意时刻
- **导入 / 导出**：Markdown 与纯文本导出；橙瓜码字 `.db` 直接导入，迁移零成本
- **云备份（可选）**：全量快照直连 Cloudflare R2，本地 `.bak` + R2 版本控制双兜底
- **本地 MCP 服务（可选）**：开启后 AI agent 可以读写你的书（[`skills/zizai-writing`](skills/)）

界面遵循 Notion 式设计语言：扁平克制、灰阶、4/6/8px 圆角，无 iOS 痕迹（见 [design.md](design.md)）。

## 平台

| 平台 | 状态 |
| --- | --- |
| macOS | ✅ 主平台 |
| Windows | ✅ 构建支持（[构建说明](docs/plan/build-windows.md)） |
| Android | ✅ 手机端（Drawer 布局） |

## 开发

```bash
flutter pub get
flutter analyze
flutter test        # 全量测试（core + UI + 集成，见 test/）
flutter run -d macos
```

工程约定与提交规范见 [agent.md](agent.md)；设计规范唯一事实源是 [design.md](design.md)。

## 文档

- [docs/app/README.md](docs/app/README.md) — 产品与架构总览（数据模型、模块划分、ADR）
- [docs/app/](docs/app/) — UI 模块布局、更新机制、云备份、橙瓜导入设计
- [docs/plan/](docs/plan/) — 交付计划与任务记录

## License

未指定。
