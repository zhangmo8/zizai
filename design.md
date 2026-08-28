# 设计规范 — Notion 风格改版

Status: Active（2026-08，替代 `docs/app/style.md` 的 Liquid Glass 方向）

## 0. 背景与目标

当前实现 iOS（Cupertino / Liquid Glass）痕迹过重：CupertinoPicker/ActionSheet、
CupertinoSwitch/Slider/Dialog、毛玻璃层次、系统蓝 accent。目标是全面向 **Notion**
的桌面产品质感靠拢：扁平、克制、灰阶为主、小圆角、icon 优先、交互反馈轻量即时。

**一句话原则：像一份安静的文档工具，而不是一台 iPhone。**

## 1. 需要移除的 iOS 痕迹（负面清单）

- ❌ `CupertinoActionSheet` / `showCupertinoModalPopup` 式选择器（settings_view.dart 的 `_IosPicker` 类组件）——改为 Notion 式**下拉菜单**（锚定在触发按钮下方的浮层菜单，条目 hover 高亮、当前项打勾）。
- ❌ `CupertinoAlertDialog` / `CupertinoDialogAction` —— 改为自绘轻量确认弹层（小卡片、8px 圆角、右下角文字按钮，危险操作红色）。
- ❌ `CupertinoSwitch` / `CupertinoSlider` / `CupertinoTextField` / `CupertinoButton` —— 改为自绘 Notion 风控件（见 §4）。
- ❌ 毛玻璃 `BackdropFilter`（glass.dart）—— 改为实色表面 + hairline 分割。
- ❌ 系统蓝 `#007AFF` 作为全局 accent —— 改为 Notion 蓝（见 §2），且用得更少。
- ❌ 圆角不统一（有大有小、部分控件圆角与容器不匹配）—— 全局收敛到 §3 的圆角 token，**任何控件不得自定圆角值**。

## 2. 色彩 Token（Notion 灰阶）

### Light
| Token | 值 | 用途 |
|---|---|---|
| `bg` | `#FFFFFF` | 主内容区 |
| `bg-sidebar` | `#F7F7F5` | 侧边栏 |
| `bg-hover` | `rgba(0,0,0,0.04)` | hover |
| `bg-active` | `rgba(0,0,0,0.06)` | 选中/按下 |
| `text-primary` | `#37352F` | 正文（Notion 暖黑） |
| `text-secondary` | `rgba(55,53,47,0.65)` | 次要 |
| `text-tertiary` | `rgba(55,53,47,0.45)` | 占位/图标默认 |
| `divider` | `rgba(55,53,47,0.09)` | hairline |
| `accent` | `#2383E2` | 链接、焦点、主按钮（Notion 蓝） |
| `danger` | `#EB5757` | 危险操作 |

### Dark
| Token | 值 |
|---|---|
| `bg` | `#191919` |
| `bg-sidebar` | `#202020` |
| `bg-hover` | `rgba(255,255,255,0.055)` |
| `text-primary` | `rgba(255,255,255,0.87)` |
| `divider` | `rgba(255,255,255,0.094)` |
| `accent` | `#529CCA` |

## 3. 圆角 / 间距 / 字体

- 圆角只允许三档：**4px**（按钮、输入框、菜单条目、tag）、**6px**（浮层菜单、卡片、弹窗）、**8px**（大面板、图片）。禁止其它值，禁止胶囊圆角（除 toast）。
- 间距 4px 网格：4 / 8 / 12 / 16 / 24。
- 字号：正文 15 / 次要 13 / 说明 12；UI chrome 13-14。
- 阴影仅浮层可用：`0 4px 12px rgba(0,0,0,0.1)` + 1px divider 描边，无其它阴影。

## 4. 控件规范（替代 Cupertino）

| 控件 | Notion 式做法 |
|---|---|
| Select/Picker | 触发器 = 文字 + 小 chevron-down（tertiary 色），点击弹**锚定下拉菜单**（6px 圆角浮层，条目 32px 高、4px 圆角 hover，当前项右侧 ✓）。禁止底部弹出 ActionSheet |
| Switch | 小型自绘 toggle（约 30×18，off 灰 on accent，120ms 位移动画） |
| Slider | 细轨道 4px + 12px 圆点，accent 填充 |
| Button（主） | accent 底白字，4px 圆角，28-32px 高 |
| Button（次） | 透明底 + hover `bg-hover`，文字 primary |
| 输入框 | `bg-hover` 底色、无边框，focus 时 accent 1px 内描边 |
| Dialog | 居中小卡片 6px 圆角，标题 14 semibold，按钮为右对齐文字按钮 |
| Toast | 底部居中浮出，深底白字胶囊或 6px 卡片，2.5s 自动消失，用于操作结果反馈 |
| Tooltip | 深底白字小浮层，hover 500ms 出现——**icon 按钮必须配 tooltip** |

