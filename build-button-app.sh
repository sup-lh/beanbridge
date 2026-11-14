#!/bin/zsh
set -eu
cd "$(dirname "$0")"
swift build -c release --product anker-button-voice
mkdir -p "安克豆按键语音.app/Contents/MacOS"
mkdir -p "安克豆按键语音.app/Contents/Resources"
cp Support/ButtonInfo.plist "安克豆按键语音.app/Contents/Info.plist"
cp .build/release/anker-button-voice "安克豆按键语音.app/Contents/MacOS/anker-button-voice"
cp docs/assets/BeanBridge.icns "安克豆按键语音.app/Contents/Resources/BeanBridge.icns"
codesign --force --deep --sign - "安克豆按键语音.app"
