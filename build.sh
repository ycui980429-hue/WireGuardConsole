#!/bin/zsh
# 一键打包 WireGuard 控制台：
#   ./build.sh                编译 + 组装 .app + 安装到 /Applications
#   ./build.sh --no-install   只构建到 app/build/，不安装
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="WireGuard Console"
BUILD_DIR="app/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications/$APP_NAME.app"

echo "▸ 编译原生 App (swiftc + AppKit)"
# 显式列出源文件：不能用 app/*.swift，那会把 make_icon.swift 的顶层表达式一起编进去
SOURCES=(app/main.swift app/WGCore.swift app/PowerButton.swift app/HomeView.swift app/TabsView.swift)
for f in "${SOURCES[@]}"; do
  [ -f "$f" ] || { echo "✗ 缺少源文件: $f"; exit 1; }
done
# 二进制放在本次构建专属的临时目录（不用固定 /tmp 路径，避免并发构建互相踩）
TMP_BIN="$(mktemp -d)/WireGuardConsole"
trap 'rm -rf "$(dirname "$TMP_BIN")"' EXIT
swiftc -O "${SOURCES[@]}" -o "$TMP_BIN"

echo "▸ 组装 $APP"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"
cp "$TMP_BIN" "$APP/Contents/MacOS/WireGuardConsole"

echo "▸ 应用图标"
ICON_SRC="app/$APP_NAME.app/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
else
  swift app/make_icon.swift "$BUILD_DIR/icon_1024.png"
  mkdir -p "$BUILD_DIR/AppIcon.iconset"
  while read -r size name; do
    sips -z "$size" "$size" "$BUILD_DIR/icon_1024.png" \
      --out "$BUILD_DIR/AppIcon.iconset/$name.png" >/dev/null
  done <<'EOF'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
EOF
  iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▸ Ad-hoc 签名"
codesign --force -s - "$APP" >/dev/null

if [ "${1:-}" = "--no-install" ]; then
  echo "✓ 构建完成（未安装）: $APP"
  exit 0
fi

echo "▸ 安装到 /Applications"
osascript -e 'tell application id "local.ycui.wireguard-console" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$INSTALL_DIR"
ditto "$APP" "$INSTALL_DIR"
echo "✓ 已安装: $INSTALL_DIR（可在启动台或应用程序中打开）"
