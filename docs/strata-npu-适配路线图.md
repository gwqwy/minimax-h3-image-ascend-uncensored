# Strata → 昇腾 NPU 适配路线图

> 目标：让 Strata 推理引擎（[Niko1221/Strata](https://github.com/Niko1221/Strata)，MIT，C++）
> 在昇腾 910C（Atlas A3，2×64GB 设备，240GB RAM，aarch64）上工作。
> 本文基于 Strata main 分支源码实盘分析（2026-11-19 快照，engine 1773 个 C++ 文件 /
> 419 个 CUDA 文件 / 55 个 Metal / SYCL+HIP 后端各一套 / 内嵌 ggml 两份）。

## TL;DR

| 路径 | 工作量 | 确定性 | 产出 |
|---|---|---|---|
| **A. 激活内嵌 ggml 的 CANN 后端**（推荐首选） | 天~周级 | 高（注册钩子已在，上游实现现成） | GGUF 模型走 NPU：Qwen3.6-35B-A3B 立即可用；**DeepSeek V4.1 Flash GGUF 有机会**（需同步上游 llama.cpp 图支持） |
| B. 引擎自有 CUDA 内核移植昇腾 | 月级 | 中（dpct/SYCL 先例证明可自动迁移，但需人工调优） | Qwen3.8-Flash-Next 全速 NPU |
| C. 绕过 Strata，直接 llama.cpp + ggml-cann | 天级 | 高 | 与 A 同源但不依赖 Strata 的务实捷径 |

**关键发现（源码证据）**：
- 内嵌 ggml（`engine/third_party/strata-llama/ggml`）的 `ggml-backend-reg.cpp` **已含
  `GGML_USE_CANN` 注册钩子**（`register_backend(ggml_backend_cann_reg())`），只缺
  `ggml/src/ggml-cann/` 实现目录——上游 llama.cpp 有现成实现（Ascend C 写就）
- 引擎已有多后端移植先例：SYCL 后端由 Intel **dpct 从 CUDA 自动迁移**生成（289 文件）、
  HIP 后端带 `hip_compat` 头 + `cmake/hip_backend.cmake`、Metal 140 文件——
  "新增一个后端"在架构上是被支持的
- MoE 内存分层是核心能力：`engine/src/core/expert_cache.cpp` / `expert_source.cpp` /
  `mtp.cpp`；设计文档明言"VRAM 预算是整个设计的硬约束"——与昇腾
  "NPU=活跃层，RAM=专家层" 的映射概念同构

## 现实约束（先说清楚什么不行）

- **DeepSeek V4.1 Flash 的"完整体"在 910C 上依然不可行**：官方 W4A8 权重（300GB 级，
  ModelScope Eco-Tech 发布）超出 128GB HBM + 240GB RAM 的同时容纳能力；GGUF 最小档
  UD-IQ1_S 233GB 跨盘可放，走路径 C 的 mmap+CANN 混合推理**速度未经验证**（专家层
  大概率落在 CPU/CANN 混合，预期 1~5 tok/s 量级，待实测）
- Strata 官方 models 文档（`docs/MODELS.md`）**只收录 Qwen3.8-Flash-Next 与
  Qwen3.6-35B-A3B**；新闻中"支持 DeepSeek V4 Flash"未见于文档，按未验证处理
- 引擎硬绑 **CUDA sm_120**（device.hpp 明言"CMakeLists 已拒绝编译其他架构"）——
  自有引擎的 NPU 化（路径 B）是内核级重写，不是开关

## 你的机器上能跑什么（路径 A/C 之后的账本）

| 模型 | 打包 | RAM+HBM 需求 | 预期 |
|---|---|---|---|
| **Qwen3.8-Flash-Next** | IQ3_S（官方评"最佳，与全量持平"） | **54.8 GB** | 240GB RAM + NPU 加速，从容 |
| Qwen3.8-Flash-Next Coder | IQ1_M（保留 256/512 专家，代码特化） | 29.6 GB（shard1） | 秒开 |
| Qwen3.6-35B-A3B | UD-Q4_K_XL | ~20 GB | 从容 |
| DeepSeek V4.1 Flash | UD-IQ1_S | 233 GB（RAM 240GB 边缘 + mmap） | ⚠️ 可试，速度待实测 |
| DeepSeek V4 Flash（vllm-ascend 官方 W8A8） | 8×64GB 设备起 | ❌ 非 Strata 路线 | 需 800I A3 服务器 |

（Qwen3.8-Flash-Next 打包尺寸来自 Strata `docs/MODELS.md` 官方数据；第二 shard
29GB 查找表留在 SSD。）

## 阶段计划

### Phase 0 · 环境与基线（0.5~1 天，先做这个）

1. 主机上装 CANN 工具链开发组件（ascend-toolkit 已有；确认 `libascendcl`/头文件齐全）
2. 上游 llama.cpp 构建 ggml-cann 基线：
   ```bash
   git clone https://github.com/ggml-org/llama.cpp
   cd llama.cpp && cmake -B build -DGGML_CANN=1 && cmake --build build -j
   ./build/bin/llama-cli -m <GGUF> -p "测试"   # NPU 是否被枚举：看日志 backend 列表
   ```
   - 通过 → 路径 C 直接可用（不依赖 Strata），同时证明 CANN 后端在这台 910C 上工作
   - 失败 → 记录报错（大概率 CANN/torch_npu 版本配对问题），回到版本矩阵排查
3. Strata 的 GGUF 链路确认：`engine/third_party/strata-llama` 的 `UPSTREAM.md`
   记录了 vendored 来源与版本——核对它相对上游的偏移量

### Phase 1 · 路径 A：给 Strata 打开 GGML_CANN（1~3 天）

**激活脚本已就绪**：`scripts/enable_ggml_cann.sh`（三个子命令，幂等）：

```bash
bash scripts/enable_ggml_cann.sh baseline   # Phase 0 基线：上游 llama.cpp -DGGML_CANN=1 构建验证
bash scripts/enable_ggml_cann.sh patch      # Phase 1: 按 pin 恢复内嵌树缺失的 ggml-cann 实现 + CMake 开关
bash scripts/enable_ggml_cann.sh build      # Phase 1 验证：补丁后单独构建 ggml（CANN 后端）
```

源码勘察补充（2026-11-19，脚本依据）：
- vendored 树 **`ggml/include/ggml-cann.h` 已存在**（include 目录整份保留），仅
  `ggml/src/ggml-cann/` 实现目录与 CMake 开关被 vendoring 裁剪——脚本按 UPSTREAM.md
  记录的 pin（`3cf03257f219…`）从上游精确恢复实现，CMake 开关以自包含块注入文件尾
- 注意内嵌树有**两份 ggml**：`strata-ggml`（引擎精简版，专家行跑 ggml-cpu NEON）与
  `strata-llama`（完整上游布局，vision 用）——本脚本恢复的是 strata-llama 这份；
  引擎专家行的 NPU 化（strata-ggml + 引擎接线）属 Phase 3 深水区
- 原计划的步骤细化：
  1. patch 恢复实现 + 开关（脚本自动）
  2. build 验证 libcann 后端产物
  3. 引擎 `core/device.hpp` 抽象面加 CANN 枚举分支（`strata-device --list-devices`）
     ——人工小改
  4. 验收：Qwen3.6-35B-A3B Q4 跑通 + tok/s 对比纯 CPU

### Phase 2 · 路径 C：DeepSeek V4.1 Flash GGUF 实测（1~2 天，与 Phase 1 并行）

1. llama.cpp 需 ≥ b11870（V4.1 Flash 图支持已并入）——Phase 0 的基线版本要够新
2. 下载 [unsloth UD-IQ1_S](https://huggingface.co/unsloth/DeepSeek-V4.1-Flash-1017-GGUF)
   （233GB，跨两块 EVS 盘 + 软链接组分片）
3. mmap 加载（ggml 默认）→ 实测 tok/s；engram 表选 IQ4_NL 档（110GB，盘上）
4. **预期管理**：专家层大概率 CPU/CANN 混合，1~5 tok/s 量级——"能用"和"好用"之间
   还差硬件

### Phase 3 · 路径 B：自有引擎的昇腾化（月级，团队工程）

仅当 Phase 1/2 证明这台机器值得投入后启动：

1. 仿照 SYCL 后端的产生方式：SYCL 是 Intel **dpct 从 CUDA 自动迁移**的（引擎内
   `dpct/device.hpp` 为证）——昇腾侧没有等价 dpct，需人工 Ascend C 重写热算子：
   MoE 路由 / grouped GEMM / attention / KV 管理四组（对应
   `engine/src/kernels/cuda/` 的 419 文件中的热点子集）
2. `core/device.hpp` 抽象面扩展：`DeviceInfo`/`device_count`/`set_primary_device`
   增加 CANN 分支（aclrtGetDeviceCount / aclrtGetMemInfo / ACL_VISIBLE_DEVICES）
3. DeviceArena（单次 cudaMalloc + bump 分配的内存计划器）→ aclrtMalloc 对等实现
4. 里程碑：Qwen3.8-Flash-Next IQ3_S（54.8GB）在 NPU+RAM 分层下跑通
5. 投入估算：熟悉 Ascend C 的工程师 1~2 人月；无经验则先做 Phase 1/2 再评估

## 风险与未验证项

- ggml-cann 对 **aarch64 + CANN 9.0.0** 的组合：上游 CI 覆盖的 CANN 版本需核对；
  CANN 9.0 较新，若算子缺口需提 issue 给 Ascend 社区（ggml-cann 有官方维护者）
- llama.cpp 对 **V4.1 Flash 图**的支持（b11870+）在 ggml-cann 后端下的算子覆盖率
  未验证——部分算子可能回落 CPU
- Strata 引擎层（非 ggml）的 Qwen3.8-Flash-Next 只有 CUDA 实现；SYCL 由 dpct 自动
  生成，昇腾无等价自动工具 → 路径 B 无法捷径
- 本文档所有性能数字均为预估，**真机未验证**（代理无昇腾执行环境）

## 与本仓库其他路线的关系

- vllm-ascend 官方路线（DeepSeek-V4-Flash W8A8）需要 8×64GB 设备起——**服务器级**，
  与本文的单卡 910C 路线互补不冲突
- Qwen3.8-27B vllm-ascend 部署（另一文档议题）与本路线同机互斥使用 NPU，注意显存
  分时；LLM 服务化推荐 vllm 路线（并发/批处理），Strata 路线优势是本地单会话体验
