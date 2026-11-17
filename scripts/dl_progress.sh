#!/usr/bin/env bash
# 下载进度快照（与 download_models_image.sh 的文件清单/预期大小保持一致）
#
# 用法:
#   bash scripts/dl_progress.sh                    # 打印一次快照
#   watch -n 10 bash scripts/dl_progress.sh        # 每 10 秒刷新（另开一个终端看）
#
# 原理：分片下载器会先把目标文件预分配为稀疏文件（stat 看着已是全尺寸），
#       所以用 du（实际落盘字节）做分子、预期字节做分母；curl 回退模式是追加写，
#       du 同样等于已下载量。
set -uo pipefail
MODELS_DIR="${COMFY_MODELS:-/mnt/workspace/ComfyUI/models}"

# 本地相对路径 -> 预期字节
declare -A EXPECT=(
  ["diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors"]=19540000000
  ["text_encoders/official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors"]=25280000000
  ["vae/minimax_h3_image_vae_fp16.safetensors"]=1090000000
  ["diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors"]=34000000000
  ["diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors"]=19530000000
  ["diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors"]=19530000000
  ["vae/minimax_h3_video_vae_fp16.safetensors"]=4850000000
  ["vae/minimax_h3_video_vae_int8_convrot.safetensors"]=3000000000
  ["vae/minimax_h3_audio_vae_fp32.safetensors"]=560000000
  ["loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors"]=1820000000
  ["loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"]=1820000000
  ["loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"]=1820000000
  ["text_encoders/qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors"]=26400000000
)

total_done=0
total_expect=0
printf '%-48s %12s %8s\n' "文件" "已下载" "进度"
echo "----------------------------------------------------------------------------"
for rel in $(printf '%s\n' "${!EXPECT[@]}" | sort); do
  f="$MODELS_DIR/$rel"
  expect=${EXPECT[$rel]}
  total_expect=$((total_expect + expect))
  if [ -f "$f" ]; then
    done_b=$(du -B1 "$f" 2>/dev/null | awk '{print $1}')
    [ -z "$done_b" ] && done_b=0
    [ "$done_b" -gt "$expect" ] && done_b=$expect
    pct=$((done_b * 100 / expect))
  else
    done_b=0
    pct=0
  fi
  total_done=$((total_done + done_b))
  bar_len=$((pct / 5))
  bar=$(printf '%*s' "$bar_len" '' | tr ' ' '#')
  bname=$(basename "$rel")
  [ ${#bname} -gt 48 ] && bname="…${bname: -47}"
  printf '%-48s %9.2fGB %5s%% %-20s\n' "$bname" \
    "$(awk "BEGIN{print $done_b/1000000000}")" "$pct" "$bar"
done
echo "----------------------------------------------------------------------------"
echo "总计: $(awk "BEGIN{printf \"%.2f\", $total_done/1000000000}")GB / $(awk "BEGIN{printf \"%.0f\", $total_expect/1000000000}")GB ($((total_done * 100 / total_expect))%)"
n_pf=$(find "$MODELS_DIR" -name '*.p[0-9]*' 2>/dev/null | wc -l)
echo "活动分片文件数: $n_pf（>0 表示正有分片在写入 = 下载进行中）"
