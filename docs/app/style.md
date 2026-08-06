# 视觉风格规范 — macOS 26 / iOS 26（Liquid Glass）

Status: Draft（2026-08 改版：从「极简留白 + Notion」迁移到 Apple Liquid Glass）

## 1. 风格定位

**气质关键词**：安静 · 克制 · 通透 · 玻璃 · 系统原生感

**参考对象：macOS 26 Tahoe / iOS 26** —— 冷调中性色、半透明毛玻璃、细 hairline、
无 Material 3 组件语言。界面让位内容，chrome 用玻璃层次退到背景。

- 界面是「玻璃桌面」，不是「舞台」：面板/状态条/工具栏都是半透明玻璃，透出窗口底色。
- 唯一强调色 = 系统蓝（`#007AFF` / 深色 `#0A84FF`），只用于状态与焦点。
- 无渐变装饰（仅窗口底极淡纵向过渡）、无重阴影、无拟物、无 Ink 水波纹。

## 2. 设计原则

| 原则 | 落地 |
|---|---|
| 玻璃分层 | 面板用 `BackdropFilter` 模糊 + 半透明填充（light 白 68%、dark 黑 55%） |
| 控件系统 | Cupertino 控件（Switch/Slider/TextField/Button/Dialog/ActionSheet），不用 M3 |
| 冷调中性色 | Apple system colors（`#F5F5F7` 底、`#1D1D1F` 文字） |
| 单点强调 | 系统蓝 accent，只出现在状态与焦点 |
| 细线结构 | 0.5–1px hairline（黑 10% / 白 12%），无深色描边 |
| 无声动效 | 150–200ms 淡入淡出，无弹跳缩放 |
| 低打扰 chrome | 工具栏/行操作平时隐藏，选中或悬停才浮现 |
| 所见即所得 | 编辑器样式即排版效果（不变） |

## 3. 色彩系统（Design Tokens）

### 浅色（Light）

| Token | 值 | 用途 |
|---|---|---|
| `bg` | `#F5F5F7` | 窗口底色（Apple 冷灰白） |
| `surface` | `#FFFFFF` | 玻璃填充基色（配合 68% 不透明度 + 模糊） |
| `surface-hover` | 黑 8% | hover/选中底 |
| `text-primary` | `#1D1D1F` | 正文（Apple 近黑） |
| `text-secondary` | `#6E6E73` | 次要信息 |
| `text-tertiary` | `#86868B` | 占位、禁用 |
| `hairline` | 黑 10% | 1px 分隔线、边框 |
| `accent` | `#007AFF` | 系统蓝（唯一强调色） |
| `success` | `#34C759` | 已保存提示 |
| `danger` | `#FF3B30` | 删除、失败提示 |

### 深色（Dark）

| Token | 值 | 用途 |
|---|---|---|
| `bg` | `#000000`（窗口顶 `#1C1C1E` 微渐变） | 窗口底色 |
| `surface` | `#FFFFFF`（玻璃填充黑 55%） | 面板 |
| `surface-hover` | 白 12% | hover/选中底 |
| `text-primary` | `#F5F5F7` | 正文 |
| `text-secondary` | `#A1A1A6` | 次要信息 |
| `text-tertiary` | `#6E6E73` | 占位 |
| `hairline` | 白 12% | 分隔线 |
| `accent` | `#0A84FF` | 系统蓝提亮 |
| `success` | `#30D158` | 成功 |
| `danger` | `#FF453A` | 错误 |

规则：主题三态（跟随系统/浅色/深色）；token 单源在 `AppTokens`，经
`ThemeData` + `AppColors`(ThemeExtension) 下发；Cupertino 控件由
`AppTheme.cupertino()` 提供同源主题。

## 4. 字体系统

| 场景 | 字体 | 说明 |
|---|---|---|
| UI 界面 | 系统无衬线（macOS SF Pro / Windows Segoe UI / Android Roboto） | 12/13/14/16 四档，行高 1.4 |
| 编辑器正文 | **等宽族**：Latin/数字 用系统等宽（macOS Menlo / Windows Consolas / Android Droid Sans Mono）；CJK 回退系统字体（中文天然全角，天然对齐） | 默认字号 18，行距 1.8（设置可调 12–28 / 1.2–2.4） |
| 编辑器标题 H1–H3 | 同编辑器字体，加粗 + 字号阶梯（24/20/18），颜色 text-primary | 所见即所得，不用装饰性字体 |

等宽说明：等宽感主要由 Latin/数字/标点对齐提供；CJK 回退系统默认不破坏对齐（全角字符等宽是字体规格）。不内置字体包（V1）。

## 5. 间距与布局

- 网格：4pt 基准（4/8/12/16/24/32/48）。
- 侧边栏 240px；内容区最大行宽 720px 居中；状态栏高 32px；顶栏高 44px。
- 编辑器内容上下 padding 96px；段落间距由行距承担，不加额外段距装饰。
- 对话框宽 480px，内边距 24px。

