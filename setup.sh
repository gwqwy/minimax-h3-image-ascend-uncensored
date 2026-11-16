#!/usr/bin/env bash
# =============================================================
# MiniMax-H3 on Ascend 一键部署入口（统一 ComfyUI v0.45.4 单服务）
# 适用: CANNLab / 昇腾 910B 容器与环境
# 用法: bash setup.sh                 # 升级/部署 + 下载文生图模型，完成后按提示启动
#       bash setup.sh --skip-models   # 只升级/部署（模型已就位时）
# 视频模型可选下载: bash scripts/download_models_image.sh video（或 all / WITH_LORA=1）
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "①/② 升级/部署 ComfyUI v0.45.4 统一服务（备份本地改动 + venv + 兼容性补丁）"
bash "$REPO_DIR/scripts/setup_image.sh"

if [ "${1:-}" != "--skip-models" ]; then
  echo "②/② 下载 H3-Image 文生图模型三件套（约 46GB，断点续传；视频模型另用 video/all 档）"
  bash "$REPO_DIR/scripts/download_models_image.sh" image
else
  echo "②/② 跳过模型下载（--skip-models）"
fi

echo ""
echo "全部完成。启动与测试："
echo "  bash $REPO_DIR/scripts/start_comfyui.sh"
echo "  bash $REPO_DIR/scripts/test_t2i.sh"
