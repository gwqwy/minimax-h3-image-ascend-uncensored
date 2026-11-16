#!/usr/bin/env bash
# =============================================================
# MiniMax-H3-Image on Ascend 一键部署入口
# 适用: CANNLab / 昇腾 910B 容器与环境
# 用法: bash setup.sh          # 部署 + 下载模型，完成后按提示启动
#       bash setup.sh --skip-models   # 只部署环境（模型已就位时）
# =============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "①/② 部署 ComfyUI v0.45.4 副本（worktree + venv + 兼容性补丁）"
bash "$REPO_DIR/scripts/setup_image.sh"

if [ "${1:-}" != "--skip-models" ]; then
  echo "②/② 下载 H3-Image 模型三件套（约 46GB，断点续传）"
  bash "$REPO_DIR/scripts/download_models_image.sh"
else
  echo "②/② 跳过模型下载（--skip-models）"
fi

echo ""
echo "全部完成。启动与测试："
echo "  bash $REPO_DIR/scripts/start_comfyui_image.sh"
echo "  bash $REPO_DIR/scripts/test_t2i.sh"
