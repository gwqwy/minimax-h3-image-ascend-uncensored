#!/usr/bin/env bash
# H3-Image 副本启动脚本（ComfyUI v0.45.4，独立于 0.32 视频主服务）
#
# 环境变量:
#   COMFY_HOME   副本目录（默认 /mnt/workspace/ComfyUI-045）
#   COMFYUI_PORT 端口（默认 8189；8188 留给视频主服务）
#   COMFY_VENV   venv 路径（默认 /mnt/workspace/runtime/venv045）
#   NPU_DEVICES  指定 NPU 卡（默认自动识别）
#
# 与视频版 start_comfyui.sh 的差异：PATH 前置 venv（0.45 依赖装在 venv，
# 系统 torch_npu 经 --system-site-packages 复用），无 --cache-classic。
set -euo pipefail

COMFY_HOME="${COMFY_HOME:-/mnt/workspace/ComfyUI-045}"
PORT="${COMFYUI_PORT:-8189}"
VENV_DIR="${COMFY_VENV:-/mnt/workspace/runtime/venv045}"
VENV_BIN="$VENV_DIR/bin"
RUNTIME="/mnt/workspace/runtime"
PID_FILE="$RUNTIME/comfyui-$PORT.pid"
LOG_FILE="$RUNTIME/comfyui-$PORT.log"
mkdir -p "$RUNTIME"

# --- 已在运行则先停 ---
if [ -s "$PID_FILE" ]; then
    old=$(cat "$PID_FILE")
    kill -0 "$old" 2>/dev/null && { echo "停止旧服务 PID=$old"; kill "$old"; sleep 3; }
    rm -f "$PID_FILE"
fi

# --- CANN 环境（与视频版一致） ---
ASCEND_HOME=""
for p in /usr/local/Ascend/ascend-toolkit "$HOME/Ascend/ascend-toolkit" /home/*/Ascend/ascend-toolkit; do
    [ -f "$p/set_env.sh" ] && ASCEND_HOME="$p" && break
done
[ -z "$ASCEND_HOME" ] && { echo "!! 未找到 CANN（ascend-toolkit/set_env.sh）"; exit 1; }
set +u; source "$ASCEND_HOME/set_env.sh"; set -u

# --- NPU 卡数自适应 ---
n=$(ls -d /dev/davinci[0-9]* 2>/dev/null | wc -l)
NPU_DEVICES="${NPU_DEVICES:-$(seq -s, 0 $(( (n>0?n:1) - 1 )))}"
export ASCEND_RT_VISIBLE_DEVICES="$NPU_DEVICES"
echo "使用 NPU: $NPU_DEVICES"

# --- aarch64 关键修复：预加载 libgomp，避免 torchaudio TLS 报错 ---
[ -f /lib/aarch64-linux-gnu/libgomp.so.1 ] && export LD_PRELOAD=/lib/aarch64-linux-gnu/libgomp.so.1

export HCCL_OP_EXPANSION_MODE="${HCCL_OP_EXPANSION_MODE:-AIV}"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy || true

# --- venv 优先（ComfyUI 0.45 依赖在 venv；torch_npu 经 --system-site-packages 复用） ---
export PATH="$VENV_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ARGS="--listen 0.0.0.0 --port $PORT --disable-auto-launch"
echo "$$" > "$PID_FILE"
cd "$COMFY_HOME"
exec python3 main.py $ARGS >> "$LOG_FILE" 2>&1
