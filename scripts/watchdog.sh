#!/usr/bin/env bash
# ComfyUI 健康看门狗：HTTP 探测失败连续 N 次自动重启服务
# （针对 torch_npu 长跑偶发假死：进程活着但不响应，SSH 正常、网页打不开）
#
# 用法（在 tmux 里挂后台）:
#   nohup bash scripts/watchdog.sh >> /mnt/workspace/runtime/watchdog.log 2>&1 &
# 停止:
#   touch /mnt/workspace/runtime/watchdog.pause   # 暂停探测（不杀进程）
#   rm /mnt/workspace/runtime/watchdog.pause
#   pkill -f "watchdog.sh"                        # 结束看门狗
#
# 环境变量: COMFYUI_PORT(默认8188)  WATCHDOG_FAILS(默认3)  WATCHDOG_INTERVAL(默认30秒)
set -uo pipefail

PORT="${COMFYUI_PORT:-8188}"
RUNTIME="/mnt/workspace/runtime"
PID_FILE="$RUNTIME/comfyui-$PORT.pid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_SCRIPT="$SCRIPT_DIR/start_comfyui.sh"
FAIL_LIMIT="${WATCHDOG_FAILS:-3}"
INTERVAL="${WATCHDOG_INTERVAL:-30}"

fails=0
echo "$(date '+%F %T') watchdog start: port=$PORT interval=${INTERVAL}s fail_limit=$FAIL_LIMIT"

while true; do
  sleep "$INTERVAL"

  # 暂停开关（人工维护服务时用）
  if [ -f "$RUNTIME/watchdog.pause" ]; then
    continue
  fi

  # 健康探测：ComfyUI 自带 /system_stats
  if curl -s --max-time 10 "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
    fails=0
    continue
  fi

  fails=$((fails + 1))
  echo "$(date '+%F %T') health check FAILED ($fails/$FAIL_LIMIT)"

  if [ "$fails" -ge "$FAIL_LIMIT" ]; then
    echo "$(date '+%F %T') restarting ComfyUI..."
    if [ -s "$PID_FILE" ]; then
      old="$(cat "$PID_FILE")"
      kill "$old" 2>/dev/null
      sleep 5
      kill -9 "$old" 2>/dev/null
    fi
    # 兜底清理可能残留的同端口进程（假死进程可能已不在 PID 文件里）
    pkill -9 -f "main.py --listen 0.0.0.0 --port $PORT" 2>/dev/null
    rm -f "$PID_FILE"
    nohup bash "$START_SCRIPT" >> "$RUNTIME/watchdog-restart.log" 2>&1 &
    fails=0
    echo "$(date '+%F %T') restart issued (log: $RUNTIME/watchdog-restart.log)"
  fi
done
