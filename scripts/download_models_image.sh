#!/usr/bin/env bash
# MiniMax-H3 全家桶模型下载（Comfy-Org 官方重打包版，hf-mirror 国内直连）
#
# 下载方式：内置分片并行下载引擎（移植自视频版仓库 sazhihou/minimax-h3-ascend-uncensored
# 的 dl_models.py 真机实测引擎，32 连接/文件 × 2 文件并行，聚合 ~40MB/s）。
# 引擎以 heredoc 内嵌于本脚本，运行时落到临时文件执行——**单文件自包含**，
# 不存在"配套 .py 没跟上导致回退"的故障模式。环境无 python3/requests 时
# 自动回退单连接 curl（~20MB/s）。两条路径都支持断点续传。
#
# 用法:
#   bash scripts/download_models_image.sh          # 全部（文生图 + 图生视频，约 108 GB）
#   bash scripts/download_models_image.sh image    # 只下文生图（46 GB）
#   bash scripts/download_models_image.sh video    # 只下图生视频（完整版 fl2va 34GB，约 62 GB）
#   LOWVRAM=1 bash scripts/download_models_image.sh video      # 视频段低配档：pruned 21GB 替代完整版
#   WITH_LORA=1 bash scripts/download_models_image.sh video    # 视频段 + Turbo 加速 LoRA（+5.5GB）
#   WITH_HERETIC_TE=1 bash scripts/download_models_image.sh all  # 额外下载无审查 heretic TE（26.4GB）
#   MAX_CONN=48 FILES_PARALLEL=3 bash scripts/download_models_image.sh all  # 调并发
#
# 与视频版仓库（sazhihou/minimax-h3-ascend-uncensored 的 scripts/dl_models.py）下载地址保持一致，
# 新增/差异项：
#   - 完整版 fl2va_int8_convrot（34GB，视频版默认档；LOWVRAM=1 时与视频版 --lowvram 一样换 pruned）
#   - vae/minimax_h3_video_vae_int8_convrot（INT8 视频 VAE，32GB 低配档工作流用）
#   - WITH_HERETIC_TE=1：ethanfel 无审查文本编码器（视频版默认下载，本仓库改默认关闭，原因见下）
#
# 文生图（Comfy-Org/MiniMax-H3-Image）:
#   diffusion_models/minimax_h3_image_pruned_bf16.safetensors               40.23 GB（全量，int8 已退出）
#   text_encoders/official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors   25.28 GB
#   vae/minimax_h3_image_vae_fp16.safetensors                                 1.09 GB
#
# 图生视频（Comfy-Org/MiniMax-H3，TE 与文生图共用同一份官方档）:
#   diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors               34 GB（LOWVRAM=1 时换 pruned 21GB）
#   diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors       19.53 GB
#   vae/minimax_h3_video_vae_fp16.safetensors                                 4.85 GB
#   vae/minimax_h3_video_vae_int8_convrot.safetensors                         ~3 GB
#   vae/minimax_h3_audio_vae_fp32.safetensors                                 0.56 GB
#
# 可选 Turbo 加速 LoRA（4/8 步出片）:
#   loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors      1.82 GB
#   loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors           1.82 GB
#   loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors          1.82 GB
#
# 可选无审查 heretic TE（ethanfel/Qwen3-VL-32B-Ultra-Heretic-H3-ComfyUI-INT8-ConvRot）:
#   text_encoders/qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors  26.4 GB
#   !! 放 text_encoders/ 根目录（不是 official/）。属非官方渠道 convrot 档，
#      layer_conf 与 0.45 官方加载器的兼容性未验证——很可能踩坑 ①（JSONDecodeError: char 0），
#      下载前请知悉；0.32 口径视频服务可用（视频版仓库默认下载它）。
#
# !! 官方 TE 必须放本地 official/ 子目录（与同名旧档隔离）：
#    仓内真实路径是 text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors——
#    Comfy-Org/MiniMax-H3-Image 仓里并没有 official/ 子目录，URL 带上它只会 404。
#
# 看进度: 引擎每 30s 自报速度与每文件百分比；另开终端可跑
#         watch -n 10 bash scripts/dl_progress.sh（du 实测落盘字节的进度快照）
set -euo pipefail

