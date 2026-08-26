/// 「字在写作助手」通用 skill 文本（与 skills/zizai-writing/SKILL.md 同步）。
///
/// 用途：设置页「复制 skill」按钮把这段内容拷到剪贴板，用户粘进自己 agent
/// 的 skills 目录即可获得字在 MCP 工具的使用说明（不绑定单一 agent 生态）。
library;

const String kZizaiWritingSkill = '''
# 字在写作助手（zizai-writer）

通过字在（zi_zai）客户端内置的本地 MCP 服务，读取 / 搜索你的书籍章节，
并协助续写。服务只在你的本机回环地址运行，其他人无法访问。

## 前置条件

1. 在字在客户端「设置 → AI 协作（本地 MCP）」打开开关，记下服务地址
   （默认 `http://127.0.0.1:8765/mcp`，端口可在设置里修改）。
2. 把该地址配置进当前 agent 的 MCP 客户端
   （如 `npx mcp-remote http://127.0.0.1:8765/mcp`，或对应客户端的 MCP 配置）。
3. 连接后先调用 `tools/list` 确认 6 个工具可见。

## 可用工具

| 工具 | 参数 | 说明 |
|---|---|---|
| `list_notebooks` | 无 | 列出所有笔记本（id / 书名 / 章节数 / 总字数） |
| `list_documents` | `notebookId` | 列出一本书的章节（id / 标题 / 字数 / 状态 / 备注） |
| `read_document` | `documentId` | 读一个章节的全文（纯文本）+ 元数据，获取上下文的核心工具 |
| `search_documents` | `query`, `notebookId?` | 关键词搜索章节，返回命中章节与上下文片段 |
| `create_document` | `notebookId`, `title`, `content?` | 新建章节，可带初始正文 |
| `append_document` | `documentId`, `content` | 在章节末尾追加正文（自动留版本快照，不覆盖已有内容） |

## 使用约定（宽松，自行组织流程）

- 动笔前先用 `list_notebooks` / `list_documents` 摸清书的结构，用
  `read_document` 读当前与相关章节拿上下文；需要保持一致性的设定
  （人名 / 时间线 / 伏笔）用 `search_documents` 找回前文。
- 帮写一律用 `append_document` 在章节末尾追加，**不要覆盖已有内容**；
  需要新开篇章时用 `create_document`。
- 正文用纯文本传入，段落用换行分隔；不要伪造不存在的 `documentId`
  （id 一律来自 `list_documents` 的返回值）。
- 写完后可用 `read_document` 复核追加结果；字数在返回的 `words` 字段。
- 工具返回的 JSON 里字段名稳定，出错时 `isError: true` 且内容为可读错误。
''';
