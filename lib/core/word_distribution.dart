/// 全书章节字数分布（节奏图）纯函数。
///
/// 设计依据：docs/app/ui-sidebar.md §章节字数分布；words 口径与状态栏
/// 一致（documents 表保存快照，见 word_count.dart）。
library;

import 'models.dart';

/// 单章字数行。
class ChapterWords {
  const ChapterWords({
    required this.id,
    required this.title,
    required this.words,
  });

  final String id;
  final String title;
  final int words;
}

/// 一本书的字数分布：目录正序的章节序列 + 汇总（节奏图对话框数据源）。
class BookWordDistribution {
  const BookWordDistribution({
    required this.chapters,
    required this.maxWords,
    required this.totalWords,
  });

  /// 按目录正序（position 升序）排列的全部章节，空书为空列表。
  final List<ChapterWords> chapters;

  /// 最长章节字数（条形长度基准）；0 = 无任何非零章节（不画条形）。
  final int maxWords;

  final int totalWords;

  int get count => chapters.length;

  /// 平均每章字数（四舍五入）；无章节返回 0。
  int get averageWords => count == 0 ? 0 : (totalWords / count).round();
}

/// 从文档列表构建分布。固定按 position 升序——**不受侧边栏「倒序」偏好
/// 影响**：节奏图的意义是从头到尾的走势，永远叙事正序展示。
BookWordDistribution buildWordDistribution(Iterable<Document> docs) {
  final sorted = [...docs]..sort((a, b) => a.position.compareTo(b.position));
  var max = 0;
  var total = 0;
  final chapters = <ChapterWords>[];
  for (final doc in sorted) {
    chapters.add(
      ChapterWords(id: doc.id, title: doc.title, words: doc.words),
    );
    if (doc.words > max) max = doc.words;
    total += doc.words;
  }
  return BookWordDistribution(
    chapters: chapters,
    maxWords: max,
    totalWords: total,
  );
}
