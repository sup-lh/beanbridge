#!/bin/zsh
set -eu

support_dir="$HOME/Library/Application Support/AnkerVoiceBridge"
model_dir="$support_dir/Models"
tier="${MODEL_TIER:-base}"
set_default=0

usage() {
  cat <<'EOF'
用法: scripts/setup-model.sh [--tier base|small|small-q5_1|medium] [--set-default]

可选模型层级 (也可通过环境变量 MODEL_TIER 指定):
  base        ggml-base.bin        (~141 MiB, 默认兼容模型，轻量快速)
  small-q5_1  ggml-small-q5_1.bin  (~181 MiB, 量化版高精度中英混说模型，兼顾速度与准确率)
  small       ggml-small.bin       (~465 MiB, 高精度中文与中英混说推荐模型)
  medium      ggml-medium.bin      (~1.43 GiB, 旗舰级中文与专业术语识别模型)

选项:
  --tier <tier>   指定要下载与校验的模型层级
  --set-default   下载/校验成功后将该层级写入 support/model-preference
  -h, --help      显示本帮助说明
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      if [[ $# -lt 2 ]]; then
        echo "错误：--tier 需要指定参数 (base|small|small-q5_1|medium)。" >&2
        exit 1
      fi
      tier="$2"
      shift 2
      ;;
    --tier=*)
      tier="${1#*=}"
      shift
      ;;
    --set-default)
      set_default=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$tier" in
  base)
    model_file="ggml-base.bin"
    expected="60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
    size_desc="约 141 MiB"
    ;;
  small-q5_1)
    model_file="ggml-small-q5_1.bin"
    expected="ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
    size_desc="约 181 MiB"
    ;;
  small)
    model_file="ggml-small.bin"
    expected="1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
    size_desc="约 465 MiB"
    ;;
  medium)
    model_file="ggml-medium.bin"
    expected="6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
    size_desc="约 1.43 GiB"
    ;;
  *)
    echo "不支持的模型层级：$tier（仅支持 base | small | small-q5_1 | medium）" >&2
    exit 1
    ;;
esac

model="$model_dir/$model_file"
source_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$model_file"

print_verification_guide() {
  echo "本地语音模型已就绪。"
  echo "  模型层级: $tier ($model_file)"
  echo "  模型路径: $model"
  echo "  复现验证: swift run anker-button-voice --self-test <wav文件路径>"
  echo "  指定模型: BEANBRIDGE_MODEL=\"$model\" swift run anker-button-voice --self-test <wav文件路径>"
}

persist_preference_if_requested() {
  if [[ "$set_default" -eq 1 ]]; then
    pref_file="$support_dir/model-preference"
    printf '%s\n' "$tier" > "$pref_file"
    chmod 600 "$pref_file"
    echo "  默认偏好已写入: $pref_file ($tier)"
  fi
}

mkdir -p "$model_dir"
chmod 700 "$support_dir" "$model_dir"
if [[ -f "$model" ]]; then
  actual="$(shasum -a 256 "$model" | awk '{print $1}')"
  if [[ "$actual" == "$expected" ]]; then
    chmod 600 "$model" 2>/dev/null || true
    persist_preference_if_requested
    print_verification_guide
    exit 0
  fi
  echo '现有模型校验不匹配；为避免覆盖，已停止。' >&2
  exit 1
fi

partial="$(mktemp "$model_dir/${model_file}.part.XXXXXX")"
trap 'rm -f "$partial"' EXIT
echo "正在下载 ${size_desc} 的本地语音模型 ($model_file)……"
curl --fail --location --retry 2 --output "$partial" "$source_url"
actual="$(shasum -a 256 "$partial" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  echo '模型校验失败，未安装。' >&2
  exit 1
fi
mv "$partial" "$model"
chmod 600 "$model" 2>/dev/null || true
persist_preference_if_requested
print_verification_guide
