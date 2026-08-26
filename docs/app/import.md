# 导入（第三方编辑器产物）

Status: Draft（v1：橙瓜码字）

## 1. 目标

把其他写作软件的产物导入字在，映射到现有数据模型，**不动现有数据**（追加合并）：

| 外部概念 | 字在落点 |
|---|---|
| 图书 | 笔记本（`notebooks`） |
| 卷 | 分卷（`volumes`，手动分卷真数据） |
| 章节 | 文档（`documents`，内容为 Delta JSON） |

## 2. 橙瓜码字（已实现）

橙瓜码字是 Electron + SQLite 应用，数据在用户数据目录的 `<uid>.db`：

- macOS：`~/Library/Application Support/橙瓜码字/<uid>.db`
- Windows：`%APPDATA%\橙瓜码字\<uid>.db`

### 表结构（实测）

| 表 | 关键列 | 说明 |
|---|---|---|
| `book_category` | `type`（1 图书 / 2 卷 / 3 章节）、`parent_client_uuid`、`title`、`sorts`（JSON 排序数组）、`is_deleted` | 目录树；`sorts` 决定子节点顺序，橙瓜偶发重复 uuid，导入去重；缺失按 `created_at` 兜底 |
| `chapter_content` | `chapter_uuid`、`volume_uuid`、`category_id`（图书）、`content`（纯文本）、`created_at/updated_at`、`is_deleted` | 正文；段落以 `\t` 开头、段间空行分隔 |

### 实现（`lib/core/import_chenggua.dart`）

- 只读打开：先把源库**复制到临时目录**再 `openDatabase(readOnly: true)`（桌面在独立
  isolate 解析，Android 主 isolate）。
- 过滤 `is_deleted`；孤儿卷跳过；指向已删卷的章节归为未归卷。
- 内容转换：纯文本 → 每行一段（去行首 `\t`）→ 单个 Delta op；字数用字在 `wordCount`
  对纯文本重算（与字在统计口径一致）。
- 批量入库：`Db.importExternal` 单事务追加插入，**不动 stats**（外部导入不是今日新增）、
  不触发 onMutation；新笔记本 position 追加在现有库末尾。
- UI 入口：设置 → 数据 → 导入 → 从橙瓜码字导入（选择 `<uid>.db`），完成后刷新书架。

### 测试

`test/core/import_chenggua_test.dart`：合成橙瓜库（含 `sorts` 重复、已删除行）映射
验证；追加合并 position 不冲突；缺失文件抛可读异常。真实库冒烟（`103564487.db`）验证过。

## 3. 扩展其他格式

新增格式遵循同一路径：解析器产出
`{notebooks, volumes, docs}` 三组条目 → `Db.importExternal` 批量入库。
富文本（docx 等）需先映射为 Delta attributes；纯文本类（txt/md）按章节标题切分。
