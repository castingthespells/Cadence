#!/bin/zsh
set -e

cd "$(dirname "$0")"

APP="Cadence.app"
BIN="$APP/Contents/MacOS/Cadence"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> 编译"
swiftc -O -parse-as-library \
  -target arm64-apple-macos14.0 \
  -o "$BIN" \
  Sources/*.swift \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Network \
  -lsqlite3

if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "签名失败（不影响本机运行）"

echo "==> 完成：$(pwd)/$APP"
du -sh "$APP"
