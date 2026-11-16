#!/usr/bin/env bash
# 统一部署 ComfyUI v0.45.4（MiniMax-H3 文生图 + 图生视频共用一个服务）
#
# 口径（2026-11-17 起）：废弃 "0.32 视频主服务 + 0.45 worktree 副本" 双服务结构，
# 主目录（/mnt/workspace/ComfyUI）直接升级到 v0.45.4，单端口单服务。
#
# 设计原则：
# - 升级前自动备份主目录的本地改动（0.32 昇腾补丁等）到 runtime/upgrade-backup-*，
#   按备份里的 previous-head.txt 可随时回滚 0.32
# - venv 复用系统 torch_npu（--system-site-packages），绝不 pip 升级 torch 系，
#   否则会破坏 CANN/torch_npu 绑定，导致整个昇腾环境不可用
# - 幂等：重复执行安全
#
# 环境变量: COMFY_BASE(默认 /mnt/workspace)  COMFY_VENV(默认 $COMFY_BASE/runtime/venv045)
set -euo pipefail

BASE="${COMFY_BASE:-/mnt/workspace}"
MAIN_DIR="$BASE/ComfyUI"
VENV_DIR="${COMFY_VENV:-$BASE/runtime/venv045}"
RUNTIME="$BASE/runtime"
PIN="v0.45.4"
REPLICA_DIR="$BASE/ComfyUI-045"   # 旧双服务方案的副本目录，如存在仅提示清理

# --- 0. 主仓库（没有就直接浅克隆 v0.45.4；--branch 支持 tag，无需先拉默认分支再 checkout。
#         已有 0.32 旧仓的机器不走这里，由下方第 1 步的备份升级流程处理） ---
if [ ! -d "$MAIN_DIR/.git" ]; then
  echo "… $MAIN_DIR 无 ComfyUI git 仓库，直接浅克隆 $PIN"
  git clone --depth 1 --branch "$PIN" https://github.com/comfyanonymous/ComfyUI.git "$MAIN_DIR"
fi

cd "$MAIN_DIR"

# --- 1. 主目录升级到 v0.45.4（升级前备份本地改动） ---
git fetch --depth 1 origin tag "$PIN" 2>/dev/null || true
TARGET_SHA="$(git rev-parse "$PIN^{commit}" 2>/dev/null || true)"
CUR_SHA="$(git rev-parse HEAD 2>/dev/null || true)"

if [ -n "$TARGET_SHA" ] && [ "$CUR_SHA" = "$TARGET_SHA" ]; then
  echo "✓ 主目录已在 $PIN"
else
  # 只备份 tracked 文件的改动（模型权重等 untracked 文件不受 checkout 影响）。
  # 注意：0.32 昇腾补丁（comfy-ui-changes.patch）就落在这类本地改动里。
  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    BACKUP_DIR="$RUNTIME/upgrade-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    git rev-parse HEAD > "$BACKUP_DIR/previous-head.txt"
    git diff HEAD > "$BACKUP_DIR/local-changes.patch"
    echo "✓ 已备份主目录本地改动（0.32 昇腾补丁等）: $BACKUP_DIR"
    echo "  回滚: git -C $MAIN_DIR checkout \"\$(cat $BACKUP_DIR/previous-head.txt)\" && git -C $MAIN_DIR apply $BACKUP_DIR/local-changes.patch"
  fi
  git checkout -f "$PIN"
  echo "✓ 主目录已升级到 $PIN (${TARGET_SHA:-unknown})"
fi

# --- 2. 独立 venv + 依赖（过滤 torch 系） ---
if [ ! -x "$VENV_DIR/bin/python" ]; then
  echo "… 创建 venv: $VENV_DIR"
  python3 -m venv --system-site-packages "$VENV_DIR"
fi
echo "… 安装 ComfyUI $PIN 依赖（已过滤 torch/torchvision/torchaudio）"
grep -viE '^torch' "$MAIN_DIR/requirements.txt" | "$VENV_DIR/bin/pip" install -q -r /dev/stdin

# --- 3. 兼容性修复：cast_weight device 守卫 ---
# torch_npu 劫持 nn.Module.to()：权重搬运时会以 (device) 调用模块的 cast_weight 钩子，
# ComfyUI 0.45 的实现直接取 input.dtype -> AttributeError: 'torch.device' object has
# no attribute 'dtype'。给所有 cast_weight(self, input) 加 device 守卫即可；
# forward 正常路径传入的是张量，不受影响。
if ! grep -q 'isinstance(input, torch.device)' comfy/ops.py; then
  sed -i '/^        def cast_weight(self, input):$/a\            if isinstance(input, torch.device):\n                return None' comfy/ops.py
  echo "✓ 已打 cast_weight device 守卫补丁（comfy/ops.py）"
else
  echo "✓ cast_weight 守卫补丁已存在"
fi

# --- 4. 旧双服务遗留提示 ---
if [ -d "$REPLICA_DIR" ]; then
  echo ""
  echo "! 检测到旧双服务方案副本: $REPLICA_DIR（统一方案不再需要）"
  echo "  统一服务验证通过后可清理:"
  echo "    git -C \"$MAIN_DIR\" worktree remove --force \"$REPLICA_DIR\""
fi

echo ""
echo "部署完成："
echo "  主目录  : $MAIN_DIR ($PIN)"
echo "  venv    : $VENV_DIR"
echo "提示: 旧主服务的 custom_nodes（0.32 时代插件）在 0.45 下可能导入失败，ComfyUI 会自动跳过；"
echo "      确认不需要可手动移除 $MAIN_DIR/custom_nodes/ 下对应目录"
echo "下一步: bash scripts/download_models_image.sh image && bash scripts/start_comfyui.sh"
