#!/bin/zsh
set -eu
cd "$(dirname "$0")"
swift build -c release --product anker-button-voice
app_dir="${1:-dist/安克豆按键语音.app}"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp Support/ButtonInfo.plist "$app_dir/Contents/Info.plist"
cp .build/release/anker-button-voice "$app_dir/Contents/MacOS/anker-button-voice"
cp scripts/create-chat.py "$app_dir/Contents/Resources/create-chat.py"
cp scripts/set-target.py "$app_dir/Contents/Resources/set-target.py"
cp docs/assets/BeanBridge.icns "$app_dir/Contents/Resources/BeanBridge.icns"
codesign --force --deep --sign - "$app_dir"
