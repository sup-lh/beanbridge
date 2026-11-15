#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

echo "== [1/4] 检查 scripts/setup-model.sh 语法与帮助输出 =="
zsh -n scripts/setup-model.sh
help_out="$(./scripts/setup-model.sh --help)"
print -r -- "$help_out" | grep -q "small-q5_1"
print -r -- "$help_out" | grep -q -- "--set-default"
echo "PASS: scripts/setup-model.sh 语法与 --help 检查通过"

echo "== [2/4] 运行 Python 桥接脚本单元测试 =="
/usr/bin/python3 -m unittest scripts/test-create-chat.py scripts/test-doubao-chat.py scripts/test-paseo-chat.py

echo "== [3/4] 构建并检查 dist/安克豆按键语音.app 资源打包 =="
./build-button-app.sh
app_dir="dist/安克豆按键语音.app"
required_paths=(
  "$app_dir/Contents/Info.plist"
  "$app_dir/Contents/MacOS/anker-button-voice"
  "$app_dir/Contents/Resources/create-chat.py"
  "$app_dir/Contents/Resources/doubao-chat.py"
  "$app_dir/Contents/Resources/paseo-chat.py"
  "$app_dir/Contents/Resources/paseo-daemon-helper.mjs"
  "$app_dir/Contents/Resources/set-target.py"
  "$app_dir/Contents/Resources/BeanBridge.icns"
)
for item in "${required_paths[@]}"; do
  if [[ ! -e "$item" ]]; then
    echo "FAIL: 缺少打包产物: $item" >&2
    exit 1
  fi
done
echo "PASS: 应用包资源完整 ($app_dir/Contents/Resources)"

echo "== [4/4] 检查本地安全模式自检 (--self-test / --probe-target) =="
jfk_wav="/opt/homebrew/Cellar/whisper.cpp/1.9.5/share/whisper.cpp/jfk.wav"
model_dir="$HOME/Library/Application Support/AnkerVoiceBridge/Models"
has_model=0
if [[ -n "${BEANBRIDGE_MODEL:-}" && -f "${BEANBRIDGE_MODEL}" ]]; then
  has_model=1
elif [[ -d "$model_dir" ]] && compgen_models=("$model_dir"/ggml-*.bin(N)) && (( ${#compgen_models} > 0 )); then
  has_model=1
fi

if command -v whisper-cli >/dev/null 2>&1 && [[ -f "$jfk_wav" ]] && [[ "$has_model" -eq 1 ]]; then
  self_test_out="$(.build/release/anker-button-voice --self-test "$jfk_wav")"
  echo "PASS: --self-test 输出: $self_test_out"
else
  echo "SKIP: --self-test（缺少 whisper-cli、jfk.wav 或本地 ggml-*.bin 模型）"
fi

probe_tmp="$(mktemp -t beanbridge-probe.XXXXXX.json)"
trap 'rm -f "$probe_tmp"' EXIT
set +e
.build/release/anker-button-voice --probe-target --probe-output "$probe_tmp" >/dev/null 2>&1
probe_rc=$?
set -e
if [[ -s "$probe_tmp" ]] && /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "appID" in d' "$probe_tmp"; then
  echo "PASS: --probe-target --probe-output 安全模式 JSON 输出有效 (exit=$probe_rc): $(cat "$probe_tmp")"
else
  echo "FAIL: --probe-target --probe-output 未写出有效 JSON (exit=$probe_rc)" >&2
  exit 1
fi

echo ""
echo "说明：以上验证覆盖纯本地构建、脚本语法/单测、App 资源打包、Whisper ASR 自检与只读目标探测；"
echo "真机 BLE 握手/按键事件流/Wi-Fi 导出/04.92 物理轻敲实时帧需连接 Anker D3200 硬件实测。"