MODELS_DIR="${COMFY_MODELS:-/mnt/workspace/ComfyUI/models}"
MIRROR="https://hf-mirror.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE="${1:-all}"
WITH_LORA="${WITH_LORA:-0}"
WITH_HERETIC_TE="${WITH_HERETIC_TE:-0}"
LOWVRAM="${LOWVRAM:-0}"

case "$SCOPE" in
  image|video|all) ;;
  *)
    echo "用法: bash scripts/download_models_image.sh [image|video|all]（默认 all）"
    echo "可选环境变量: WITH_LORA=1（Turbo LoRA）  WITH_HERETIC_TE=1（无审查 TE）  LOWVRAM=1（视频段用 pruned fl2va）"
    echo "并发调节: MAX_CONN（每文件连接数，默认 32）  FILES_PARALLEL（并行文件数，默认 2）"
    exit 1
    ;;
esac

# 本地相对路径 -> [预期最小字节数, 下载 URL]
# add <仓库> <仓内路径> <本地相对路径> <预期最小字节>
# 注意仓内路径与本地路径分离：官方 TE 在仓里位于 text_encoders/ 根，本地放 official/ 子目录隔离；
# heretic TE 在 ethanfel 仓根，本地放 text_encoders/ 根
declare -A FILES=()
declare -A URL_OF=()

add() {
  local rel="$3"
  FILES["$rel"]="$4"
  URL_OF["$rel"]="$MIRROR/$1/resolve/main/$2"
}

if [ "$SCOPE" = "image" ] || [ "$SCOPE" = "all" ]; then
  # image DiT 用 bf16 全量（40.2GB）：int8 量化版 4K/高分直出疑似量化退化（发糊），
  # 已退出清单；权重 40GB < 单设备 64GB，910C/910B 均可直载
  add "Comfy-Org/MiniMax-H3-Image" \
      "diffusion_models/minimax_h3_image_pruned_bf16.safetensors" \
      "diffusion_models/minimax_h3_image_pruned_bf16.safetensors" 40000000000
  add "Comfy-Org/MiniMax-H3-Image" \
      "text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" \
      "text_encoders/official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" 25280000000
  add "Comfy-Org/MiniMax-H3-Image" \
      "vae/minimax_h3_image_vae_fp16.safetensors" \
      "vae/minimax_h3_image_vae_fp16.safetensors" 1090000000
fi

if [ "$SCOPE" = "video" ] || [ "$SCOPE" = "all" ]; then
  # 主模型：默认完整版 fl2va（34GB，与视频版仓库一致）；LOWVRAM=1 换精简版 pruned（21GB）
  if [ "$LOWVRAM" = "1" ]; then
    add "Comfy-Org/MiniMax-H3" \
        "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
        "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" 19530000000
    echo "[低配档] fl2va 用精简版 pruned_int8（21GB）替代完整版（34GB）"
  else
    add "Comfy-Org/MiniMax-H3" \
        "diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors" \
        "diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors" 30000000000
  fi
  add "Comfy-Org/MiniMax-H3" \
      "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" \
      "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" 19530000000
  add "Comfy-Org/MiniMax-H3" \
      "vae/minimax_h3_video_vae_fp16.safetensors" \
      "vae/minimax_h3_video_vae_fp16.safetensors" 4850000000
  add "Comfy-Org/MiniMax-H3" \
      "vae/minimax_h3_video_vae_int8_convrot.safetensors" \
      "vae/minimax_h3_video_vae_int8_convrot.safetensors" 2000000000
  add "Comfy-Org/MiniMax-H3" \
      "vae/minimax_h3_audio_vae_fp32.safetensors" \
      "vae/minimax_h3_audio_vae_fp32.safetensors" 560000000
fi

if [ "$WITH_LORA" = "1" ] && { [ "$SCOPE" = "video" ] || [ "$SCOPE" = "all" ]; }; then
  add "Comfy-Org/MiniMax-H3" \
      "loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors" \
      "loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors" 1820000000
  add "Comfy-Org/MiniMax-H3" \
      "loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" \
      "loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" 1820000000
  add "Comfy-Org/MiniMax-H3" \
      "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" \
      "loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" 1820000000
