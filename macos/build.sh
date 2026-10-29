#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! xcrun --find swift >/dev/null 2>&1; then
  echo '需要先安装 Apple 开发工具。在终端运行 xcode-select --install，安装后再打开此文件。'
  exit 1
fi
swift test
swift build --configuration release --arch arm64
BIN_DIR="$(swift build --configuration release --arch arm64 --show-bin-path)"
APP="$PWD/dist/NetScope.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NetScope" "$APP/Contents/MacOS/NetScope"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/dist/NetScope-macOS-arm64.zip"
echo "已生成：$APP"
