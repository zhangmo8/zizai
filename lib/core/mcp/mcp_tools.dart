/// 本地 MCP 工具层：把 Db 的读写能力暴露给 AI agent。
///
/// 设计：docs/app/ui-settings.md「AI 协作（本地 MCP）」；skill 侧见
/// skills/zizai-writing/SKILL.md 与 lib/core/mcp/writing_skill.dart。
/// 纯函数、不依赖 mcp_dart 协议类型（便于单测），由 mcp_server.dart 包装成
/// registerTool 回调。写操作约定：只追加/新建，不覆盖已有章节。
library;

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart' show JsonObject, JsonSchema;

import '../db.dart';
import '../export.dart'
    show deltaToPlainText, emptyDeltaJson, parseDeltaOpsLenient;
import '../snapshot_history.dart';

/// 一次工具调用的结果：给 AI 的文本内容 + 是否错误。
class ZizaiMcpResult {
  const ZizaiMcpResult(this.content, {this.isError = false});

  final String content;
  final bool isError;
}

/// 一个 MCP 工具的声明。
class ZizaiMcpTool {
  const ZizaiMcpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  final String name;
  final String description;

  /// 入参 JSON Schema（mcp_dart 的 ToolInputSchema = JsonObject）。
  final JsonObject inputSchema;
  final Future<ZizaiMcpResult> Function(Map<String, Object?> args) handler;
}

/// 组装字在的 6 个 MCP 工具（绑定到某个 Db 实例）。
///
/// [onWrite] 在有写操作成功（建章/追章）后回调，供上层刷新 UI 目录树——
/// MCP 直接写 Db，不刷新的话书架/侧边栏看不到新内容。
List<ZizaiMcpTool> buildZizaiMcpTools(
  Db db, {
  SnapshotHistory? snapshots,
  Future<void> Function()? onWrite,
}) => [
  _listNotebooks(db),
  _listDocuments(db),
  _readDocument(db),
  _searchDocuments(db),
  _createDocument(db, onWrite),
  _appendDocument(db, snapshots, onWrite),
];

/// 纯文本 → Quill Delta JSON。空文本用标准空 delta。
/// （与橙瓜导入的 plainTextToDelta 语义不同：那边要滤空行/剥段首 \t，
/// 这里对 agent 给的文本保真，只收紧右端空白。）
String plainToDelta(String text) {
  final t = text.trimRight();
  if (t.isEmpty) return emptyDeltaJson;
  return jsonEncode([{'insert': t}]);
}

String _json(Object? value) => jsonEncode(value);

ZizaiMcpTool _listNotebooks(Db db) {
  return ZizaiMcpTool(
    name: 'list_notebooks',
    description: '列出所有笔记本（id / 书名 / 章节数 / 总字数），用于选择要写哪本书。',
    inputSchema: JsonSchema.object(properties: const {}),
    handler: (args) async {
      final nbs = await db.listNotebooks();
      final out = <Map<String, Object?>>[];
      for (final nb in nbs) {
        final docs = await db.listDocuments(nb.id);
        out.add({
          'id': nb.id,
          'name': nb.name,
          'documentCount': docs.length,
          'totalWords': docs.fold<int>(0, (sum, d) => sum + d.words),
        });
      }
      return ZizaiMcpResult(_json({'notebooks': out}));
    },
  );
}

ZizaiMcpTool _listDocuments(Db db) {
  return ZizaiMcpTool(
    name: 'list_documents',
    description: '列出某本书的全部章节（id / 标题 / 字数 / 状态 / 备注），按章节顺序。',
    inputSchema: JsonSchema.object(
      properties: {
        'notebookId': JsonSchema.string(
          description: '笔记本 id（来自 list_notebooks）',
        ),
      },
      required: const ['notebookId'],
    ),
    handler: (args) async {
      final notebookId = (args['notebookId'] as String? ?? '').trim();
      if (notebookId.isEmpty) {
        return const ZizaiMcpResult('缺少 notebookId', isError: true);
      }
      final docs = await db.listDocuments(notebookId);
      final out = [
        for (final d in docs)
          {
            'id': d.id,
            'title': d.title,
            'words': d.words,
            'status': d.status.name,
            'notes': d.notes,
          },
      ];
      return ZizaiMcpResult(_json({'documents': out}));
    },
  );
}

ZizaiMcpTool _readDocument(Db db) {
  return ZizaiMcpTool(
    name: 'read_document',
    description: '读取一个章节的全文（纯文本）与元数据，是获取写作上下文的核心工具。',
    inputSchema: JsonSchema.object(
      properties: {
        'documentId': JsonSchema.string(
          description: '章节 id（来自 list_documents）',
        ),
      },
      required: const ['documentId'],
    ),
    handler: (args) async {
      final documentId = (args['documentId'] as String? ?? '').trim();
      if (documentId.isEmpty) {
        return const ZizaiMcpResult('缺少 documentId', isError: true);
      }
      final doc = await db.getDocument(documentId);
      if (doc == null) {
        return ZizaiMcpResult('找不到章节 $documentId', isError: true);
      }
      return ZizaiMcpResult(
        _json({
          'document': {
            'id': doc.id,
            'title': doc.title,
            'words': doc.words,
            'status': doc.status.name,
            'notes': doc.notes,
            'plainText': deltaToPlainText(doc.content),
          },
        }),
      );
    },
  );
}

