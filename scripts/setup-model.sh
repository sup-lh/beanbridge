#!/bin/zsh
set -eu

model_dir="$HOME/Library/Application Support/AnkerVoiceBridge/Models"
model="$model_dir/ggml-base.bin"
expected='60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe'
source_url='https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin'

mkdir -p "$model_dir"
chmod 700 "$HOME/Library/Application Support/AnkerVoiceBridge" "$model_dir"
if [[ -f "$model" ]]; then
  actual="$(shasum -a 256 "$model" | awk '{print $1}')"
  if [[ "$actual" == "$expected" ]]; then
    echo '本地语音模型已就绪。'
    exit 0
  fi
  echo '现有模型校验不匹配；为避免覆盖，已停止。' >&2
  exit 1
fi

partial="$(mktemp "$model_dir/ggml-base.bin.part.XXXXXX")"
trap 'rm -f "$partial"' EXIT
echo '正在下载约 141 MiB 的本地语音模型……'
curl --fail --location --retry 2 --output "$partial" "$source_url"
actual="$(shasum -a 256 "$partial" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  echo '模型校验失败，未安装。' >&2
  exit 1
fi
mv "$partial" "$model"
echo '本地语音模型已就绪。'
