# Backlog（非阻塞待办）

| # | 来源 | 内容 | 状态 |
|---|---|---|---|
| 1 | requirements.md F4.3 | 打字机滚动（当前行居中） | 待处理 |
| 2 | requirements.md 范围 | 导出整库为 Markdown 文件集 | 待处理 |
| 3 | requirements.md F2.4 | 图片粘贴（富文本内嵌图片） | 待处理 |
| 4 | requirements.md 范围 | 全文搜索 | 待处理 |
| 5 | requirements.md 范围 | 链接、表格等更多富文本格式 | 待处理 |
| 6 | requirements.md F1.5 | 拖拽排序章节 | 待处理 |
| 7 | requirements.md F4.x | 焦点模式（暗淡非当前行） | 待处理 |
| 8 | app/README.md ADR | 多人实时协同（当前单用户架构不支持，需重构状态层） | 待处理 |
| 9 | requirements.md 风险 | 内置中文字体包（改善跨端渲染一致） | 待处理 |
| 10 | sync.md §5 | 云端修订历史浏览/回滚 UI（数据层 R2 版本控制已留） | 待处理 |
| 11 | store-001 评审 | 增量跨日无测试且 saveDocument 时钟不可注入（建议可注入时钟 + 跨日用例） | 处理中（随 shell-001 前修复） |
| 12 | store-001 评审 | settings 损坏值回退默认无显式单测 | 处理中 |
| 13 | store-001 评审 | deltaToPlainText 对非 map op 抛 TypeError 而非承诺的 FormatException | 处理中（随 shell-001 前修复） |
| 14 | store-001 评审 | 迁移失败注入测试的 sqflite 预期日志噪音 | 待处理 |
| 15 | shell-001 评审 | token 映射不完整：surface 槽位覆盖为 bg，surface-hover/text-tertiary/success 未显式接线（骨架条与 Ctrl+B 已随 side-002 落地） | 待处理 |
| 16 | side-002 评审 | 选中项底色用 M3 派生色而非 surface-hover token（同 backlog 15，主题接线统一处理） | 待处理 |
| 17 | side-002 评审 | `⋮`/「新建章节」hover 浮现（style.md §9 低打扰 chrome，纯视觉） | 待处理 |
| 18 | side-002 评审 | Ctrl/Cmd+B 与笔记本级联删除缺 UI 测试 | 待处理 |
| 19 | edit-003 评审 | 文档冲突：ui-editor.md 把 Ctrl/Cmd+B 列为加粗（编辑器内置），ui-shell.md 列为切换侧边栏——需文档裁定（当前实现：B=侧边栏，加粗走工具栏） | 待处理 |
| 20 | edit-003 评审 | Windows/Linux 上 flutter_quill 内置 Ctrl+S=codeBlock 会遮蔽全局保存快捷键（macOS Cmd+S 不受影响；自动保存兜底） | 待处理 |
| 21 | edit-003 评审 | 上下文工具栏 H1-H3 为文本按钮，与图标按钮视觉密度不齐（纯视觉） | 待处理 |
| 22 | edit-003 评审 | 编辑器光标色/选中底色未按 style.md 显式配置（flutter_quill 默认值） | 待处理 |
| 23 | edit-003 评审 | 沉浸模式退出后焦点未自动回编辑器 | 待处理 |
| 24 | edit-003 评审 | 保存失败重试成功后错误条清除的 UI 测试缺失 | 待处理 |
| 25 | edit-003 评审 | 全量套件偶发 flake（复跑即绿，未定位） | 待处理 |
| 26 | edit-003 评审 | Ctrl/Cmd+S 在侧边栏输入框聚焦时也触发保存（全局 handler 范围） | 待处理 |
| 27 | set-004 评审 | 字体列表为预设候选而非系统字体枚举（Flutter 无跨端枚举 API，已确认接受） | 待处理 |
| 28 | set-004 评审 | 对话框圆角/阴影为 M3 默认值（style.md §6 8px 待 M5 打磨） | 待处理 |
| 29 | set-004 评审 | 导出失败路径 / Esc 关闭 / 状态栏点击聚焦入口无专门测试 | 待处理 |
| 30 | set-004 评审 | Android Drawer 底部设置入口未实现（ui-settings.md Entry Points） | 待处理 |
| 31 | sync-worker-001 评审 | 无自定义域名 route（仅 workers_dev，自用可接受） | 待处理 |
| 32 | sync-worker-001 评审 | pull 对损坏对象静默跳过无可观测计数 | 待处理 |
| 33 | sync-worker-001 评审 | 测试缺口：notebooks/settings/stats 键布局、非数字协议头未覆盖 | 待处理 |
