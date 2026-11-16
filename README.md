<div align="center">

# 🖼️ MiniMax-H3-Image · 昇腾 NPU 本地部署（910B 真机实测）

**在华为昇腾 NPU 上用 ComfyUI 本地跑 MiniMax-H3-Image 文生图**
6 步蒸馏采样 · 最高 16MP · 多参考图编辑 · 全程离线 · 免费无限量

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Ascend NPU](https://img.shields.io/badge/Platform-Ascend_NPU-c8102e)]()
[![ComfyUI: v0.45.4](https://img.shields.io/badge/ComfyUI-v0.45.4-blue)]()
[![Tested: 910B 2×64G](https://img.shields.io/badge/Tested-910B_2%C3%9764G-green)]()

**中文** ｜ [English](#english)

</div>

> **🔥 一句话卖点**：官方与社区资料几乎全是 N 卡路线，H3-Image 的原生节点需要 ComfyUI ≥ 0.45，
> 而昇腾环境的 ComfyUI 普遍停留在 0.32 视频版——本仓库给出**已验证的 0.45.4 副本共存方案**：
> 主服务（视频）零改动，副本跑文生图，**文字→图片一条命令出图**。
>
> **姊妹项目**：
> - 视频版（fl2va / ref2va / i2v，910B 真机实测）→ [minimax-h3-ascend-uncensored](https://gitcode.com/sazhihou/minimax-h3-ascend-uncensored)
> - NVIDIA 路线 → [minimax-h3-nvidia-uncensored](https://gitcode.com/nxxwjbl/minimax-h3-nvidia-uncensored)

---

## 📑 目录

- [这是什么](#这是什么)
- [实测环境与结果](#实测环境与结果)
- [快速开始（三步）](#快速开始三步)
- [模型清单](#模型清单)
- [两大兼容性坑与修复](#两大兼容性坑与修复)
- [文生图工作流](#文生图工作流)
- [与其他服务的共存](#与其他服务的共存)
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
| 与视频版主服务共存 | ✅ 8188 视频 / 8189 文生图，互不干扰 |
| 多参考图编辑 | ⏳ 节点已具备（MiniMaxH3ImageConditioning 支持最多 100 张参考图），待实测 |
| 潜空间放大（MiniMaxH3LatentUpscaleWithModel） | ⏳ 节点已具备，待实测 |

## 实测环境与结果

| 项 | 值 |
|---|---|
| NPU | 昇腾 910B ×2（2×64GB HBM） |
| CANN / torch_npu | CANNLab 镜像自带（`docs/ENVIRONMENT-910B.txt` 有版本快照） |
| ComfyUI | v0.45.4（worktree 副本，主服务 0.32 零改动） |
| 模型 | Comfy-Org/MiniMax-H3-Image 官方重打包版（convrot INT8） |
| 首次加载 | DiT 19.5GB + TE 25.3GB ≈ 45GB 权重 |
| 出图速度 | 6 步采样，2048×1152 秒级出片（首次运行含权重加载，之后热机更快） |
| 下载 | hf-mirror 直连，实测 ~20MB/s，46GB 约 40 分钟 |

## 快速开始（三步）

```bash
# ① 部署 ComfyUI v0.45.4 副本（自动建 venv、打兼容性补丁）
bash scripts/setup_image.sh

# ② 下载模型（46GB，支持断点续传）
bash scripts/download_models_image.sh

# ③ 启动 + 一键文生图
bash scripts/start_comfyui_image.sh
bash scripts/test_t2i.sh
```

看到 `DONE /h3image_t2i_00001_.png` 即为成功；产物在副本 `output/` 目录。
浏览器访问 `http://<机器IP>:8189` 也可手动操作（左侧队列历史可查历史出图）。

> **已有一条 0.32 视频版主服务？** 直接跑上面三步即可，主服务（端口 8188）零改动。
> 还没有 ComfyUI？`setup_image.sh` 会自动浅克隆官方仓库再建副本。

## 模型清单

全部来自 **Comfy-Org/MiniMax-H3-Image 官方重打包版**（[HuggingFace](https://huggingface.co/Comfy-Org/MiniMax-H3-Image)），
脚本默认走 [hf-mirror.com](https://hf-mirror.com) 国内直连：

| 文件 | 大小 | 放置目录 | 说明 |
|---|---|---|---|
| `minimax_h3_image_pruned_int8_convrot.safetensors` | 19.54 GB | `models/diffusion_models/` | DiT 主模型（INT8 convrot，实测可跑） |
| `qwen3vl_32b_minimax_h3_int8_convrot.safetensors` | 25.28 GB | `models/text_encoders/official/` | **必须官方版**（见下方坑 ①），子目录随意但工作流里要带前缀 |
| `minimax_h3_image_vae_fp16.safetensors` | 1.09 GB | `models/vae/` | image VAE |

> **重要**：`text_encoders/official/` 里的 TE **只给 0.45 副本用**。
> 0.32 视频主服务用的是另一份（昇腾视频仓库版）`qwen3vl_32b_minimax_h3_int8_convrot.safetensors`
> （直接放 `models/text_encoders/` 根目录），两者同名不同内容、互不干扰。

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
  （`setup_image.sh` 已自动完成）：

  ```python
  def cast_weight(self, input):
      if isinstance(input, torch.device):
          return None          # torch_npu .to() hook 传入的是设备对象，直接跳过
      return CastBiasWeightContext(...)
  ```

- **影响面**：只动副本（`ComfyUI-045/comfy/ops.py`），主服务零改动；
  forward 正常路径传入张量，行为不变

更多过程记录（软链坑 / venv 升级 torch 风险 / hf-mirror 429 等）见
[docs/踩坑记录-image.md](docs/踩坑记录-image.md)。

## 文生图工作流

`workflows/` 提供两份等价工作流：

| 文件 | 形态 | 用法 |
|---|---|---|
| `image_minimax_h3_t2i.json` | UI 格式（官方模板，subgraph 封装） | 浏览器里 Workflows → Open 直接加载，改提示词点 Queue |
| `minimax_h3_image_t2i_api.json` | API 格式（`/prompt` 直用） | `curl -X POST http://127.0.0.1:8189/prompt -d @...`，或用 `scripts/test_t2i.sh` |

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

## 与其他服务的共存

| 服务 | 端口 | 目录 | ComfyUI | 用途 |
|---|---|---|---|---|
| 视频主服务 | 8188 | `/mnt/workspace/ComfyUI` | 0.32 + 昇腾补丁 | fl2va / ref2va / i2v |
| **本仓库副本** | **8189** | `/mnt/workspace/ComfyUI-045` | **0.45.4** | **H3-Image 文生图** |

两者共享 `models/`（软链），模型文件互不覆盖（TE 官方版在 `official/` 子目录）。
视频主服务需要 Python 依赖时用系统环境；副本一律走 venv。

## 常见问题

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
从低分辨率 latent 放大，或用 `--lowvram` 启动。

**Q：下载报 429 / 卡在某个文件？**
hf-mirror 是共享配额，被限流时稍等重跑 `download_models_image.sh`（自动断点续传）。

---

<a id="english"></a>

## English

**MiniMax-H3-Image (text-to-image, 6-step distilled sampling, up to 16MP) running fully
offline on Huawei Ascend 910B NPUs via ComfyUI v0.45.4.**

This repo packages a verified deployment path that **coexists with an existing ComfyUI 0.32
video service**: the main service stays untouched while a git-worktree replica at v0.45.4
serves H3-Image text-to-image on port 8189.

Three steps:

```bash
bash scripts/setup_image.sh           # deploy v0.45.4 replica + venv + compat patches
bash scripts/download_models_image.sh # 46GB of official Comfy-Org weights (resumable)
bash scripts/start_comfyui_image.sh   # start on port 8189
bash scripts/test_t2i.sh              # one-shot text-to-image smoke test
```

Two Ascend-specific pitfalls are documented and auto-patched: text-encoder weights must be
the official Comfy-Org build (layer_conf JSON compatibility), and a `cast_weight` device
guard is required because torch_npu hijacks `nn.Module.to()` and calls the hook with a
`torch.device`. See the Chinese sections above for details.
