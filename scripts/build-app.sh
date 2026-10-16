#!/usr/bin/env bash
# 用 swift build 编译，再手动拼出 启动台助手.app，最后可选打包 DMG。
# 用法：scripts/build-app.sh [版本号] [--dmg]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0-dev}"
APP_NAME="启动台助手"
BUNDLE_ID="com.launchy.app"
OUT="dist"
APP="$OUT/$APP_NAME.app"

echo "==> 编译（Universal：arm64 + x86_64）"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Launchy"

echo "==> 组装 .app"
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Launchy"
# 图标：macOS 上优先用 iconutil 从 iconset 生成，失败就用仓库里现成的 .icns
if command -v iconutil >/dev/null && [ -d Resources/AppIcon.iconset ]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" \
    || cp Resources/AppIcon.icns "$APP/Contents/Resources/"
elif [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Launchy</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>修改系统级服务和重启电脑时需要用到。</string>
</dict></plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

if [[ "${2:-}" == "--dmg" ]]; then
  echo "==> 打包 DMG"
  STAGE="$OUT/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  DMG="$OUT/Launchy-$VERSION.dmg"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  echo "DMG: $DMG"
fi
