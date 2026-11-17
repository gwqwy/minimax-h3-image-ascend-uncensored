#!/usr/bin/env bash
# MiniMax-H3 全家桶模型下载（Comfy-Org 官方重打包版，hf-mirror 国内直连）
#
# 下载方式：默认走分片并行下载器 dl_models_fast.py（移植自视频版仓库实测引擎，
# 32 连接/文件 × 2 文件并行，聚合 ~40MB/s）；环境无 python3/requests 时自动
# 回退单连接 curl（~20MB/s）。两条路径都支持断点续传。
#
# 用法:
#   bash scripts/download_models_image.sh          # 全部（文生图 + 图生视频，约 108 GB）
#   bash scripts/download_models_image.sh image    # 只下文生图（46 GB）
#   bash scripts/download_models_image.sh video    # 只下图生视频（完整版 fl2va 34GB，约 62 GB）
#   LOWVRAM=1 bash scripts/download_models_image.sh video      # 视频段低配档：pruned 21GB 替代完整版
#   WITH_LORA=1 bash scripts/download_models_image.sh video    # 视频段 + Turbo 加速 LoRA（+5.5GB）
#   WITH_HERETIC_TE=1 bash scripts/download_models_image.sh all  # 额外下载无审查 heretic TE（26.4GB）
#   MAX_CONN=48 FILES_PARALLEL=3 bash scripts/download_models_image.sh all  # 调并发
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
# !! 官方 TE 必须放本地 official/ 子目录（与同名旧档隔离）：
#    仓内真实路径是 text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors——
#    Comfy-Org/MiniMax-H3-Image 仓里并没有 official/ 子目录，URL 带上它只会 404。
#    其他渠道同名 qwen3vl convrot 会报 JSONDecodeError: char 0（见 docs/踩坑记录-image.md 坑 ①）。
#    文生图与图生视频共用这一份官方 TE，无需重复下载。
set -euo pipefail

MODELS_DIR="${COMFY_MODELS:-/mnt/workspace/ComfyUI/models}"
MIRROR="https://hf-mirror.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE="${1:-all}"
WITH_LORA="${WITH_LORA:-0}"
WITH_HERETIC_TE="${WITH_HERETIC_TE:-0}"
LOWVRAM="${LOWVRAM:-0}"

case "$SCOPE" in
  image|video|all) ;;
  *)
    echo "用法: bash scripts/download_models_image.sh [image|video|all]（默认 all）"
    echo "可选环境变量: WITH_LORA=1（Turbo LoRA）  WITH_HERETIC_TE=1（无审查 TE）  LOWVRAM=1（视频段用 pruned fl2va）"
    echo "并发调节: MAX_CONN（每文件连接数，默认 32）  FILES_PARALLEL（并行文件数，默认 2）"
    exit 1
    ;;
esac

# 本地相对路径 -> [预期最小字节数, 下载 URL]
# add <仓库> <仓内路径> <本地相对路径> <预期最小字节>
# 注意仓内路径与本地路径分离：官方 TE 在仓里位于 text_encoders/ 根，本地放 official/ 子目录隔离；
# heretic TE 在 ethanfel 仓根，本地放 text_encoders/ 根
declare -A FILES=()
declare -A URL_OF=()

add() {
  local rel="$3"
  FILES["$rel"]="$4"
  URL_OF["$rel"]="$MIRROR/$1/resolve/main/$2"
}

if [ "$SCOPE" = "image" ] || [ "$SCOPE" = "all" ]; then
  add "Comfy-Org/MiniMax-H3-Image" \
      "diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors" \
      "diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors" 19540000000
  add "Comfy-Org/MiniMax-H3-Image" \
      "text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" \
      "text_encoders/official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" 25280000000
  add "Comfy-Org/MiniMax-H3-Image" \
      "vae/minimax_h3_image_vae_fp16.safetensors" \
      "vae/minimax_h3_image_vae_fp16.safetensors" 1090000000
fi

if [ "$SCOPE" = "video" ] || [ "$SCOPE" = "all" ]; then
  # 主模型：默认完整版 fl2va（34GB，与视频版仓库一致）；LOWVRAM=1 换精简版 pruned（21GB）
  if [ "$LOWVRAM" = "1" ]; then
    add "Comfy-Org/MiniMax-H3" \
        "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
        "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" 19530000000
    echo "[低配档] fl2va 用精简版 pruned_int8（21GB）替代完整版（34GB）"
  else
    add "Comfy-Org/MiniMax-H3" \
        "diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors" \
        "diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors" 30000000000
  fi
  add "Comfy-Org/MiniMax-H3" \
      "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" \
      "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" 19530000000
  add "Comfy-Org/MiniMax-H3" \
      "vae/minimax_h3_video_vae_fp16.safetensors" \
      "vae/minimax_h3_video_vae_fp16.safetensors" 4850000000
  add "Comfy-Org/MiniMax-H3" \
      "vae/minimax_h3_video_vae_int8_convrot.safetensors" \
      "vae/minimax_h3_video_vae_int8_convrot.safetensors" 2000000000
  add "Comfy-Org/MiniMax-H3" \
      "vae/minimax_h3_audio_vae_fp32.safetensors" \
      "vae/minimax_h3_audio_vae_fp32.safetensors" 560000000
fi

