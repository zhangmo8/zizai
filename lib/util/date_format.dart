/// 日期/时间展示格式化：全应用唯一的口径来源。
///
/// 此前「yyyy-MM-dd」在 db 统计键、备份文件名等处各写一份，且备份
/// 文件名误用 UTC 口径（toIso8601String），跨零点会与本地统计键差一天；
/// 统一收敛到本文件，一律取本地时区。
library;

/// 本地时区 yyyy-MM-dd。既用于逐日统计键（db 今日增量），也用于
/// 备份文件名日期戳，两处口径必须一致。
String localDateKey(DateTime t) {
  final mm = t.month.toString().padLeft(2, '0');
  final dd = t.day.toString().padLeft(2, '0');
  return '${t.year}-$mm-$dd';
}

/// 快照时间展示：今天 / 同年「M 月 D 日」/ 跨年 yyyy-MM-dd，均附 HH:mm。
String formatSnapshotTime(DateTime time) {
  final t = time.toLocal();
  final now = DateTime.now();
  final sameDay =
      t.year == now.year && t.month == now.month && t.day == now.day;
  final hm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (sameDay) return '今天 $hm';
  if (t.year == now.year) return '${t.month} 月 ${t.day} 日 $hm';
  return '${localDateKey(t)} $hm';
}

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前。
String relativeTime(DateTime at) {
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  return '${diff.inDays} 天前';
}
