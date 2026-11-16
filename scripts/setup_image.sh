#!/usr/bin/env bash
# 部署 ComfyUI v0.45.4 副本（MiniMax-H3-Image 需要 ≥0.45 的原生文生图节点）
#
# 设计原则：
# - 主服务（如 0.32 视频版）完全不受影响：副本用独立目录 + 独立端口
# - venv 复用系统 torch_npu（--system-site-packages），绝不 pip 升级 torch 系，
#   否则会破坏 CANN/torch_npu 绑定，导致整个昇腾环境不可用
# - 幂等：重复执行安全
#
# 环境变量: COMFY_BASE(默认 /mnt/workspace)  COMFY_VENV(默认 $COMFY_BASE/runtime/venv045)
set -euo pipefail

BASE="${COMFY_BASE:-/mnt/workspace}"
MAIN_DIR="$BASE/ComfyUI"
REPLICA_DIR="$BASE/ComfyUI-045"
VENV_DIR="${COMFY_VENV:-$BASE/runtime/venv045}"
PIN="v0.45.4"

# --- 0. 主仓库（有主服务就用它的 git；没有就浅克隆官方仓库） ---
if [ ! -d "$MAIN_DIR/.git" ]; then
  echo "… $MAIN_DIR 无 ComfyUI git 仓库，浅克隆官方仓库"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$MAIN_DIR"
fi

cd "$MAIN_DIR"

# --- 1. 拉 0.45.4 tag 并建 worktree 副本 ---
git fetch --depth 1 origin tag "$PIN" 2>/dev/null || true
if [ -d "$REPLICA_DIR" ]; then
  echo "✓ 副本目录已存在: $REPLICA_DIR"
else
  git worktree add "$REPLICA_DIR" "$PIN"
  echo "✓ worktree 副本已创建 ($PIN)"
fi

# --- 2. models 共享主目录（软链）。
#      注意：git worktree remove 后重建副本时软链会丢，这里做幂等重建；
#      软链缺失时 ComfyUI 会自建空 models 目录，导致模型列表为空。 ---
if [ ! -L "$REPLICA_DIR/models" ]; then
  rm -rf "$REPLICA_DIR/models"
  ln -s "$MAIN_DIR/models" "$REPLICA_DIR/models"
  echo "✓ models 软链已重建 -> $MAIN_DIR/models"
else
  echo "✓ models 软链已存在"
fi

# --- 3. 独立 venv + 依赖（过滤 torch 系） ---
if [ ! -x "$VENV_DIR/bin/python" ]; then
  echo "… 创建 venv: $VENV_DIR"
  python3 -m venv --system-site-packages "$VENV_DIR"
fi
echo "… 安装 ComfyUI 依赖（已过滤 torch/torchvision/torchaudio）"
grep -viE '^torch' "$REPLICA_DIR/requirements.txt" | "$VENV_DIR/bin/pip" install -q -r /dev/stdin

# --- 4. 兼容性修复：cast_weight device 守卫 ---
# torch_npu 劫持 nn.Module.to()：权重搬运时会以 (device) 调用模块的 cast_weight 钩子，
# ComfyUI 0.45 的实现直接取 input.dtype -> AttributeError: 'torch.device' object has
# no attribute 'dtype'。给所有 cast_weight(self, input) 加 device 守卫即可；
# forward 正常路径传入的是张量，不受影响。
cd "$REPLICA_DIR"
if ! grep -q 'isinstance(input, torch.device)' comfy/ops.py; then
  sed -i '/^        def cast_weight(self, input):$/a\            if isinstance(input, torch.device):\n                return None' comfy/ops.py
  echo "✓ 已打 cast_weight device 守卫补丁（comfy/ops.py）"
else
  echo "✓ cast_weight 守卫补丁已存在"
fi

echo ""
echo "部署完成："
echo "  副本目录: $REPLICA_DIR"
echo "  venv    : $VENV_DIR"
echo "下一步: bash scripts/download_models_image.sh && bash scripts/start_comfyui_image.sh"