## 6. 形状与阴影

| Token | 值 |
|---|---|
| 圆角 | 玻璃面板/浮层 10px；侧边栏/状态条 0px（直角）；输入框 6px；列表选中 6px |
| 阴影 | 一律无阴影（玻璃层级取代 elevation） |
| 边框 | 0.5–1px hairline（浅色黑 10% / 深色白 12%） |

## 7. 动效

| 动作 | 时长/曲线 | 说明 |
|---|---|---|
| hover/点击反馈 | 80–120ms ease-out | 底色淡入（无 Ink 水波纹） |
| 上下文工具栏/浮层出现 | 100ms ease-out | 从选中点淡入上浮 |
| 抽屉/对话框出入 | 200ms ease-out | 位移动画 |
| 状态栏提示（已保存） | 淡入 150ms，停留 1s，淡出 300ms | 只动透明度 |
| 沉浸模式进出 | 200ms ease-out | 内容区放大 + chrome 淡出 |

禁：弹性、回弹、缩放强调、粒子、过渡时长 > 300ms 的装饰动效。chrome 隐藏项只许淡出，不许位移花活。

## 8. 图标与图形

- 线性图标，笔画 1.5px，16/20/24 三档。
- 默认 `text-tertiary`，hover `text-secondary`，激活/选中 `accent`。
- 工具栏图标 20px；侧边栏 16px；顶栏 20px。
- 空态插图：无插图，一行文字 + 一个线性图标（克制）。

## 9. 组件样式要点

| 组件 | 样式 |
|---|---|
| 玻璃面板 | `GlassSurface`：BackdropFilter 模糊 + 半透明填充 + hairline 描边 + 顶部微高光 |
| 侧边栏 | 整栏玻璃（右缘 0.5px hairline）；选中项 = 圆角 6px 灰底 + 主色加粗文字（无左侧竖条） |
| 侧边栏行操作 | 平时隐藏，hover 行时浮现 `⋮`/`+`（低打扰 chrome） |
| 上下文工具栏 | 选中文本时浮现：玻璃圆角 10px（Notion 式浮动工具栏） |
| 工具栏按钮 | 无边框图标钮；激活态系统蓝；hover 灰底圆角 6px |
| 状态栏 | 玻璃条（顶缘 0.5px hairline）；文字 12px secondary；进度条 2px 高、accent、直角 |
| 编辑器 | 与窗口同底色（无卡片感）；光标 1.5px accent；选中文本 accent 15% 透明 |
| 空态引导 | text-tertiary 一句话（「新建一本笔记本，开始写」），无插图 |
| 控件 | CupertinoSwitch / CupertinoSlider / CupertinoTextField / CupertinoButton / CupertinoDialog / CupertinoActionSheet |
| 选择器 | 主题/字体：显示当前值 + `›`，点按弹 CupertinoActionSheet |
| 删除确认条 | 编辑器顶部通条，danger 文字 + 「确认/取消」文字按钮，5s 自动关 |
| 错误提示 | text danger + 重试按钮，无弹窗（不阻断写作） |

### 借鉴与不学

| 借鉴 | 不学 |
|---|---|
| Apple 系统控件与玻璃层级 | Material 3 组件语言（FilledButton/Switch/Slider/Ink 水波纹） |
| 侧边栏圆角灰底选中 | 强调色可随意切换（我们锁定系统蓝） |
| 冷调中性色与 hairline 结构 | 高饱和纯色出现在功能色之外 |

## 10. 深色模式

- 深色：纯黑底（窗口顶 `#1C1C1E` 微渐变），玻璃用黑 55% 填充；accent 提亮一档保证对比。
- 编辑区深色：文字 `#F5F5F7`，选中底色 accent 20% 透明，光标 accent。
- 跟随系统时，系统切换主题即时生效，无过渡动画（或 150ms 淡入，桌面端）。

## 11. 反模式清单（不做）

- ❌ Material 3 组件（M3 Switch/Slider/FilledButton/Dropdown 外观、Ink 水波纹）
- ❌ 重阴影卡片、彩色强调多于一种（锁定系统蓝）
- ❌ 装饰性启动页、品牌大 Logo
- ❌ 圆角大卡片式排版（编辑器不套卡片）
- ❌ 动效炫技（弹性、位移动画满屏）
- ❌ 表情符号当图标
- ❌ 暖色纸感底色（旧版「极简留白」色板已废弃）

## 12. 落地映射

- Flutter：`app.dart`（`AppTokens` + `AppTheme` + `AppColors` ThemeExtension）、
  `ui/glass.dart`（`GlassSurface` 玻璃面板），shell-001 接线。
- 编辑器字体族：`settings.fontFamily` 缺省 = 等宽栈（平台分支见 §4）。
- 本规范所有 token 单源在 style.md，代码里不允许硬编码颜色。
