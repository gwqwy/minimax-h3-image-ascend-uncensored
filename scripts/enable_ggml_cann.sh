#!/usr/bin/env bash
# =============================================================
# 激活 Strata 内嵌 ggml 的 CANN 后端（路径 A，见 docs/strata-npu-适配路线图.md）
#
# 前提: 昇腾主机已有 CANN toolkit（set_env.sh），aarch64 Linux
# 用法:
#   bash scripts/enable_ggml_cann.sh baseline   # Phase 0: 上游 llama.cpp -DGGML_CANN=1 基线验证
#   bash scripts/enable_ggml_cann.sh patch      # Phase 1: 恢复 Strata 内嵌树缺失的 ggml-cann 实现
#   bash scripts/enable_ggml_cann.sh build      # Phase 1 验证: 补丁后单独构建 ggml（CANN 后端）
#
# 说明:
# - 本脚本所有子命令都在昇腾主机（aarch64 Linux + CANN）上执行
# - Strata 内嵌树 (engine/third_party/strata-llama) pin 自 llama.cpp
#   3cf03257f219afbe7334045ff7c6a06ac68c627d，include/ggml-cann.h 与注册钩子已在，
#   仅 ggml/src/ggml-cann/ 实现目录与 CMake 开关被裁剪——本脚本按 pin 精确恢复
# - 所有子命令均幂等
# =============================================================
set -euo pipefail

PIN="3cf03257f219afbe7334045ff7c6a06ac68c627d"
UPSTREAM="https://github.com/ggml-org/llama.cpp"
WORK="${STRATA_CANN_WORK:-/mnt/workspace/runtime/llamacpp-cann}"
CMD="${1:-baseline}"

fetch_pin() {
  # 按 pin 精确取上游源码；严格自愈：复用检出必须通过健康检查（pin 一致 + ggml-cann 在场），
  # 否则删除重克隆——网络中断留下的残缺检出是"上游检出中无 ggml/src/ggml-cann"的根源
  local HEALTHY=0
  if [ -d "$WORK/llama.cpp/.git" ]; then
    echo "… 复用已存在的检出: $WORK/llama.cpp（校验中）"
    if ( cd "$WORK/llama.cpp" && git fetch origin "$PIN" 2>/dev/null \
         && git checkout -q --detach "$PIN" 2>/dev/null \
         && git cat-file -e "$PIN^{commit}" 2>/dev/null ); then
      if [ -d "$WORK/llama.cpp/ggml/src/ggml-cann" ]; then
        echo "✓ 检出健康（pin + ggml-cann 均在）"
        HEALTHY=1
      else
        echo "!! 检出已到 pin 但缺 ggml-cann（异常状态），重建"
      fi
    else
      echo "!! 检出无法到达 pin（残缺/浅克隆），重建"
    fi
  fi

  if [ "$HEALTHY" != "1" ]; then
    rm -rf "$WORK/llama.cpp"
    mkdir -p "$WORK"
    echo "… 全量克隆上游 llama.cpp（约 115MB，网络抖动时重试本脚本即可）"
    git clone "$UPSTREAM" "$WORK/llama.cpp" 2>&1 | tail -1
    ( cd "$WORK/llama.cpp" && git checkout -q --detach "$PIN" ) \
      || { echo "!! 无法检出 pin $PIN"; exit 1; }
    [ -d "$WORK/llama.cpp/ggml/src/ggml-cann" ] \
      || { echo "!! 全新检出仍缺 ggml/src/ggml-cann——请截图上报"; exit 1; }
    echo "✓ 全新检出完成（pin + ggml-cann 均在）"
  fi
}

case "$CMD" in

baseline)
  # ---- Phase 0: 上游基线（验证 CANN 后端在这台 910C 上可用） ----
  fetch_pin
  cd "$WORK/llama.cpp"
  echo "… 配置（GGML_CANN=1）"
  cmake -B build-cann -DGGML_CANN=1 2>&1 | tail -5
  grep -i "cann" build-cann/CMakeCache.txt || echo "!! CMakeCache 中未见 GGML_CANN，检查 CANN 环境变量（set_env.sh）"
  echo "… 编译（$(nproc) 线程，首次约 10~20 分钟）"
  cmake --build build-cann -j "$(nproc)" --target llama-cli 2>&1 | tail -5
  echo ""
  echo "=== 验证: 后端枚举（应出现 CANN / Ascend 字样） ==="
  ./build-cann/bin/llama-cli --list-devices 2>&1 | head -20 || true
  echo ""
  echo "若上面列出 CANN 设备 → 基线通过，可继续 patch/build；否则贴输出排查。"
  ;;

