#!/usr/bin/env bash
# 文生图一键测试：提交 MinimaxH3 节点链并轮询结果（实测在 910B 2×64G 出图）
#
# 用法: bash scripts/test_t2i.sh [提示词] [宽] [高] [端口]
# 示例:
#   bash scripts/test_t2i.sh                                          # 默认提示词 2048x1152
#   bash scripts/test_t2i.sh "a red sports car on a mountain road" 2048 1152 8188
#
# 依赖: scripts/download_models_image.sh 已完成，服务已启动（start_comfyui.sh）
set -euo pipefail

API="http://127.0.0.1:${4:-8188}"
PROMPT="${1:-ancient chinese fantasy, a white-robed swordswoman standing on a bamboo sea peak, moonlight like water, robe and long hair flowing in wind, her sword glowing with azure spirit light, distant mountains wrapped in mist and cloud, cinematic composition, low-angle shot, guofeng fantasy aesthetic, ultra detailed}"
W="${2:-2048}"
H="${3:-1152}"

# --- 生成工作流 JSON（python 拼 JSON，避免引号地狱） ---
PROMPT="$PROMPT" W="$W" H="$H" python3 <<'PYEOF'
import json
import os

wf = {
    "1": {"class_type": "UNETLoader", "inputs": {
        "unet_name": "minimax_h3_image_pruned_bf16.safetensors",
        "weight_dtype": "default"}},
    "2": {"class_type": "CLIPLoader", "inputs": {
        "clip_name": "official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors",
        "type": "minimax", "device": "default"}},
    "3": {"class_type": "VAELoader", "inputs": {
        "vae_name": "minimax_h3_image_vae_fp16.safetensors"}},
    "4": {"class_type": "MiniMaxH3ImageConditioning", "inputs": {
        "clip": ["2", 0], "prompt": os.environ["PROMPT"],
        "width": int(os.environ["W"]), "height": int(os.environ["H"])}},
    "5": {"class_type": "ConditioningZeroOut", "inputs": {
        "conditioning": ["4", 0]}},
    "6": {"class_type": "KSampler", "inputs": {
        "seed": 42, "steps": 6, "cfg": 1.0, "sampler_name": "euler",
        "scheduler": "simple", "denoise": 1.0,
        "model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0],
        "latent_image": ["4", 1]}},
    "7": {"class_type": "VAEDecode", "inputs": {
        "samples": ["6", 0], "vae": ["3", 0]}},
    "8": {"class_type": "SaveImage", "inputs": {
        "filename_prefix": "h3image_t2i", "images": ["7", 0]}},
}
with open("/tmp/h3img_test.json", "w", encoding="utf-8") as f:
    json.dump(wf, f, ensure_ascii=False)
print("workflow json ready")
PYEOF

RESP=$(curl -s --max-time 15 -X POST "$API/prompt" -H "Content-Type: application/json" -d @/tmp/h3img_test.json)
echo "submit resp: $RESP"
PID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('prompt_id',''))" 2>/dev/null || true)
if [ -z "$PID" ]; then
  echo "SUBMIT FAILED"
  exit 1
fi
echo "prompt_id: $PID"

for i in $(seq 1 90); do
  sleep 10
  H2=$(curl -s --max-time 10 "$API/history/$PID")
  STATUS=$(echo "$H2" | python3 -c "
import json,sys
h = json.load(sys.stdin)
p = h.get('$PID', {})
if not p:
    print('pending')
elif p.get('status', {}).get('completed'):
    out = p.get('outputs', {})
    for node, o in out.items():
        if 'images' in o:
            for img in o['images']:
                print('DONE ' + img.get('subfolder','') + '/' + img.get('filename',''))
            break
    else:
        print('done-noimage')
else:
    msgs = p.get('status', {}).get('messages', [])
    err = [m for m in msgs if m[0] == 'execution_error']
    if err:
        print('ERROR ' + json.dumps(err[0])[:2500])
    else:
        print('running')
" 2>/dev/null || echo "poll-err")
  echo "[$i] $STATUS"
  case "$STATUS" in
    DONE*) exit 0 ;;
    ERROR*|done-noimage*) exit 1 ;;
  esac
done
echo "TIMEOUT（首次运行需加载约 45GB 权重，可重跑本脚本；报 ERROR 请把输出贴到 issue）"
exit 1