## 5. 结构与页面要求

### 5.0 两层结构：笔记本管理层 + 单书工作区
- **笔记本管理层（LibraryHome）= 应用入口**：网格/列表展示全部笔记本（卡片无封面，显示书名 + 章节数 + 总字数），右上角 grid/list 视图切换 + 新建笔记本 + 全局设置。
- 点书 → 单书工作区（Shell）；返回（侧边栏顶栏 ←）回管理层。进入/退出由 `currentNotebook` 声明式驱动，不做 Navigator 栈。
- 启动时若存在 `last_open` 记录，恢复上次的书（resume 进工作区）。

### 5.1 侧边栏（单书）
- 底色 `bg-sidebar`，条目 28px 高、4px 圆角 hover。
- 顶栏：返回 + 书名 + 全书搜索 + **本书设置**（icon + tooltip）。
- 章节树支持**分卷视觉分组**（书内设置开启后按每卷章数插入「第 N 卷」标题，不动库）。
- **设置入口固定在侧边栏底部**：一行「⚙ 设置」条目（icon + 文字，全局设置），与列表主体之间用 hairline 或留白分隔；hover 有背景反馈，点击有按下态。不再从编辑器内入口为主。
- 底部区域可同时容纳同步/字数等状态，但保持一行、安静。

### 5.2 设置页
- 布局参考 Notion Settings：左侧分类列表 + 右侧内容（当前的分类结构保留），但视觉全部按 §2-§4 重做。
- 分组标题 12px tertiary 大写/加粗，行高统一- **软件更新**：
  - **不暴露更新地址**：移除「更新地址」输入框（URL 作为内部默认配置/隐藏在高级入口，普通界面不展示）。
  - **自动检查**：启动后异步检查一次，无需手动触发；发现新版自动 toast 提示「发现新版本 vX.Y.Z」，管理页设置图标亮 accent 角标（`UpdateChecker.status` 驱动）。
  - 另保留「检查更新」按钮；点击后按钮内出现 loading 态（spinner 替换文字）。
  - 结果用 **toast** 反馈：「已是最新版本」/「发现新版本 vX.Y.Z」/「检查失败，请稍后重试」。**移除按钮下方的 inline error text**。
  - 下载进度显示在按钮内或旁边一条细进度条，完成后按钮变「安装 vX.Y.Z」。

### 5.3 编辑器
- **光标**：宽 2px、accent 色（或 primary 文字色）、圆角 1px，高度与行高匹配；输入时不闪、停顿后 1s 周期闪烁（Notion/现代编辑器手感）。修正目前光标观感不对的问题（editor.dart `cursorColor` 一带）。
- **icon 优先**：chrome 上的纯文字按钮/标签尽量换成 icon + tooltip（如工具栏动作、行操作、状态栏入口），减少页面文字密度。正文区域除外。
- 图标统一线性风格（Material Symbols outlined 或 Lucide 风），tertiary 色，hover 变 primary。

### 5.4 交互反馈通则
- 所有可点元素必须有 hover / pressed 两态背景反馈。
- 动效 100-150ms ease-out，无弹跳。
- 异步操作：进行中 → 按钮 loading 态；结束 → toast；禁止无反馈的点击。

## 6. 迁移检查清单

- [x] app.dart：新 ThemeData token（§2/§3），删除 CupertinoTheme 依赖（AppTokens + AppColors ThemeExtension，useMaterial3 关）
- [x] glass.dart：废弃毛玻璃，改实色表面组件（GlassSurface 保留名称，实现已切换 flat surface）
- [x] settings_view.dart：全部 Cupertino 控件替换；更新区按 §5.2 重做；加 toast（检查更新 loading 态 + toast 结果，无更新地址暴露）
- [x] sidebar.dart：底部设置入口（§5.1，_SidebarFooter 桌面与 Android Drawer 共用）
- [x] editor.dart：光标参数（§5.3，accent 2px Material 光标）；文字按钮 → icon+tooltip（H1–H3 保留文本按钮为 Notion 惯例，统一 30×30 密度）
- [x] 全局圆角审计：只允许 4/6/8（审计通过；开关轨道 9px、进度条 2px 为全圆角惯例）
- [x] 编辑器光标闪烁节奏——2026-08-27 裁定不做（现实现已足够），backlog 同步剔除