patch)
  # ---- Phase 1: 恢复 Strata 内嵌树缺失的 ggml-cann 实现与 CMake 开关 ----
  STRATA_HOME="${STRATA_HOME:-/mnt/workspace/Strata}"
  [ -d "$STRATA_HOME/engine/third_party/strata-llama/ggml" ] \
    || { echo "!! 未找到 Strata 检出: $STRATA_HOME（先 git clone https://github.com/Niko1221/Strata）"; exit 1; }
  GG="$STRATA_HOME/engine/third_party/strata-llama/ggml"

  fetch_pin
  SRC="$WORK/llama.cpp/ggml"
  [ -d "$SRC/ggml-cann" ] || { echo "!! 上游检出中无 ggml/src/ggml-cann（pin 不对？）"; exit 1; }

  echo "… 恢复 ggml/src/ggml-cann/ 实现（来自 pin）"
  rm -rf "$GG/src/ggml-cann"
  cp -r "$SRC/ggml-cann" "$GG/src/ggml-cann"
  echo "✓ 实现 $(find "$GG/src/ggml-cann" -type f | wc -l) 文件"

  # ggml-cann 编译还需要 Ascend CANN toolkit 头文件（acl/ascendc），由主机 set_env.sh 提供——
  # 构建前先校验，缺了直接报清楚而不是让 CMake 半路失败
  CANN_HOME=""
  for p in /usr/local/Ascend/ascend-toolkit "$HOME/Ascend/ascend-toolkit" /home/*/Ascend/ascend-toolkit; do
    [ -f "$p/set_env.sh" ] && CANN_HOME="$p" && break
  done
  [ -n "$CANN_HOME" ] && echo "✓ CANN toolkit: $CANN_HOME" \
    || echo "!! 未找到 CANN toolkit——build 前先 source set_env.sh"

  echo "… 恢复 ggml-cann 依赖的文件（如缺失）"
  for f in $(cd "$SRC" && find ggml-cann -type f 2>/dev/null); do :; done  # 目录整体已拷贝
  # 头文件: include/ggml-cann.h 内嵌树已有（勘察确认），缺失时补
  [ -f "$GG/include/ggml-cann.h" ] || { cp "$SRC/../include/ggml-cann.h" "$GG/include/" 2>/dev/null || \
    cp "$WORK/llama.cpp/ggml/include/ggml-cann.h" "$GG/include/"; echo "✓ 补 include/ggml-cann.h"; }

  echo "… 注入 CMake 开关（幂等）"
  if ! grep -q "GGML_CANN" "$GG/CMakeLists.txt"; then
    # 自包含块追加到文件尾（option + add_subdirectory 同块，不依赖上游 if 嵌套位置）
    python3 - "$GG/CMakeLists.txt" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
block = '''

# __STRATA_CANN__ restored by scripts/enable_ggml_cann.sh (upstream option, stripped in vendoring)
option(GGML_CANN "ggml: use CANN" OFF)
if (GGML_CANN)
    add_subdirectory(ggml-cann)
endif()
'''
open(p, "w", encoding="utf-8").write(s + block)
print("CMakeLists.txt 已注入 GGML_CANN 开关（文件尾自包含块）")
PYEOF
  else
    echo "✓ GGML_CANN 开关已存在"
  fi

  echo ""
  echo "✓ patch 完成。验证构建: bash scripts/enable_ggml_cann.sh build"
  ;;

build)
  # ---- Phase 1 验证: 补丁后的内嵌 ggml 单独构建（CANN 后端） ----
  STRATA_HOME="${STRATA_HOME:-/mnt/workspace/Strata}"
  GG="$STRATA_HOME/engine/third_party/strata-llama/ggml"
  [ -d "$GG/src/ggml-cann" ] || { echo "!! 先跑 patch 子命令"; exit 1; }
  cd "$GG"
  echo "… 配置（GGML_CANN=1）"
  cmake -B build-cann -DGGML_CANN=1 2>&1 | tail -8
  echo "… 编译"
  cmake --build build-cann -j "$(nproc)" --target ggml 2>&1 | tail -5
  echo ""
  find build-cann -name "*cann*" -o -name "*.so" 2>/dev/null | grep -i cann | head -5 \
    && echo "✓ CANN 后端构建产物存在" || echo "!! 未找到 CANN 后端产物，检查上方编译日志"
  echo ""
  echo "下一步: 构建整个 Strata（含引擎）并在 Qwen3.6-35B-A3B GGUF 上验证 NPU 推理;"
  echo "路线图: docs/strata-npu-适配路线图.md Phase 1/2"
  ;;

*)
  echo "用法: bash scripts/enable_ggml_cann.sh [baseline|patch|build]"
  exit 1
  ;;
esac