ZizaiMcpTool _searchDocuments(Db db) {
  return ZizaiMcpTool(
    name: 'search_documents',
    description: '按关键词搜索章节内容（可限定某本书），返回命中章节与上下文片段，'
        '用于找回前文设定/人名/时间线以保持一致。',
    inputSchema: JsonSchema.object(
      properties: {
        'query': JsonSchema.string(description: '搜索关键词'),
        'notebookId': JsonSchema.string(
          description: '可选：只搜索这本书',
        ),
      },
      required: const ['query'],
    ),
    handler: (args) async {
      final query = (args['query'] as String? ?? '').trim();
      final notebookId = (args['notebookId'] as String? ?? '').trim();
      if (query.isEmpty) {
        return const ZizaiMcpResult('缺少 query', isError: true);
      }
      final docs = notebookId.isEmpty
          ? await db.listAllDocuments()
          : await db.listDocuments(notebookId);
      final q = query.toLowerCase();
      final hits = <Map<String, Object?>>[];
      for (final d in docs) {
        final text = deltaToPlainText(d.content);
        final low = text.toLowerCase();
        final idx = low.indexOf(q);
        if (idx < 0) continue;
        final start = (idx - 40).clamp(0, text.length);
        final end = (idx + q.length + 80).clamp(0, text.length);
        hits.add({
          'documentId': d.id,
          'title': d.title,
          'words': d.words,
          'snippet': text.substring(start, end).replaceAll('\n', ' '),
        });
      }
      return ZizaiMcpResult(_json({'query': query, 'hits': hits}));
    },
  );
}

ZizaiMcpTool _createDocument(Db db, Future<void> Function()? onWrite) {
  return ZizaiMcpTool(
    name: 'create_document',
    description: '在某本书里新建一个章节，可选附带初始正文（纯文本，段落用换行分隔）。',
    inputSchema: JsonSchema.object(
      properties: {
        'notebookId': JsonSchema.string(description: '笔记本 id'),
        'title': JsonSchema.string(description: '章节标题'),
        'content': JsonSchema.string(
          description: '可选：初始正文（纯文本）',
        ),
      },
      required: const ['notebookId', 'title'],
    ),
    handler: (args) async {
      final notebookId = (args['notebookId'] as String? ?? '').trim();
      final title = (args['title'] as String? ?? '').trim();
      if (notebookId.isEmpty || title.isEmpty) {
        return const ZizaiMcpResult('缺少 notebookId/title', isError: true);
      }
      final content = plainToDelta((args['content'] as String?) ?? '');
      final doc = await db.createDocument(
        notebookId,
        title: title,
        content: content,
      );
      await onWrite?.call(); // 刷新 UI 目录树
      return ZizaiMcpResult(
        _json({
          'documentId': doc.id,
          'title': doc.title,
          'words': doc.words,
        }),
      );
    },
  );
}

ZizaiMcpTool _appendDocument(
  Db db,
  SnapshotHistory? snapshots,
  Future<void> Function()? onWrite,
) {
  return ZizaiMcpTool(
    name: 'append_document',
    description: '在章节末尾追加正文（纯文本，段落用换行分隔）。只追加、不覆盖已有内容；'
        '追加前自动留版本快照，永不丢字。',
    inputSchema: JsonSchema.object(
      properties: {
        'documentId': JsonSchema.string(description: '章节 id'),
        'content': JsonSchema.string(description: '要追加的正文（纯文本）'),
      },
      required: const ['documentId', 'content'],
    ),
    handler: (args) async {
      final documentId = (args['documentId'] as String? ?? '').trim();
      final text = (args['content'] as String? ?? '').trimRight();
      if (documentId.isEmpty || text.isEmpty) {
        return const ZizaiMcpResult('缺少 documentId/content', isError: true);
      }
      final doc = await db.getDocument(documentId);
      if (doc == null) {
        return ZizaiMcpResult('找不到章节 $documentId', isError: true);
      }
      // 追加前自动留底（复用 snap-001 文档级快照），保证可回滚。
      if (snapshots != null) {
        await snapshots.create(doc);
      }
      // 宽容解析存量正文（坏 JSON 裸文本按纯文本兜底，不丢字）；
      // 结构性坏数据会抛错 → mcp_server 回错误结果，绝不静默清空原章节。
      // 末位补 \n 规范化保证追加内容从新行开始。
      final newDelta = [
        ...parseDeltaOpsLenient(doc.content),
        {'insert': '\n$text\n'},
      ];
      final words = await db.saveDocument(
        id: documentId,
        title: doc.title,
        content: jsonEncode(newDelta),
      );
      await onWrite?.call(); // 刷新 UI 目录树（字数/最新内容）
      return ZizaiMcpResult(
        _json({
          'documentId': documentId,
          'appended': text,
          'words': words,
        }),
      );
    },
  );
}
