#!/usr/bin/env bash
# 构建 macOS 安装向导包（.pkg）。
#
# 产物：build/installer/zizai-<version>-macos.pkg
# 依赖：macOS 自带 pkgbuild / productbuild（无需额外安装）。
#
# 用法：
#   tool/installer/macos/build_pkg.sh [APP_PATH]
#   APP_PATH 缺省为 build/macos/Build/Products/Release/zi_zai.app
#
# 与 update.md §3 的关系：桌面自更新仍走 zip 解压替换；.pkg 只用于
# **首次安装**——用户下载后双击，进入系统「下一步 → 安装 → 完成」向导，
# 装到 /Applications。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_PATH="${1:-$ROOT/build/macos/Build/Products/Release/zi_zai.app}"
OUT_DIR="$ROOT/build/installer"

BUNDLE_ID="dev.zizai.ziZai"
APP_NAME="字在"

if [[ ! -d "$APP_PATH" ]]; then
  echo "未找到构建产物: $APP_PATH" >&2
  echo "请先执行: flutter build macos --release" >&2
  exit 1
fi

# 版本从 pubspec.yaml 读取（1.4.0+13 → 1.4.0）。
VERSION="$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/pubspec.yaml" | head -1)"
[[ -n "$VERSION" ]] || { echo "无法从 pubspec.yaml 解析版本" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# 1) 组件包：把 .app 装到 /Applications。
COMPONENT_PKG="$OUT_DIR/zi_zai-component.pkg"
pkgbuild \
  --component "$APP_PATH" \
  --install-location /Applications \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --ownership recommended \
  "$COMPONENT_PKG"

# 2) 产品包：套上 Distribution.xml（欢迎/介绍页 + 标准安装向导 UI）。
#    __VERSION__ 占位符按 pubspec 版本替换（pkg-ref 版本需与组件包一致）。
DIST_XML_TMPL="$ROOT/tool/installer/macos/Distribution.xml"
DIST_XML="$OUT_DIR/Distribution.xml"
sed "s/__VERSION__/$VERSION/g" "$DIST_XML_TMPL" > "$DIST_XML"
PKG="$OUT_DIR/zizai-$VERSION-macos.pkg"
productbuild \
  --distribution "$DIST_XML" \
  --package-path "$OUT_DIR" \
  --resources "$ROOT/tool/installer/macos/resources" \
  --version "$VERSION" \
  "$PKG"

# 组件包是中间产物，不保留。
rm -f "$COMPONENT_PKG" "$DIST_XML"

echo "✅ 安装向导包: $PKG"
echo "   (双击后进入系统安装向导，装到 /Applications)"
