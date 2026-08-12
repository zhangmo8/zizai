# Agent 工作指南（agent.md）

面向在本仓库工作的 AI Agent / 协作者的约定。设计相关的唯一事实来源是根目录 **[design.md](design.md)**。

## 项目概况

- Flutter 桌面/移动应用「字在 zi_zai」，本地优先的写作工具（sqflite + flutter_quill）。
- 入口 `lib/main.dart` / `lib/app.dart`；UI 在 `lib/ui/`，状态在 `lib/state/`，核心逻辑在 `lib/core/`。
- 既有模块文档在 `docs/app/`（README、style、ui-*、update、sync）。注意：`docs/app/style.md` 描述的 Liquid Glass 方向**已废弃**，以根目录 `design.md` 为准；改版落地后同步更新 docs。

## 设计与 UI 硬性约定

1. **禁止新增任何 Cupertino 组件**；存量 Cupertino 按 design.md §1 逐步替换为自绘 Notion 风控件。
2. 颜色、圆角、间距只能取 design.md §2/§3 的 token；圆角仅 4/6/8px 三档。
3. 选择类控件一律用锚定下拉菜单，不用 ActionSheet/底部弹层。
4. icon 优先：chrome 上避免纯文字按钮，icon 必须带 tooltip。
5. 所有可点元素要有 hover/pressed 反馈；异步操作 = 按钮 loading + toast 结果，禁止 inline error text 常驻。
6. 设置入口位于侧边栏底部；格式工具栏**常驻可见**（用户明确要求，不做隐藏式触发）。
7. 更新功能不在 UI 暴露更新地址 URL。

## 工程约定

- 遵循现有代码风格与中文注释习惯；注释只写代码无法表达的约束。
- 改 UI 前先读对应的 `docs/app/ui-*.md`；行为变更后更新对应文档。
- 提交信息用中文 conventional commits（参考 git log，如 `feat(editor): …`、`chore(release): …`）。
- 测试在 `test/`，改动核心逻辑（update/backup/db）需跑 `flutter test`。
- 本地没有完整 Xcode 时，不以 macOS 本机构建作为交付阻塞项；改用 `flutter analyze`、`flutter test`、平台配置静态校验和 GitHub Actions macOS 构建结果确认代码质量。
- 不主动 bump 版本号；发布相关由 `chore(release)` 流程处理。

## 沟通

- 始终使用简体中文。
- 变更前若涉及交互方向的选择，对照 design.md；design.md 未覆盖的再询问用户。
