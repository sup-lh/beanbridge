#!/bin/zsh
set -eu
cd "$(dirname "$0")"
if [[ ! -x .build/release/anker-voice-bridge ]]; then
  echo "首次使用，正在编译语音桥……"
  swift build -c release --product anker-voice-bridge
fi
echo "启动后会新建一段录音；结束时按 Control-C。"
exec .build/release/anker-voice-bridge