if [ "$WITH_LORA" = "1" ] && { [ "$SCOPE" = "video" ] || [ "$SCOPE" = "all" ]; }; then
  add "Comfy-Org/MiniMax-H3" \
      "loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors" \
      "loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors" 1820000000
  add "Comfy-Org/MiniMax-H3" \
      "loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" \
      "loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" 1820000000
  add "Comfy-Org/MiniMax-H3" \
      "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" \
      "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" 1820000000
fi

# 无审查 heretic TE：与视频版仓库同一地址，本仓库默认关闭（0.45 兼容性未验证，见文件头说明）
if [ "$WITH_HERETIC_TE" = "1" ]; then
  add "ethanfel/Qwen3-VL-32B-Ultra-Heretic-H3-ComfyUI-INT8-ConvRot" \
      "qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors" \
      "text_encoders/qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors" 25000000000
  echo "[heretic] 将下载无审查 TE（26.4GB，放 text_encoders/ 根目录；0.45 兼容性未验证）"
fi

# --- 下载前提醒：档位 / 总量 / 磁盘余量 / 断点续传 ---
TOTAL=0
for v in "${FILES[@]}"; do TOTAL=$((TOTAL + v)); done
echo ""
echo "================== 下载提醒 =================="
echo " 档位: $SCOPE   文件数: ${#FILES[@]}   预计下载: 约 $((TOTAL / 1000000000)) GB"
echo " 目标目录: $MODELS_DIR"
echo " 下载源  : $MIRROR（共享配额，遇 429 限流稍等重跑本脚本，自动断点续传）"
echo " 建议在 tmux/screen 中执行，避免 SSH 断线中断"
echo " 看进度: 下载器每 30s 自报速度与每文件百分比；另开终端可跑"
echo "         watch -n 10 bash scripts/dl_progress.sh（du 实测落盘字节的进度快照）"
AVAIL="$(df -B1 "$MODELS_DIR" 2>/dev/null | awk 'NR==2{print $4}' || true)"
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$((TOTAL * 12 / 10))" ]; then
  echo " !! 磁盘余量偏低: 可用约 $((AVAIL / 1000000000)) GB < 总量 1.2 倍（约 $((TOTAL * 12 / 10 / 1000000000)) GB）"
  echo "    已就位的文件会跳过、实际需求可能更小；请确认磁盘或改用 COMFY_MODELS 指到更大盘"
fi
echo "=============================================="
echo ""

mkdir -p "$MODELS_DIR"

# --- 快路径：分片并行下载器（视频版同款引擎，聚合 ~40MB/s） ---
PY=""
if command -v python3 >/dev/null 2>&1 && python3 -c "import requests" >/dev/null 2>&1; then
  PY="python3"
fi

MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT
: > "$MANIFEST"
for rel in "${!FILES[@]}"; do
  printf '%s\t%s\t%s\n' "${URL_OF[$rel]}" "$MODELS_DIR/$rel" "${FILES[$rel]}" >> "$MANIFEST"
done

if [ -n "$PY" ]; then
  echo "… 分片并行下载（MAX_CONN=${MAX_CONN:-32}/文件 × FILES_PARALLEL=${FILES_PARALLEL:-2} 文件，实测聚合 ~40MB/s）"
  if python3 "$SCRIPT_DIR/dl_models_fast.py" --manifest "$MANIFEST" --root "$MODELS_DIR"; then
    echo ""
    echo "模型就绪清单："
    find "$MODELS_DIR/diffusion_models" "$MODELS_DIR/text_encoders" "$MODELS_DIR/vae" "$MODELS_DIR/loras" \
      -mindepth 1 -maxdepth 2 -name '*.safetensors' -exec du -sh {} \; 2>/dev/null | sort -k2 || true
    exit 0
  fi
  echo "!! 分片下载器未全部完成，回退 curl 单连接模式补漏（断点续传）…"
else
  echo "… 未检测到 python3 + requests，回退 curl 单连接模式（~20MB/s；pip install requests 后重跑可启用 40MB/s 加速）"
fi

# --- 回退路径：单连接 curl（断点续传） ---
for rel in "${!FILES[@]}"; do
  expect="${FILES[$rel]}"
  dst="$MODELS_DIR/$rel"
  mkdir -p "$(dirname "$dst")"

  if [ -s "$dst" ]; then
    size=$(stat -c%s "$dst")
    if [ "$size" -ge "$expect" ]; then
      echo "✓ 已存在: $rel ($size bytes)"
      continue
    fi
    echo "… 文件不完整（$size < $expect），断点续传: $rel"
    curl -L --progress-bar --retry 3 --max-time 7200 -C - -o "$dst" "${URL_OF[$rel]}"
  else
    echo "… 下载: $rel (预期 ≥ $expect bytes)"
    curl -L --progress-bar --retry 3 --max-time 7200 -o "$dst" "${URL_OF[$rel]}"
  fi

  size=$(stat -c%s "$dst")
  if [ "$size" -lt "$expect" ]; then
    echo "!! 校验失败: $rel ($size < $expect bytes) —— 多半是 hf-mirror 429 限流，稍等重跑本脚本（断点续传）"
    exit 1
  fi
done

echo ""
echo "模型就绪清单："
find "$MODELS_DIR/diffusion_models" "$MODELS_DIR/text_encoders" "$MODELS_DIR/vae" "$MODELS_DIR/loras" \
  -mindepth 1 -maxdepth 2 -name '*.safetensors' -exec du -sh {} \; 2>/dev/null | sort -k2 || true
