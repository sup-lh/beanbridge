#!/bin/zsh
set -eu
cd "$(dirname "$0")"
if [[ ! -d "dist/安克豆按键语音.app" ]]; then
  ./build-button-app.sh
fi
open "dist/安克豆按键语音.app"
