#!/usr/bin/env bash
# MiniMax-H3 全家桶模型下载（Comfy-Org 官方重打包版，hf-mirror 国内直连）
#
# 用法:
#   bash scripts/download_models_image.sh          # 全部（文生图 + 图生视频，约 108 GB）
#   bash scripts/download_models_image.sh image    # 只下文生图（46 GB）
#   bash scripts/download_models_image.sh video    # 只下图生视频（完整版 fl2va 34GB，约 62 GB）
#   LOWVRAM=1 bash scripts/download_models_image.sh video      # 视频段低配档：pruned 21GB 替代完整版
#   WITH_LORA=1 bash scripts/download_models_image.sh video    # 视频段 + Turbo 加速 LoRA（+5.5GB）
#   WITH_HERETIC_TE=1 bash scripts/download_models_image.sh all  # 额外下载无审查 heretic TE（26.4GB）
#
# 与视频版仓库（sazhihou/minimax-h3-ascend-uncensored 的 scripts/dl_models.py）下载地址保持一致，
# 新增/差异项：
#   - 完整版 fl2va_int8_convrot（34GB，视频版默认档；LOWVRAM=1 时与视频版 --lowvram 一样换 pruned）
#   - vae/minimax_h3_video_vae_int8_convrot（INT8 视频 VAE，32GB 低配档工作流用）
#   - WITH_HERETIC_TE=1：ethanfel 无审查文本编码器（视频版默认下载，本仓库改默认关闭，原因见下）
#
# 文生图（Comfy-Org/MiniMax-H3-Image）:
#   diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors        19.54 GB
#   text_encoders/official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors   25.28 GB
#   vae/minimax_h3_image_vae_fp16.safetensors                                 1.09 GB
#
# 图生视频（Comfy-Org/MiniMax-H3，TE 与文生图共用同一份官方档）:
#   diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors               34 GB（LOWVRAM=1 时换 pruned 21GB）
#   diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors       19.53 GB
#   vae/minimax_h3_video_vae_fp16.safetensors                                 4.85 GB
#   vae/minimax_h3_video_vae_int8_convrot.safetensors                         ~3 GB
#   vae/minimax_h3_audio_vae_fp32.safetensors                                 0.56 GB
#
# 可选 Turbo 加速 LoRA（4/8 步出片）:
#   loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors      1.82 GB
#   loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors           1.82 GB
#   loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors          1.82 GB
#
# 可选无审查 heretic TE（ethanfel/Qwen3-VL-32B-Ultra-Heretic-H3-ComfyUI-INT8-ConvRot）:
#   text_encoders/qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors  26.4 GB
#   !! 放 text_encoders/ 根目录（不是 official/）。属非官方渠道 convrot 档，
#      layer_conf 与 0.45 官方加载器的兼容性未验证——很可能踩坑 ①（JSONDecodeError: char 0），
#      下载前请知悉；0.32 口径视频服务可用（视频版仓库默认下载它）。
#
# !! 官方 TE 必须放 official/ 子目录：
#    Comfy-Org/MiniMax-H3(-Image) 官方档的 layer_conf 才与 ComfyUI 0.45 官方加载器兼容；
#    其他渠道同名 qwen3vl convrot 会报 JSONDecodeError: char 0（见 docs/踩坑记录-image.md 坑 ①）。
#    文生图与图生视频共用这一份官方 TE，无需重复下载。
set -euo pipefail

MODELS_DIR="${COMFY_MODELS:-/mnt/workspace/ComfyUI/models}"
MIRROR="https://hf-mirror.com"
SCOPE="${1:-all}"
WITH_LORA="${WITH_LORA:-0}"
WITH_HERETIC_TE="${WITH_HERETIC_TE:-0}"
LOWVRAM="${LOWVRAM:-0}"

case "$SCOPE" in
  image|video|all) ;;
  *)
    echo "用法: bash scripts/download_models_image.sh [image|video|all]（默认 all）"
    echo "可选环境变量: WITH_LORA=1（Turbo LoRA）  WITH_HERETIC_TE=1（无审查 TE）  LOWVRAM=1（视频段用 pruned fl2va）"
    exit 1
    ;;
esac

