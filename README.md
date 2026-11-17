<div align="center">

# 🖼️ MiniMax-H3-Image · 昇腾 NPU 本地部署（910B 真机实测）

**在华为昇腾 NPU 上用 ComfyUI v0.45.4 统一单服务本地跑 MiniMax-H3 文生图**
6 步蒸馏采样 · 最高 16MP · 多参考图编辑 · 全程离线 · 免费无限量

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Ascend NPU](https://img.shields.io/badge/Platform-Ascend_NPU-c8102e)]()
[![ComfyUI: v0.45.4 统一单服务](https://img.shields.io/badge/ComfyUI-v0.45.4_统一单服务-blue)]()
[![Tested: 910B 2×64G](https://img.shields.io/badge/Tested-910B_2%C3%9764G-green)]()

**中文** ｜ [English](#english)

</div>

> **🔥 一句话卖点**：官方与社区资料几乎全是 N 卡路线，H3-Image 的原生节点需要 ComfyUI ≥ 0.45，
> 而昇腾环境的 ComfyUI 普遍停留在 0.32 视频版——本仓库给出**统一 v0.45.4 单服务方案**：
> 主目录直接升级，一条命令出图；不再维护 "0.32 主服务 + 0.45 副本" 双服务结构。
>
> **姊妹项目**：
> - 视频版（fl2va / ref2va / i2v，0.32 口径 910B 真机实测）→ [minimax-h3-ascend-uncensored](https://gitcode.com/sazhihou/minimax-h3-ascend-uncensored)
> - NVIDIA 路线 → [minimax-h3-nvidia-uncensored](https://gitcode.com/nxxwjbl/minimax-h3-nvidia-uncensored)

---

## 📑 目录

- [这是什么](#这是什么)
- [实测环境与结果](#实测环境与结果)
- [全新主机部署（三步）](#全新主机部署三步)
- [从 0.32 双服务升级（迁移说明）](#从-032-双服务升级迁移说明)
- [重新部署（推倒重来）](#重新部署推倒重来)
- [模型清单](#模型清单)
- [两大兼容性坑与修复](#两大兼容性坑与修复)
- [文生图工作流](#文生图工作流)
- [常见问题](#常见问题)

---

## 这是什么

[MiniMax-H3-Image](https://huggingface.co/MiniMaxAI/MiniMax-H3-Image) 是 MiniMax 开源的图像生成模型
（文生图 + 多参考图编辑，最高 16MP，蒸馏后 **6 步采样**）。ComfyUI 从 **v0.45.0** 起原生支持
（[官方教程](https://docs.comfy.org/tutorials/image/minimax/minimax-h3-image)），但官方只给了
NVIDIA 路线——本仓库把这套东西搬上昇腾：

| 能力 | 状态 |
|---|---|
| 文生图（6 步蒸馏采样） | ✅ 910B 2×64G 真机跑通 |
| 2048×1152 出图 | ✅ 实测出片（见 [assets/demo_t2i.png](assets/demo_t2i.png)） |
| convrot INT8 量化权重直跑 | ✅ 无需 bf16（省一半下载量） |
| 统一 v0.45.4 单服务（8188 端口） | ✅ 主目录直接升级，告别双服务共存 |
| 多参考图编辑 | ⏳ 节点已具备（MiniMaxH3ImageConditioning 支持最多 100 张参考图），待实测 |
| 潜空间放大（MiniMaxH3LatentUpscaleWithModel） | ⏳ 节点已具备，待实测 |
| 图生视频（fl2va / ref2va） | ⏳ 全套模型可下载；0.32 昇腾视频补丁与 Turbo 节点在 0.45 下**未验证** |

## 实测环境与结果

| 项 | 值 |
|---|---|
| NPU | 昇腾 910B ×2（2×64GB HBM） |
| CANN / torch_npu | CANNLab 镜像自带（`docs/ENVIRONMENT-910B.txt` 有版本快照） |
| ComfyUI | v0.45.4（统一单服务；出图链路在 0.45.4 真机实测通过，统一部署口径变更后待复验） |
| 模型 | Comfy-Org/MiniMax-H3-Image 官方重打包版（convrot INT8） |
| 首次加载 | DiT 19.5GB + TE 25.3GB ≈ 45GB 权重 |
| 出图速度 | 6 步采样，2048×1152 秒级出片（首次运行含权重加载，之后热机更快） |
| 下载 | hf-mirror 直连，实测 ~20MB/s，46GB 约 40 分钟 |

## 全新主机部署（三步）

### 前提自查（缺一不可）

CANNLab / 昇腾官方镜像一般开箱即满足；自备主机先跑一遍下面的自查命令：

| 项 | 要求 | 自查命令 |
|---|---|---|
| 硬件 | 昇腾 NPU（910B 实测；910B3 / 910C 理论可行，未验证） | `ls /dev/davinci*` 能看到设备 |
| CANN | ascend-toolkit 已安装（含 `set_env.sh`） | `ls /usr/local/Ascend/ascend-toolkit/set_env.sh ~/Ascend/ascend-toolkit/set_env.sh` 二者有其一 |
| torch / torch_npu | **系统** Python 已装且与 CANN 版本匹配（脚本全程不动它们） | `python3 -c "import torch, torch_npu"` 无报错 |
| 磁盘 | 模型下载：文生图 46GB，含图生视频全家桶约 108GB；建议 ≥150GB 空闲 | `df -h /mnt/workspace` |
| 工具 | git / curl / python3 ≥ 3.10 | `git --version && curl --version && python3 -V` |

> CANN 与 torch_npu 的安装不在本仓库范围内，参考华为 Ascend 官方
> [CANN 安装指南](https://www.hiascend.com/document)装好后重跑自查。
> 实测环境快照（CANN 9.0.0 / torch 2.7.1 / torch_npu 2.7.1.post4 / Python 3.11）见
> [docs/ENVIRONMENT-910B.txt](docs/ENVIRONMENT-910B.txt)。

### 三步部署

> **⚠️ 下载量提醒（开跑前必读）**
> 第 ② 步合计下载约 **108GB**（文生图 46GB + 图生视频 62GB）：
> - **耗时预期**：默认用**分片并行下载器**（视频版同款引擎，32 连接/文件 × 2 文件并行）实测聚合 **~40MB/s，全家桶约 45 分钟**；环境缺 python3/requests 时自动回退单连接 curl（~20MB/s，约 1.5~2 小时）
> - **高峰期可能 429 限流**：稍等重跑即可，**断点续传**不会从头再来
> - **先确认磁盘**：`df -h /mnt/workspace` 余量 ≥ 150GB（脚本启动时也会自动检查并警告）
> - **建议放 `tmux`/`screen` 里跑**：SSH 断线、合盖都不中断
> - **只想先出图？** 跳过 `download_models_image.sh video` 那条命令，46GB 约 20 分钟即可开跑文生图；视频模型随时补下
> - 并发可调：`MAX_CONN=48`（每文件连接数）/ `FILES_PARALLEL=3`（并行文件数）

```bash
# ① 取本仓库
git clone https://github.com/gwqwy/minimax-h3-image-ascend-uncensored.git
cd minimax-h3-image-ascend-uncensored

# ② 一键部署 + 下载模型（断点续传）
#    部署：ComfyUI 直拉 v0.45.4 + 独立 venv + 兼容性补丁 + 文生图三件套（46GB）
bash setup.sh                    # 模型已就位时: bash setup.sh --skip-models
#    图生视频模型（Comfy-Org/MiniMax-H3 全家桶 62GB：fl2va 完整版/ref2va + 视频/音频 VAE）
bash scripts/download_models_image.sh video
#    可选档位：
#      LOWVRAM=1 bash scripts/download_models_image.sh video   # 低配档：pruned fl2va 21GB（32GB 卡）
#      WITH_LORA=1 ... video                                    # 追加 Turbo 加速 LoRA（+5.5GB）
#      WITH_HERETIC_TE=1 bash scripts/download_models_image.sh all   # 追加无审查 TE（+26.4GB，0.45 兼容性未验证）

# ③ 启动 + 一键文生图
bash scripts/start_comfyui.sh
bash scripts/test_t2i.sh
```

看到 `DONE /h3image_t2i_00001_.png` 即为成功；产物在主目录 `output/`。
浏览器访问 `http://<机器IP>:8188` 也可手动操作（左侧队列历史可查历史出图）。

### 默认路径与可调项

| 项 | 默认值 | 覆盖方式 |
|---|---|---|
| 工作区根 | `/mnt/workspace`（ComfyUI 装在 `$COMFY_BASE/ComfyUI`） | `COMFY_BASE=/your/path bash setup.sh` |
| venv | `$COMFY_BASE/runtime/venv045`（复用系统 torch_npu） | `COMFY_VENV=... bash setup.sh` |
| 服务端口 | `8188` | `COMFYUI_PORT=8090 bash scripts/start_comfyui.sh` |
| NPU 卡 | 自动识别全部 | `NPU_DEVICES=0,1 bash scripts/start_comfyui.sh` |
| 模型目录 | `$COMFY_BASE/ComfyUI/models` | `COMFY_MODELS=... bash scripts/download_models_image.sh` |

> **ComfyUI 不需要单独装**：`setup_image.sh` 在目标机器无 ComfyUI 时会
> `git clone --depth 1 --branch v0.45.4` **直接拉取 v0.45.4**（`--branch` 支持 tag，
> 一步到位）；已有 0.32 旧仓的机器则自动走备份升级流程，见下节。
> 图生视频模型已含在第 ② 步（两条下载命令都可单独重跑，断点续传；视频模型的官方 TE
> 与文生图共用同一份，第 ② 步 `setup.sh` 已先就位）；
> ⚠️ 视频链路在 v0.45.4 下**未验证**，模型先行就位，更多可选档位见[模型清单](#模型清单)。
>
> 首次出图前要加载约 45GB 权重，耐心等 `test_t2i.sh` 轮询（约 15 分钟上限）；
> 之后热机秒级出片。下载或出图报错先看 [docs/踩坑记录-image.md](docs/踩坑记录-image.md)。

## 从 0.32 双服务升级（迁移说明）

此前方案是 "0.32 视频主服务（8188）+ 0.45.4 worktree 副本（8189）" 共存；现已统一为
**主目录 `/mnt/workspace/ComfyUI` 直接升级 v0.45.4、单端口 8188 单服务**：

- **升级前自动备份**：主目录的本地改动（0.32 昇腾补丁等 tracked 改动）会备份到
  `/mnt/workspace/runtime/upgrade-backup-<时间戳>/`（`previous-head.txt` + `local-changes.patch`），
  按脚本输出的回滚命令可随时退回 0.32；模型权重是 untracked 文件，不受升级影响。
- **端口合并**：8188 由 v0.45.4 服务接管，`start_comfyui.sh` 启动时会先停掉旧 PID
  （即原 0.32 视频服务）。
- **启动脚本合并**：`scripts/start_comfyui_image.sh` 已删除，统一用 `scripts/start_comfyui.sh`
  （venv PATH 前置、不带 `--cache-classic`）。
- **旧副本清理**：`ComfyUI-045` 副本不再需要，统一服务验证通过后执行
  `git -C /mnt/workspace/ComfyUI worktree remove --force /mnt/workspace/ComfyUI-045` 清理。
- **custom_nodes 兼容**：旧主服务的 custom_nodes（0.32 时代昇腾/Turbo 插件）在 0.45 下可能
  导入失败，ComfyUI 会自动跳过；确认不需要可手动移除。
- **代价（未验证项）**：0.32 昇腾视频适配补丁（comfy-ui-changes.patch）不再随主服务生效，
  视频链路在 v0.45.4 下未验证（模型可先下载）。需要 0.32 口径视频服务时，用姊妹仓库
  [minimax-h3-ascend-uncensored](https://gitcode.com/sazhihou/minimax-h3-ascend-uncensored)
  或按升级备份回滚。

## 重新部署（推倒重来）

老目录状态太乱（0.32 残留插件、改坏的本地改动、莫名的启动问题）不想原地升级？
`REDEPLOY=1` 一条命令推倒重来，**模型不会重新下载**：

```bash
REDEPLOY=1 bash setup.sh --skip-models
```

脚本会依次：

1. 停掉所有在跑的 ComfyUI 服务（读 PID 文件）
2. 旧主目录**整体挪走留档**为 `/mnt/workspace/ComfyUI-old-<时间戳>`（同盘改名，瞬间完成）
3. 全新克隆 ComfyUI v0.45.4 到 `/mnt/workspace/ComfyUI`
4. **`models/`、`output/`、`user/`（自存工作流）自动迁回**新目录；`custom_nodes` **不迁回**
   （0.32 时代插件与 0.45 不兼容，确需某个插件从留档目录手动挑）
5. 建/复用 venv → 装依赖（过滤 torch 系）→ 打 cast_weight 兼容补丁

收尾：

```bash
bash scripts/start_comfyui.sh && bash scripts/test_t2i.sh   # 验证
# 验证通过后回收空间（旧目录 + 旧双服务副本）：
rm -rf /mnt/workspace/ComfyUI-old-<时间戳>
rm -rf /mnt/workspace/ComfyUI-045   # 若存在（旧 worktree 副本）
```

> 想连 venv 也全新：`REDEPLOY=1 COMFY_VENV=/mnt/workspace/runtime/venv045-new bash setup.sh --skip-models`，
> 验证通过后把启动脚本的 `COMFY_VENV` 指到新路径再删旧 venv。

## 模型清单

下载地址与视频版仓库（[sazhihou/minimax-h3-ascend-uncensored](https://gitcode.com/sazhihou/minimax-h3-ascend-uncensored)
的 `scripts/dl_models.py`）保持一致，下载引擎也移植自它（`scripts/dl_models_fast.py`，
分片并行实测聚合 ~40MB/s；`MAX_CONN` / `FILES_PARALLEL` 可调并发）。官方档来自 Comfy-Org
重打包版（文生图 [H3-Image](https://huggingface.co/Comfy-Org/MiniMax-H3-Image)，
图生视频 [H3](https://huggingface.co/Comfy-Org/MiniMax-H3)），脚本默认走
[hf-mirror.com](https://hf-mirror.com) 国内直连。下载档位：

```bash
bash scripts/download_models_image.sh image     # 只文生图（46GB，setup.sh 默认档）
bash scripts/download_models_image.sh video     # 只图生视频（62GB，默认完整版 fl2va）
LOWVRAM=1 bash scripts/download_models_image.sh video    # 视频段低配档：pruned fl2va 21GB 替代完整版
bash scripts/download_models_image.sh           # 全部（约 108GB）
WITH_LORA=1 bash scripts/download_models_image.sh video      # 视频段 + Turbo 加速 LoRA（+5.5GB）
WITH_HERETIC_TE=1 bash scripts/download_models_image.sh all  # 额外无审查 heretic TE（+26.4GB）
```

文生图三件套（必下）：

| 文件 | 大小 | 放置目录 | 说明 |
|---|---|---|---|
| `minimax_h3_image_pruned_int8_convrot.safetensors` | 19.54 GB | `models/diffusion_models/` | DiT 主模型（INT8 convrot，实测可跑） |
| `qwen3vl_32b_minimax_h3_int8_convrot.safetensors` | 25.28 GB | `models/text_encoders/official/` | **必须官方版**（见坑 ①），文生图/图生视频共用 |
| `minimax_h3_image_vae_fp16.safetensors` | 1.09 GB | `models/vae/` | image VAE |

图生视频模型（可选，⚠️ 0.45 下视频链路未验证）：

| 文件 | 大小 | 放置目录 |
|---|---|---|
| `minimax_h3_fl2va_int8_convrot.safetensors` | 34 GB | `models/diffusion_models/`（完整版，默认） |
| `minimax_h3_fl2va_pruned_int8_convrot.safetensors` | 19.53 GB | `models/diffusion_models/`（`LOWVRAM=1` 低配档） |
| `minimax_h3_ref2va_pruned_int8_convrot.safetensors` | 19.53 GB | `models/diffusion_models/` |
| `minimax_h3_video_vae_fp16.safetensors` | 4.85 GB | `models/vae/` |
| `minimax_h3_video_vae_int8_convrot.safetensors` | ~3 GB | `models/vae/`（32GB 低配档工作流用） |
| `minimax_h3_audio_vae_fp32.safetensors` | 0.56 GB | `models/vae/` |

Turbo 加速 LoRA（可选，4/8 步出片，`WITH_LORA=1` 时下载）：`loras/` 下三个 1.82GB 文件。

无审查 heretic TE（可选，`WITH_HERETIC_TE=1` 时下载，与视频版仓库同地址）：

| 文件 | 大小 | 放置目录 |
|---|---|---|
| `qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors` | 26.4 GB | `models/text_encoders/`（根目录） |

> **重要**：官方 TE 必须放 `official/` 子目录（坑 ①）；单独只下 `video` 档时 TE 不会
> 重复下载，请确保 `image` 档的官方 TE 已就位。工作流里引用官方 TE 要带子目录前缀：
> `official/qwen3vl_32b_minimax_h3_int8_convrot.safetensors`。
> heretic TE 属**非官方渠道** convrot 档，放根目录且与官方档同名不同物；其 layer_conf 与
> 0.45 官方加载器的兼容性**未验证**（大概率踩坑 ①），故本仓库默认不下载（视频版仓库默认下载、
> 配 0.32 服务使用），`WITH_HERETIC_TE=1` 可先囤权重。

## 两大兼容性坑与修复

### 坑 ①：文本编码器 layer_conf 不兼容（JSONDecodeError）

- **现象**：`CLIPLoader` 加载 TE 时报
  `json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)`
- **根因**：非官方渠道的 qwen3vl convrot 权重内嵌的 `layer_conf` 量化配置结构与
  ComfyUI 0.45 官方加载器（`comfy/ops.py::_load_quantized_module`）不一致
- **修复**：**用官方版 TE，放 `official/` 子目录**（下载脚本已自动处理）
- **教训**：文件名相同 ≠ 内容相同。出这种错先对比文件 metadata（`__metadata__` 键集）：
  官方版带 `config` 等键，旧档只有 `minimax_h3_te` 一个键

### 坑 ②：torch_npu 劫持 `.to()` 导致 cast_weight 崩溃（AttributeError）

- **现象**：KSampler 阶段报
  `AttributeError: 'torch.device' object has no attribute 'dtype'`
- **根因**：torch_npu 劫持 `nn.Module.to()`，权重搬运时会以 `(device)` 为参调用模块的
  `cast_weight` 钩子；ComfyUI 0.45 的实现直接取 `input.dtype`，而 `torch.device` 没有 `.dtype`
- **修复**：给 `comfy/ops.py` 里所有 `def cast_weight(self, input):` 加 device 守卫
  （`setup_image.sh` 已自动完成，现打在主目录）：

  ```python
  def cast_weight(self, input):
      if isinstance(input, torch.device):
          return None          # torch_npu .to() hook 传入的是设备对象，直接跳过
      return CastBiasWeightContext(...)
  ```

- **影响面**：只动 `comfy/ops.py` 的钩子路径；forward 正常路径传入张量，行为不变

更多过程记录（venv 升级 torch 风险 / 软链坑 / hf-mirror 429 等）见
[docs/踩坑记录-image.md](docs/踩坑记录-image.md)。

## 文生图工作流

`workflows/` 提供两份等价工作流：

| 文件 | 形态 | 用法 |
|---|---|---|
| `image_minimax_h3_t2i.json` | UI 格式（官方模板，subgraph 封装） | 浏览器里 Workflows → Open 直接加载，改提示词点 Queue |
| `minimax_h3_image_t2i_api.json` | API 格式（`/prompt` 直用） | `curl -X POST http://127.0.0.1:8188/prompt -d @...`，或用 `scripts/test_t2i.sh` |

节点链（API 版）：

```
UNETLoader(convrot DiT) ─┐
CLIPLoader(官方TE, minimax) ── MiniMaxH3ImageConditioning ──┬─ positive ─┐
                              └─ (内置 LATENT 输出) ────────┴─ latent ───┤
ConditioningZeroOut ── negative ─────────────────────────────────────────┤
                                        KSampler(6步, euler/simple, cfg=1)┘
                                              ↓
                              VAEDecode → SaveImage
```

> `MiniMaxH3ImageConditioning` 是**双输出节点**（CONDITIONING + 内置 LATENT），
> 官方调优区域为 2048×2048（4MP）；自定义尺寸要求宽×高在 0.65MP~20MP、宽高比 ≤3:1、边长 16 的倍数。

## 常见问题

**Q：为什么从 "副本共存" 改成统一升级？**
双服务要维护两份 ComfyUI、两套补丁口径和两个端口；统一后只维护一份 v0.45.4，
部署/启动/测试脚本各一份。代价是 0.32 视频补丁不再生效（见迁移说明）。

**Q：统一到 0.45 后，视频（fl2va / ref2va）还能跑吗？**
模型可以先用 `download_models_image.sh video` 下载，但 0.32 昇腾视频适配补丁与 Turbo
采样节点尚未在 v0.45.4 上验证，视频链路暂按不可用处理。需要 0.32 口径视频服务时用
姊妹仓库的部署方案，或按升级备份回滚。

**Q：无审查（uncensored）怎么开？**
社区 heretic TE 就是无审查文本编码器：`WITH_HERETIC_TE=1` 下载（26.4GB，放
`text_encoders/` 根目录）。注意它是非官方渠道 convrot 档，0.45 官方加载器兼容性未验证
（可能踩坑 ①）——可先囤权重，真机验证通过后再改工作流引用；0.32 口径视频服务可直接用。

**Q：为什么不用 bf16 版（37.5GB）？**
convrot INT8 版官方教程同样推荐，实测 NPU 直跑没问题，下载量省一半。追求极致画质可自行换 bf16
（`UNETLoader` 里选对应文件即可），节点链不变。

**Q：为什么必须 v0.45+？**
H3-Image 原生节点（`MiniMaxH3ImageConditioning` 等）在 v0.45.0 才进入 ComfyUI 核心
（day-0 支持，[发布说明](https://blog.comfy.org/p/minimax-h3-image-is-now-available)）。
0.32 及以下没有这些节点，也没有 convrot INT8 加载支持。

**Q：`MinimaxH3ImageNode` 这个节点是什么？**
那是调 MiniMax 云端 API 的 Partner 节点（需要 API key），**不是本地模型**——本地文生图请用
上面节点链里的原生节点组合。

**Q：显存不够 / 16MP 直出？**
2×64GB 起步即可跑 2MP 档；16MP（4096×4096）建议先用 `MiniMaxH3LatentUpscaleWithModel`
从低分辨率 latent 放大，或用 `LOWVRAM=1 bash scripts/start_comfyui.sh`（`--lowvram`）启动。

**Q：下载报 429 / 卡在某个文件？**
hf-mirror 是共享配额，被限流时稍等重跑 `download_models_image.sh`（自动断点续传）。

---

<a id="english"></a>

## English

**MiniMax-H3-Image (text-to-image, 6-step distilled sampling, up to 16MP) running fully
offline on Huawei Ascend 910B NPUs via a single unified ComfyUI v0.45.4 service (port 8188).**

This repo packages a verified text-to-image path for Ascend. The deployment has been **unified**:
instead of the earlier "0.32 video main service + 0.45.4 worktree replica" coexistence, the main
ComfyUI checkout (`/mnt/workspace/ComfyUI`) is upgraded in place to v0.45.4 — local changes are
auto-backed-up before the upgrade with a documented rollback, and a single service now serves
both text-to-image (verified) and video models (download supported, pipeline on 0.45 unverified).

Three steps:

Prerequisites: an Ascend NPU host (910B tested) with CANN toolkit plus a system-wide
torch/torch_npu matching it (the scripts never touch torch), ≥100GB free disk, git/curl/python≥3.10.
See the Chinese "全新主机部署" section above for one-line self-checks and the full walkthrough.

```bash
git clone https://github.com/gwqwy/minimax-h3-image-ascend-uncensored.git
cd minimax-h3-image-ascend-uncensored

bash setup.sh                               # deploy + t2i weights (46GB): clones ComfyUI v0.45.4
                                            # directly (--branch tag clone), builds a venv that reuses the
                                            # system torch_npu, patches comfy/ops.py
bash scripts/download_models_image.sh video # i2v models (62GB): fl2va/ref2va + video/audio VAEs
                                            # (LOWVRAM=1 pruned fl2va; WITH_LORA=1 Turbo LoRAs; WITH_HERETIC_TE=1
                                            #  uncensored TE — 0.45 compatibility unverified)

bash scripts/start_comfyui.sh               # single service on port 8188
bash scripts/test_t2i.sh                    # one-shot text-to-image smoke test
```

Heads-up: the two download commands fetch ~108GB total (46GB t2i + 62GB i2v). The default
downloader is a sharded parallel engine (ported from the video repo, 32 connections/file ×
2 files) measuring **~40MB/s aggregate — full bundle in ~45min**; without python3+requests it
falls back to single-connection curl (~20MB/s, 1.5–2h). Run inside `tmux`/`screen`; on 429
rate-limit pauses just re-run (resumable). T2I-only? Skip the `video` line and you're up in
~20min. Tunables: `MAX_CONN`, `FILES_PARALLEL`. The script prints a per-run summary
(scope, total GB, free-disk check) at startup.

All downloads are resumable; other scopes: `download_models_image.sh image|video|all`.

Two Ascend-specific pitfalls are documented and auto-patched: text-encoder weights must be
the official Comfy-Org build (layer_conf JSON compatibility), and a `cast_weight` device
guard is required because torch_npu hijacks `nn.Module.to()` and calls the hook with a
`torch.device`. See the Chinese sections above for details.
