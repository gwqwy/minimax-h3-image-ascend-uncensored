#!/usr/bin/env bash
# 把仓库 workflows/*.json 安装到 ComfyUI 用户工作流目录
# 装完后浏览器左侧「工作流」面板即可看到（minimax-h3 文件夹内）
#
# 用法: bash scripts/install_workflows.sh
# 环境变量: COMFY_HOME(默认 /mnt/workspace/ComfyUI)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMFY_HOME="${COMFY_HOME:-/mnt/workspace/ComfyUI}"
DEST="$COMFY_HOME/user/default/workflows/minimax-h3"

[ -d "$COMFY_HOME" ] || { echo "!! 未找到 ComfyUI 目录: $COMFY_HOME（先执行 setup_image.sh）"; exit 1; }

mkdir -p "$DEST"
cp -f "$REPO_DIR"/workflows/*.json "$DEST"/
echo "✓ 已安装 $(find "$DEST" -maxdepth 1 -name '*.json' | wc -l) 份工作流 -> $DEST"
echo "  浏览器刷新页面后，左侧「工作流」面板的 minimax-h3 文件夹内即可看到"