# 相对路径 -> [预期最小字节数, 所属官方仓库]
# 官方档分两仓：MiniMax-H3-Image（文生图）与 MiniMax-H3（视频）；官方 TE 同名同内容，取任一仓均可
declare -A FILES=()
declare -A REPO_OF=()

add() {
  FILES["$1"]="$2"
  REPO_OF["$1"]="$3"
}

if [ "$SCOPE" = "image" ] || [ "$SCOPE" = "all" ]; then
  add "diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors" 19540000000 "Comfy-Org/MiniMax-H3-Image"
  add "text_encoders/official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" 25280000000 "Comfy-Org/MiniMax-H3-Image"
  add "vae/minimax_h3_image_vae_fp16.safetensors" 1090000000 "Comfy-Org/MiniMax-H3-Image"
fi

if [ "$SCOPE" = "video" ] || [ "$SCOPE" = "all" ]; then
  # 主模型：默认完整版 fl2va（34GB，与视频版仓库一致）；LOWVRAM=1 换精简版 pruned（21GB）
  if [ "$LOWVRAM" = "1" ]; then
    add "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" 19530000000 "Comfy-Org/MiniMax-H3"
    echo "[低配档] fl2va 用精简版 pruned_int8（21GB）替代完整版（34GB）"
  else
    add "diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors" 30000000000 "Comfy-Org/MiniMax-H3"
  fi
  add "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" 19530000000 "Comfy-Org/MiniMax-H3"
  add "vae/minimax_h3_video_vae_fp16.safetensors" 4850000000 "Comfy-Org/MiniMax-H3"
  add "vae/minimax_h3_video_vae_int8_convrot.safetensors" 2000000000 "Comfy-Org/MiniMax-H3"
  add "vae/minimax_h3_audio_vae_fp32.safetensors" 560000000 "Comfy-Org/MiniMax-H3"
fi

if [ "$WITH_LORA" = "1" ] && { [ "$SCOPE" = "video" ] || [ "$SCOPE" = "all" ]; }; then
  add "loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors" 1820000000 "Comfy-Org/MiniMax-H3"
  add "loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" 1820000000 "Comfy-Org/MiniMax-H3"
  add "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" 1820000000 "Comfy-Org/MiniMax-H3"
fi

# 无审查 heretic TE：与视频版仓库同一地址，本仓库默认关闭（0.45 兼容性未验证，见文件头说明）
if [ "$WITH_HERETIC_TE" = "1" ]; then
  add "text_encoders/qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors" 25000000000 \
      "ethanfel/Qwen3-VL-32B-Ultra-Heretic-H3-ComfyUI-INT8-ConvRot"
  echo "[heretic] 将下载无审查 TE（26.4GB，放 text_encoders/ 根目录；0.45 兼容性未验证）"
fi

for rel in "${!FILES[@]}"; do
  expect="${FILES[$rel]}"
  repo="${REPO_OF[$rel]}"
  dst="$MODELS_DIR/$rel"
  mkdir -p "$(dirname "$dst")"

  if [ -s "$dst" ]; then
    size=$(stat -c%s "$dst")
    if [ "$size" -ge "$expect" ]; then
      echo "✓ 已存在: $rel ($size bytes)"
      continue
    fi
    echo "… 文件不完整（$size < $expect），断点续传: $rel"
    curl -sL --retry 3 --max-time 7200 -C - -o "$dst" "$MIRROR/$repo/resolve/main/$rel"
  else
    echo "… 下载 [$repo]: $rel (预期 ≥ $expect bytes)"
    curl -sL --retry 3 --max-time 7200 -o "$dst" "$MIRROR/$repo/resolve/main/$rel"
  fi

  size=$(stat -c%s "$dst")
  if [ "$size" -lt "$expect" ]; then
    echo "!! 校验失败: $rel ($size < $expect bytes) —— 多半是 hf-mirror 429 限流，稍等重跑本脚本（断点续传）"
    exit 1
  fi
done

echo ""
echo "模型就绪清单："
# || true：单独下 video 档时 text_encoders/official 可能尚未创建，目录缺失不应报错退出
find "$MODELS_DIR/diffusion_models" "$MODELS_DIR/text_encoders/official" "$MODELS_DIR/text_encoders" "$MODELS_DIR/vae" "$MODELS_DIR/loras" -maxdepth 1 -name '*.safetensors' -exec du -sh {} \; 2>/dev/null | sort -k2 || true
