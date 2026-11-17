#!/usr/bin/env bash
# MiniMax-H3 on Ascend —— ComfyUI 统一启动脚本（v0.45.4 单服务，文生图 + 图生视频）
# 用法: bash scripts/start_comfyui.sh
# 环境变量: COMFY_HOME(默认 /mnt/workspace/ComfyUI)  COMFYUI_PORT(默认 8188)
#           COMFY_VENV(默认 /mnt/workspace/runtime/venv045)  NPU_DEVICES(可手动指定)
#
# 与旧 0.32 版启动脚本的差异：
# - PATH 前置 venv（0.45 依赖装在 venv，系统 torch_npu 经 --system-site-packages 复用）
# - 不带 --cache-classic（0.45 不需要，语义也可能随版本变化，见踩坑记录坑 7）
# - 去掉 0.32 昇腾补丁时代的 COMFYUI_MULTI_DEVICE_BACKEND / set_npu_count 联动
#   （多卡并行适配在 0.45 下未验证，视频并行配置工具留存在 scripts/ 备用）
set -euo pipefail

COMFY_HOME="${COMFY_HOME:-/mnt/workspace/ComfyUI}"
PORT="${COMFYUI_PORT:-8188}"
VENV_DIR="${COMFY_VENV:-/mnt/workspace/runtime/venv045}"
RUNTIME="/mnt/workspace/runtime"
PID_FILE="$RUNTIME/comfyui-$PORT.pid"
LOG_FILE="$RUNTIME/comfyui-$PORT.log"
mkdir -p "$RUNTIME"

# --- 已在运行则先停（统一后 8188 上的旧 0.32 服务也会被这一步替换） ---
if [ -s "$PID_FILE" ]; then
    old=$(cat "$PID_FILE")
    kill -0 "$old" 2>/dev/null && { echo "停止旧服务 PID=$old"; kill "$old"; sleep 3; }
    rm -f "$PID_FILE"
fi

# --- CANN ---
ASCEND_HOME=""
for p in /usr/local/Ascend/ascend-toolkit "$HOME/Ascend/ascend-toolkit" /home/*/Ascend/ascend-toolkit; do
    [ -f "$p/set_env.sh" ] && ASCEND_HOME="$p" && break
done
[ -z "$ASCEND_HOME" ] && { echo "!! 未找到 CANN（ascend-toolkit/set_env.sh）"; exit 1; }
set +u; source "$ASCEND_HOME/set_env.sh"; set -u

# --- venv 校验（0.45 依赖在 venv；torch_npu 经 --system-site-packages 复用） ---
[ -x "$VENV_DIR/bin/python" ] || { echo "!! 未找到 venv: $VENV_DIR（先执行 scripts/setup_image.sh）"; exit 1; }

# --- NPU 卡数自适应 ---
n=$(ls -d /dev/davinci[0-9]* 2>/dev/null | wc -l)
NPU_DEVICES="${NPU_DEVICES:-$(seq -s, 0 $(( (n>0?n:1) - 1 )))}"
export ASCEND_RT_VISIBLE_DEVICES="$NPU_DEVICES"
echo "使用 NPU: $NPU_DEVICES"

# --- aarch64 关键修复：预先加载 libgomp，避免 torchaudio TLS 报错 ---
[ -f /lib/aarch64-linux-gnu/libgomp.so.1 ] && export LD_PRELOAD=/lib/aarch64-linux-gnu/libgomp.so.1

export HCCL_OP_EXPANSION_MODE="${HCCL_OP_EXPANSION_MODE:-AIV}"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy || true

# --- venv 优先（前置而非覆盖：必须保留 set_env.sh 注入的 CANN 编译器路径——
#     triton-ascend 初始化时要找 bisheng 编译器，整段覆盖 PATH 会让 comfy_kitchen
#     导入时 triton 无可用驱动 -> RuntimeError: 0 active drivers） ---
export PATH="$VENV_DIR/bin:$PATH"

# --- triton-ascend 编译器兜底：PATH 里找不到 bisheng 时显式指定 ---
if ! command -v bisheng >/dev/null 2>&1; then
    BISHENG=""
    for r in "$ASCEND_HOME" "${ASCEND_HOME_PATH:-}" /usr/local/Ascend/ascend-toolkit; do
        [ -n "$r" ] && [ -d "$r" ] || continue
        BISHENG="$(find "$r" -maxdepth 4 -type f -name bisheng 2>/dev/null | head -1)"
        [ -n "$BISHENG" ] && break
    done
    if [ -n "$BISHENG" ]; then
        export TRITON_NPU_COMPILER_PATH="$BISHENG"
        echo "triton-ascend 编译器: $BISHENG"
    else
        echo "!! 未找到 bisheng 编译器：comfy_kitchen 的 triton 后端可能初始化失败。"
        echo "   若启动仍报 '0 active drivers'，可退回视频版验证过的旧版 comfy-kitchen："
        echo "   /mnt/workspace/runtime/venv045/bin/pip install 'comfy-kitchen==0.2.30'"
    fi
fi

# --- 显存模式 ---
ARGS="--listen 0.0.0.0 --port $PORT --disable-auto-launch"
if [ "${LOWVRAM:-0}" = "1" ]; then
    echo "低显存模式 (--lowvram)：模型逐层卸载到内存，慢但 32GB 卡也能跑"
    ARGS="$ARGS --lowvram"
fi
if [ "${NORMALVRAM:-0}" = "1" ]; then
    ARGS="$ARGS --normalvram"
fi

echo "$$" > "$PID_FILE"
cd "$COMFY_HOME"
echo "启动中（本终端前台阻塞属正常，Ctrl-C 停止服务；日志: tail -f $LOG_FILE）"
echo "浏览器访问 http://<主机IP>:$PORT ；出图测试: bash scripts/test_t2i.sh"
exec python3 main.py $ARGS >> "$LOG_FILE" 2>&1
