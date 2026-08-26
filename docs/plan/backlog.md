# Backlog（非阻塞待办）

| # | 来源 | 内容 | 状态 |
|---|---|---|---|
| 1 | requirements.md F4.3 | 打字机滚动（当前行居中） | 已完成（跟随「暗淡非当前行」联动，无独立开关：focusDim 开启时光标行 120ms 平滑滚动到视口中部，与 flutter_quill showCaretOnScreen 协调） |
| 2 | requirements.md 范围 | 导出整库为 Markdown 文件集 | 已完成（exportBookMarkdownFiles + 导出对话框「Markdown · 每章一个文件」，export_dialog_test 覆盖） |
| 3 | requirements.md F2.4 | 图片粘贴（富文本内嵌图片） | 待处理 |
| 4 | requirements.md 范围 | 全文搜索 | 已完成（全书搜索 + 替换预览） |
| 5 | requirements.md 范围 | 链接、表格等更多富文本格式 | 待处理（链接已随工具栏落地，表格仍缺） |
| 6 | requirements.md F1.5 | 拖拽排序章节 | 已完成（reorderDocument DB + 上移/下移 UI + 拖拽手势：桌面手柄/触摸长按，支持跨笔记本移动） |
| 7 | requirements.md F4.x | 焦点模式（暗淡非当前行） | 已完成（focusDim 蒙层 + 沉浸 FocusView + 设置项 + 打字机联动，2026-08-26 核实） |
| 8 | app/README.md ADR | 多人实时协同（当前单用户架构不支持，需重构状态层） | 待处理 |
| 9 | requirements.md 风险 | 内置中文字体包（改善跨端渲染一致） | 待处理 |
| 10 | sync.md §5 | 云端修订历史浏览/回滚 UI（数据层 R2 版本控制已留） | 待处理 |
| 11 | store-001 评审 | 增量跨日无测试且 saveDocument 时钟不可注入 | 已完成（`Db.open(clock:)` 可注入 + db_test 跨日用例） |
| 12 | store-001 评审 | settings 损坏值回退默认无显式单测 | 已完成（db_test「损坏的 settings 值回退默认」） |
| 13 | store-001 评审 | deltaToPlainText 对非 map op 抛 TypeError 而非承诺的 FormatException | 已完成（parseDeltaOps 校验 op 为 Map；export_test `[42]` 用例） |
| 14 | store-001 评审 | 迁移失败注入测试的 sqflite 预期日志噪音 | 已接受：`print('error $e during open...')` 是 sqflite_common database_mixin 硬编码，无选项可关；行为正确（迁移失败→停止启动），仅测试输出噪音 |
| 15 | shell-001 评审 | token 映射不完整：surface 槽位覆盖为 bg，surface-hover/text-tertiary/success 未显式接线 | 已完成（AppTokens/AppColors 全量接线：surfaceHover/textTertiary/success/callout 均入 ThemeExtension） |
| 16 | side-002 评审 | 选中项底色用 M3 派生色而非 surface-hover token | 已完成（sidebar 用 appColors.rowSelected/surfaceHover） |
| 17 | side-002 评审 | `⋮`/「新建章节」hover 浮现（style.md §9 低打扰 chrome，纯视觉） | 已完成（_HoverReveal opacity 动画，桌面 hover 浮现、触摸端常显） |
| 18 | side-002 评审 | Ctrl/Cmd+B 与笔记本级联删除缺 UI 测试 | 已完成（shell_test Ctrl+B 显隐 + sidebar_test 级联删除，2026-08-21） |
| 19 | edit-003 评审 | 文档冲突：ui-editor.md 把 Ctrl/Cmd+B 列为加粗，ui-shell.md 列为切换侧边栏 | 已裁定：实现 = B 切换侧边栏（全局 handler 消费）；ui-editor.md 已改为「加粗走工具栏」，B 保留给侧边栏 |
| 20 | edit-003 评审 | Windows/Linux 上 flutter_quill 内置 Ctrl+S=codeBlock 会遮蔽全局保存快捷键 | 已完成（shell 全局 HardwareKeyboard handler 先于 flutter_quill 分发并消费） |
| 21 | edit-003 评审 | 上下文工具栏 H1-H3 为文本按钮，与图标按钮视觉密度不齐（纯视觉） | 已完成（textBtn 统一 30×30 与图标按钮一致，2026-08-21） |
| 22 | edit-003 评审 | 编辑器光标色/选中底色未按 style.md 显式配置 | 已完成（TextSelectionThemeData accent 光标/选区 + 桌面 Material 2px 光标） |
| 23 | edit-003 评审 | 沉浸模式退出后焦点未自动回编辑器 | 已完成（EditorView.didUpdateWidget 在退出沉浸时 requestFocus） |
| 24 | edit-003 评审 | 保存失败重试成功后错误条清除的 UI 测试缺失 | 已完成（editor_test 用 SQLite 触发器注入瞬时失败 → 重试成功 → 错误条清除，2026-08-21） |
| 25 | edit-003 评审 | 全量套件偶发 flake（复跑即绿，未定位） | 未复现（settings 落库队列已随 81a1fec 排空；2026-08-21 连续两轮全量 273/273 通过） |
| 26 | edit-003 评审 | Ctrl/Cmd+S 在侧边栏输入框聚焦时也触发保存（全局 handler 范围） | 已完成（全局 handler 对 TextField 子树焦点让位；Quill 编辑器非 TextField 不受影响，2026-08-21） |
| 27 | set-004 评审 | 字体列表为预设候选而非系统字体枚举（Flutter 无跨端枚举 API） | 已确认接受 |
| 28 | set-004 评审 | 对话框圆角/阴影为 M3 默认值（style.md §6 8px 待 M5 打磨） | 已完成（app.dart dialogTheme 8px + hairline 描边；zzConfirm 6px + hairline；surfaceTint 透明） |
| 29 | set-004 评审 | 导出失败路径 / Esc 关闭 / 状态栏点击聚焦入口无专门测试 | 已完成（export_dialog_test 抛异常 → toast 失败；settings_test Esc 关闭 + 状态栏今日进度点击聚焦，2026-08-21） |
| 30 | set-004 评审 | Android Drawer 底部设置入口未实现（ui-settings.md Entry Points） | 已完成（桌面与 Drawer 共用 Sidebar，_SidebarFooter 即底部设置入口） |
| 31 | design.md §6 | 全局圆角审计：只允许 4/6/8 | 已完成（审计仅 2/9 两处，均为开关轨道/进度条的全圆角惯例，符合控件规范） |
| 32 | design.md §6 | 编辑器光标：输入时不闪、停顿后 1s 周期闪烁 | 待处理（宽度/颜色已做；闪烁节奏由 flutter_quill 控制，自定需改其光标动画） |
| 33 | 需求「分卷」 | 分卷 v2：自动/手动分卷 + volumes 表真分组（DB v5 + documents.volume_id；自动 = 纯视觉推导可重命名，手动 = 侧边栏建卷/删卷/重命名 + 章节拖拽与「移动到分卷」+ 未分卷区；自动→手动一次性建卷归章；侧边栏分卷/平铺视图切换 + 笔记本管理视图切换动画与持久化；H1-H3 工具栏反选修复；preview 同步；ui-sidebar/ui-settings/README 更新，2026-08-26） | 已完成 |
| 34 | edit-review | 编辑器 H1/H2/H3 工具条与斜杠菜单无法反选（header 块级独占，flutter_quill 无 paragraph 常量） | 已完成（toggle：已是该级 → clone(header, null) 转回正文；editor.dart `_toggleHeader` 复用，2026-08-26） |
| 35 | 需求「启动/排序」 | 启动总是停在书架（restore 不自动进书，进书才恢复 last_open 章节）；每本书章节排序（正序/倒序，大书倒序看最新）；「+ 新建章节」按钮随序列末尾端移动；新章节标题直接按整本章节数 +1（不再出现「新章节」） | 已完成（docsOrder.<id> 设置 + 设置对话框「目录」组下拉；倒序 = 整章序列反转后再分卷、手动卷反转；按钮正序树底/倒序树顶；2026-08-26） |
