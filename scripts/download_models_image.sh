#!/usr/bin/env bash
# MiniMax-H3-Image 模型下载（Comfy-Org 官方重打包版，hf-mirror 国内直连）
# 三个文件共约 46 GB：
#   diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors        19.54 GB
#   text_encoders/official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors   25.28 GB
#   vae/minimax_h3_image_vae_fp16.safetensors                                 1.09 GB
#
# !! 文本编码器必须用官方版并放 official/ 子目录：
#    其他渠道分发过的同名 qwen3vl convrot（如视频版仓库旧档）的 layer_conf
#    结构与 ComfyUI 0.45 官方加载器不兼容，加载时报
#    `json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)`。
#    官方版（本仓库 Comfy-Org/MiniMax-H3-Image 直连）无此问题。
#
# 环境变量: COMFY_MODELS(默认 /mnt/workspace/ComfyUI/models)
# 支持断点续传：中断后重跑本脚本即可。
set -euo pipefail

MODELS_DIR="${COMFY_MODELS:-/mnt/workspace/ComfyUI/models}"
MIRROR="https://hf-mirror.com"
REPO="Comfy-Org/MiniMax-H3-Image"

# 相对路径 -> 预期最小字节数（用于完整性校验与跳过）
declare -A FILES=(
  ["diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors"]=19540000000
  ["text_encoders/official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors"]=25280000000
  ["vae/minimax_h3_image_vae_fp16.safetensors"]=1090000000
)

for rel in "${!FILES[@]}"; do
  expect="${FILES[$rel]}"
  dst="$MODELS_DIR/$rel"
  mkdir -p "$(dirname "$dst")"

  if [ -f "$dst" ]; then
    size=$(stat -c%s "$dst")
    if [ "$size" -ge "$expect" ]; then
      echo "✓ 已存在且完整，跳过: $rel"
      continue
    fi
    echo "… 文件不完整（$size < $expect），断点续传: $rel"
    curl -sL --retry 3 --max-time 7200 -C - -o "$dst" "$MIRROR/$REPO/resolve/main/$rel"
  else
    echo "… 下载: $rel (预期 ≥ $expect bytes)"
    curl -sL --retry 3 --max-time 7200 -o "$dst" "$MIRROR/$REPO/resolve/main/$rel"
  fi

  size=$(stat -c%s "$dst")
  if [ "$size" -lt "$expect" ]; then
    echo "✗ $rel 大小异常（$size < $expect）。可能被 hf-mirror 限流（429），稍后重跑本脚本续传。"
    exit 1
  fi
  echo "✓ 完成: $rel"
done

echo ""
echo "全部模型就绪："
du -sh "$MODELS_DIR"/diffusion_models/minimax_h3_image* "$MODELS_DIR"/text_encoders/official/* "$MODELS_DIR"/vae/minimax_h3_image* 2>/dev/null || true