fi

# 无审查 heretic TE：与视频版仓库同一地址，本仓库默认关闭（0.45 兼容性未验证，见文件头说明）
if [ "$WITH_HERETIC_TE" = "1" ]; then
  add "ethanfel/Qwen3-VL-32B-Ultra-Heretic-H3-ComfyUI-INT8-ConvRot" \
      "qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors" \
      "text_encoders/qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors" 25000000000
  echo "[heretic] 将下载无审查 TE（26.4GB，放 text_encoders/ 根目录；0.45 兼容性未验证）"
fi

# --- 下载前提醒：档位 / 总量 / 磁盘余量 / 断点续传 ---
TOTAL=0
for v in "${FILES[@]}"; do TOTAL=$((TOTAL + v)); done
echo ""
echo "================== 下载提醒 =================="
echo " 档位: $SCOPE   文件数: ${#FILES[@]}   预计下载: 约 $((TOTAL / 1000000000)) GB"
echo " 目标目录: $MODELS_DIR"
echo " 下载源  : $MIRROR（共享配额，遇 429 限流稍等重跑本脚本，自动断点续传）"
echo " 建议在 tmux/screen 中执行，避免 SSH 断线中断"
echo " 看进度: 引擎每 30s 自报速度与每文件百分比；另开终端可跑"
echo "         watch -n 10 bash scripts/dl_progress.sh（du 实测落盘字节的进度快照）"
AVAIL="$(df -B1 "$MODELS_DIR" 2>/dev/null | awk 'NR==2{print $4}' || true)"
if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$((TOTAL * 12 / 10))" ]; then
  echo " !! 磁盘余量偏低: 可用约 $((AVAIL / 1000000000)) GB < 总量 1.2 倍（约 $((TOTAL * 12 / 10 / 1000000000)) GB）"
  echo "    已就位的文件会跳过、实际需求可能更小；请确认磁盘或改用 COMFY_MODELS 指到更大盘"
fi
echo "=============================================="
echo ""

mkdir -p "$MODELS_DIR"

MANIFEST="$(mktemp /tmp/h3_manifest.XXXXXX)"
PYTMP="$(mktemp /tmp/h3_dl_engine.XXXXXX.py)"
cleanup() { rm -f "$MANIFEST" "$PYTMP"; }
trap cleanup EXIT

: > "$MANIFEST"
for rel in "${!FILES[@]}"; do
  printf '%s\t%s\t%s\n' "${URL_OF[$rel]}" "$MODELS_DIR/$rel" "${FILES[$rel]}" >> "$MANIFEST"
done

# --- 内置分片并行下载引擎（自包含，heredoc 落临时文件执行） ---
# 引擎移植自视频版仓库真机实测代码：64MB 分片 × MAX_CONN 连接/文件 × FILES_PARALLEL 文件，
# 分片级断点续传（.p<offset> 进度文件）、精确大小校验、仅允许 https://hf-mirror.com 源、
# 目标路径强制锁在 --root 内且仅 .safetensors（SSRF/路径穿越防护）。
cat > "$PYTMP" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse, os, sys, threading, time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse
import requests

MIRROR_HOST = "hf-mirror.com"
CHUNK = 64 * 1024 * 1024
NCHUNK = int(os.environ.get("MAX_CONN", "32"))
FILES_PARALLEL = int(os.environ.get("FILES_PARALLEL", "2"))
REQ_TIMEOUT = int(os.environ.get("H3_DL_TIMEOUT", "90"))

lock = threading.Lock()
total = [0]        # 本次会话累计字节
done = [False]
ROOT = [None]      # models 根目录（路径穿越防护边界），由 --root 注入
prog = {}          # 文件名 -> [本次会话已写字节, 文件总字节]，reporter 每 30s 打印


def check_url(url):
    """SSRF 防护：仅允许 https://hf-mirror.com/（域名精确匹配）"""
    u = urlparse(url)
    if u.scheme != "https" or u.hostname != MIRROR_HOST:
        raise SystemExit(f"URL 非法（仅允许 https://{MIRROR_HOST}/）: {url}")


