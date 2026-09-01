/// 中文数字工具：int ↔ 中文数字串。
library;

/// int → 中文数字串（1..99999999；超出范围回退阿拉伯数字）。
/// 供「第 N 卷 / 第 N 章」式编号展示与自动分卷命名复用。
String toChineseNumber(int n) {
  assert(n > 0);
  if (n >= 100000000) return n.toString();
  const d = '零一二三四五六七八九';
  const u = ['', '十', '百', '千'];
  String below10000(int g) {
    final s = g.toString();
    final buf = StringBuffer();
    var prevZero = false;
    for (var i = 0; i < s.length; i++) {
      final digit = s.codeUnitAt(i) - 0x30;
      final pos = s.length - 1 - i;
      if (digit == 0) {
        prevZero = true;
      } else {
        if (prevZero) buf.write('零');
        buf.write(d[digit]);
        buf.write(u[pos]);
        prevZero = false;
      }
    }
    var r = buf.toString();
    // 10-19 省略开头的「一」：一十 → 十。
    if (r.startsWith('一十')) r = '十${r.substring(2)}';
    return r;
  }

  final wan = n ~/ 10000;
  final ge = n % 10000;
  final buf = StringBuffer();
  if (wan > 0) buf.write('${below10000(wan)}万');
  if (ge > 0) {
    // 万级后个级不足千时补零，如 一万零五。
    if (wan > 0 && ge < 1000) buf.write('零');
    buf.write(below10000(ge));
  }
  return buf.toString();
}
