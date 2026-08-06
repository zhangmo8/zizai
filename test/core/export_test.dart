import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/export.dart';
import 'package:zi_zai/core/models.dart';

void main() {
  group('deltaToPlainText', () {
    test('空文档占位返回空串', () {
      expect(deltaToPlainText(''), '');
      expect(deltaToPlainText('{}'), '');
    });

    test('简单插入', () {
      expect(deltaToPlainText('[{"insert":"你好世界"}]'), '你好世界');
    });

    test('带格式属性', () {
      expect(
        deltaToPlainText('[{"insert":"加粗"},{"insert":"普通","attributes":{"bold":true}}]'),
        '加粗普通',
      );
    });

    test('换行', () {
      expect(deltaToPlainText('[{"insert":"第一行\\n第二行"}]'), '第一行\n第二行');
    });

    test('非法结构抛 FormatException', () {
      expect(() => deltaToPlainText('{"a":1}'), throwsFormatException);
      expect(() => deltaToPlainText('不是json'), throwsFormatException);
    });
  });

  group('exportPlainText', () {
    test('文档导出纯文本', () {
      const doc = Document(
        id: 'd1',
        notebookId: 'n1',
        title: 't',
        content: '[{"insert":"导出的内容"}]',
        words: 5,
        position: 0,
        createdAt: 0,
        updatedAt: 0,
      );
      expect(exportPlainText(doc), '导出的内容');
    });
  });
}
