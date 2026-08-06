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