def check_dest(dest, root):
    """路径穿越防护：目标必须在 models 根目录内且为 .safetensors"""
    rp_dest = os.path.realpath(dest)
    rp_root = os.path.realpath(root)
    if os.path.commonpath([rp_dest, rp_root]) != rp_root:
        raise SystemExit(f"目标路径越界（必须在 {root} 内）: {dest}")
    if os.path.basename(dest) == "" or not os.path.basename(dest).endswith(".safetensors"):
        raise SystemExit(f"目标文件名非法（仅允许 .safetensors）: {dest}")


def load_manifest(path, root):
    """解析 manifest：url<TAB>dest<TAB>expect_min_bytes，并做源与目标校验"""
    items = []
    with open(path, encoding="utf-8") as f:
        for ln, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                raise SystemExit(f"manifest 每行三列（url\\tdest\\texpect）: {line[:100]}")
            url, dest, expect = parts
            check_url(url)
            check_dest(dest, root)
            items.append((url, dest, int(expect)))
    if not items:
        raise SystemExit("manifest 为空")
    return items


def head_size(url):
    with requests.head(url, allow_redirects=True, timeout=60) as r:
        return int(r.headers["Content-Length"])


def dl(url, path, expect_min):
    """单文件下载：分片并行 + 断点续传，返回是否完整"""
    check_url(url)            # SSRF 防护：请求前再次校验源白名单
    check_dest(path, ROOT[0])
    fname = os.path.basename(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    size = head_size(url)
    if os.path.exists(path) and os.path.getsize(path) == size:
        print(f"[跳过] {fname} ({size / 1e9:.2f}GB 已存在)", flush=True)
        return True
    with lock:
        prog[fname] = [0, size]   # 供 reporter 打印每文件进度

    print(f"[下载] {fname} ({size / 1e9:.2f}GB)", flush=True)
    # 预分配目标文件
    if not os.path.exists(path) or os.path.getsize(path) != size:
        with open(path, "wb" if not os.path.exists(path) else "r+b") as f:
            f.truncate(size)

    ranges, s = [], 0
    while s < size:
        e = min(s + CHUNK - 1, size - 1)
        ranges.append((s, e))
        s = e + 1

    def get(rg):
        a, b = rg
        check_url(url)        # SSRF 防护：每个分片请求前校验源白名单
        pf = f"{path}.p{a}"   # 分片进度文件（.gitignore 已忽略 *.p[0-9]*）
        pos = a + (os.path.getsize(pf) if os.path.exists(pf) else 0)
        for _ in range(6):
            try:
                while pos <= b:
                    r = requests.get(url, headers={"Range": f"bytes={pos}-{b}"},
                                     stream=True, timeout=REQ_TIMEOUT)
                    r.raise_for_status()
                    with open(pf, "ab") as f, open(path, "r+b") as t:
                        t.seek(pos)
                        for buf in r.iter_content(1 << 20):
                            if buf:
                                f.write(buf)
                                t.write(buf)
                                pos += len(buf)
                                with lock:
                                    total[0] += len(buf)
                                    prog[fname][0] += len(buf)
                break
            except Exception as e:
                print(f"  [重试] {fname} @{a}: {repr(e)[:60]}", flush=True)
        else:
            return False      # 6 次重试后仍失败（for-else：无 break 即全失败）
        if os.path.exists(pf):
            os.remove(pf)
        return True

    ok = True
    with ThreadPoolExecutor(max_workers=NCHUNK) as ex:
        for ret in ex.map(get, ranges):
            ok = ok and ret
    # 清理残留进度分片（数据已写入目标文件本身）
    for a, _ in ranges:
        pf = f"{path}.p{a}"
        if os.path.exists(pf):
            os.remove(pf)

    if os.path.getsize(path) != size:
        ok = False
    if ok and os.path.getsize(path) < expect_min:
        print(f"  !! {fname} 小于预期 {expect_min} 字节，疑似限流错误页", flush=True)
        ok = False
    print(f"[{'完成' if ok else '未完成'}] {fname}", flush=True)
    return ok


def reporter():
    last = [0]
    while not done[0]:
        time.sleep(30)
        d = (total[0] - last[0]) / 30 / 1e6
        last[0] = total[0]
        print(f"  --- 速度 {d:.1f} MB/s，本次累计 {total[0] / 1e9:.2f} GB", flush=True)
        with lock:
            snap = sorted(prog.items())
        for k, (w, t) in snap:
            if t:
                print(f"      {k}: {w / 1e9:.2f}/{t / 1e9:.2f}GB ({w * 100 // t}%)", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True, help="TSV: url\\tdest\\texpect_min_bytes")
    ap.add_argument("--root", required=True, help="下载目标根目录（路径穿越防护边界）")
    args = ap.parse_args()
    ROOT[0] = args.root
    items = load_manifest(args.manifest, args.root)
    print(f"分片并行下载: {len(items)} 个文件 | MAX_CONN={NCHUNK}/文件 | 并行文件数={FILES_PARALLEL}",
          flush=True)
    threading.Thread(target=reporter, daemon=True).start()
    with ThreadPoolExecutor(max_workers=FILES_PARALLEL) as ex:
        results = list(ex.map(lambda it: dl(it[0], it[1], it[2]), items))
    done[0] = True
    failed = [items[i][1] for i, r in enumerate(results) if not r]
    if failed:
        print(f"\n{len(failed)} 个文件未完成（重跑可断点续传）:")
        for dest in failed:
            print("  -", os.path.basename(dest))
        sys.exit(1)
    print("\n全部下载完成。")


if __name__ == "__main__":
    main()
PYEOF

# --- 快路径：内置分片并行下载器（聚合 ~40MB/s） ---
PY=""
if command -v python3 >/dev/null 2>&1 && python3 -c "import requests" >/dev/null 2>&1; then
  PY="python3"
fi

if [ -n "$PY" ]; then
  echo "… 分片并行下载（MAX_CONN=${MAX_CONN:-32}/文件 × FILES_PARALLEL=${FILES_PARALLEL:-2} 文件，实测聚合 ~40MB/s）"
  if python3 "$PYTMP" --manifest "$MANIFEST" --root "$MODELS_DIR"; then
    echo ""
    echo "模型就绪清单："
    find "$MODELS_DIR/diffusion_models" "$MODELS_DIR/text_encoders" "$MODELS_DIR/vae" "$MODELS_DIR/loras" \
      -mindepth 1 -maxdepth 2 -name '*.safetensors' -exec du -sh {} \; 2>/dev/null | sort -k2 || true
    exit 0
  fi
  echo "!! 分片下载器未全部完成，回退 curl 单连接模式补漏（断点续传）…"
else
  echo "… 未检测到 python3 + requests，回退 curl 单连接模式（~20MB/s；pip install requests 后重跑可启用 40MB/s 加速）"
fi

# --- 回退路径：单连接 curl（断点续传） ---
for rel in "${!FILES[@]}"; do
  expect="${FILES[$rel]}"
  dst="$MODELS_DIR/$rel"
  mkdir -p "$(dirname "$dst")"

  if [ -s "$dst" ]; then
    size=$(stat -c%s "$dst")
    if [ "$size" -ge "$expect" ]; then
      echo "✓ 已存在: $rel ($size bytes)"
      continue
    fi
    echo "… 文件不完整（$size < $expect），断点续传: $rel"
    curl -L --progress-bar --retry 3 --max-time 7200 -C - -o "$dst" "${URL_OF[$rel]}"
  else
    echo "… 下载: $rel (预期 ≥ $expect bytes)"
    curl -L --progress-bar --retry 3 --max-time 7200 -o "$dst" "${URL_OF[$rel]}"
  fi

  size=$(stat -c%s "$dst")
  if [ "$size" -lt "$expect" ]; then
    echo "!! 校验失败: $rel ($size < $expect bytes) —— 多半是 hf-mirror 429 限流，稍等重跑本脚本（断点续传）"
    exit 1
  fi
done

echo ""
echo "模型就绪清单："
find "$MODELS_DIR/diffusion_models" "$MODELS_DIR/text_encoders" "$MODELS_DIR/vae" "$MODELS_DIR/loras" \
  -mindepth 1 -maxdepth 2 -name '*.safetensors' -exec du -sh {} \; 2>/dev/null | sort -k2 || true
