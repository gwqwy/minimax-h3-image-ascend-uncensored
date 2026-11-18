# 部署踩坑记录（H3-Image 昇腾版）

> 从零把 MiniMax-H3-Image 搬上昇腾 910B 的完整踩坑过程，按时间顺序。
> 结论已固化进 `scripts/setup_image.sh` 与 `scripts/download_models_image.sh`，这里保留过程与原理。

## 坑 0：H3-Image 需要 ComfyUI ≥ 0.45，而昇腾环境普遍是 0.32

> **【2026-11-17 口径更新】** 本坑的 worktree 副本方案已被 **"统一 v0.45.4 单服务"** 取代：
> 主目录直接升级到 v0.45.4（升级前自动备份本地改动，回滚方法见 `setup_image.sh` 输出），
> 端口合并为 8188，`start_comfyui_image.sh` 删除。代价：0.32 昇腾视频补丁与 Turbo 节点
> 不再随主服务生效，视频链路在 0.45 下未验证（模型可先行下载）。副本方案的历史记录保留如下。

- H3-Image 原生节点（`MiniMaxH3ImageConditioning` / `MiniMaxH3LatentUpscaleWithModel` 等）
  在 ComfyUI v0.45.0 进入核心（2026-11-10，day-0 支持）。
- 昇腾视频版主服务锁定 0.32 + 昇腾补丁（`comfy-ui-changes.patch` 是对着 0.32 写的），
  直接升级主服务风险极大（补丁冲突 + Turbo 插件兼容未知）。
- **解法（历史）**：git worktree 副本。`git fetch v0.45.4` → `git worktree add ComfyUI-045 v0.45.4`，
  与主服务共存，models 目录软链共享。

## 坑 1：`MinimaxH3ImageNode` 是 API 节点，别用错

- 0.45 的 `object_info` 里有个 `MinimaxH3ImageNode`，输入是 `MiniMax-H3-Image` 下拉框 +
  `auth_token_comfy_org`——那是**调 MiniMax 云端 API** 的 Partner 节点，不是本地模型。
- 本地文生图的真实节点链：`UNETLoader + CLIPLoader + VAELoader +
  MiniMaxH3ImageConditioning + KSampler + VAEDecode`。

## 坑 2：文本编码器 layer_conf 不兼容（JSONDecodeError: char 0）

- **现象**：`CLIPLoader` 报 `Expecting value: line 1 column 1 (char 0)`，traceback 落在
  `comfy/ops.py::_load_quantized_module` 的 `json.loads(layer_conf...)`。
- **排查过程**：
  1. 先怀疑文件 metadata 缺 `config` 键——读了 safetensors header，
     metadata 只有 `minimax_h3_te` 一个键（官方版应带 `config` 等），确认"文件名相同≠内容相同"。
  2. 云端已有的 qwen3vl convrot 是**视频版仓库分发过的定制档**，layer_conf 结构与
     0.45 官方加载器不兼容。
- **解法**：下载 Comfy-Org 官方版 TE，放 `text_encoders/official/` 子目录（避免与主服务的
  同名旧档冲突），工作流里 `clip_name` 带子目录前缀。
- **原理**：convrot 是量化格式，量化配置以 JSON 内嵌在权重里；不同批次/渠道的档可能
  结构有差异，官方加载器只认官方档。
- **补充教训（2026-11-17）**：`official/` 只是**本地隔离目录**，Comfy-Org/MiniMax-H3-Image
  仓内并没有这个路径（HF API 实证）——下载 URL 必须用仓内真实路径
  `text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors`，带了 `official/` 只会
  404 拿到错误页（会被大小校验拦下，但文件永远下不下来）。脚本已把仓内路径与本地路径分离。

## 坑 3：torch_npu 劫持 `.to()` → cast_weight(device) → AttributeError

- **现象**：KSampler 阶段 `AttributeError: 'torch.device' object has no attribute 'dtype'`。
- **traceback 链**：`model_patcher.load → x[2].to(device_to) →
  torch_npu/utils/_module.py::to() → self.cast_weight(device) →
  ops.py cast_weight → cast_bias_weight → input.dtype`。
- **根因**：torch_npu 的 `to()` 包装会**以设备对象为参**调用模块的 `cast_weight` 钩子
  （通知式，忽略返回值）；ComfyUI 0.45 的 `cast_weight` 假设 input 是张量，取 `input.dtype` 即崩。
- **解法**：给 `comfy/ops.py` 所有 `def cast_weight(self, input):` 加守卫：

  ```python
  if isinstance(input, torch.device):
      return None
  ```

  forward 正常路径传入张量，行为不变。已固化进 `setup_image.sh`（幂等）。

## 坑 4：venv 升级 torch 会毁掉整个昇腾环境

- ComfyUI `requirements.txt` 含 torch 系包。venv 里直接 `pip install -r requirements.txt`
  会尝试升级 torch → **torch_npu 与 torch 版本强绑定**，升级后 CANN 初始化直接失败。
- **解法**：`grep -viE '^torch' requirements.txt | pip install -r /dev/stdin`，
  torch/torch_npu 一律走系统环境（`--system-site-packages`）。
- **补充（2026-11-18 真机复现）**：`^torch` 前缀过滤**误伤 torchsde**——它是独立正经包
  （k_diffusion 采样必需），被滤掉后启动报
  `ModuleNotFoundError: No module named 'torchsde'`。过滤条件必须精确匹配包名：
  `grep -viE '^(torch|torchvision|torchaudio)(=|<|>|!|~| |$)'`。
  （0.32 视频服务当年没炸只是因为它的环境另有 torchsde 来源，不是过滤器没错。）

## 坑 5：models 软链的幂等性

- `ln -sfn` 在目标为**真实目录**时不会替换而是钻进目录里建——经典坑。
- `git worktree remove` 后重建副本，之前建的软链会随目录一起消失，ComfyUI 启动时
  自建空 `models/` 目录 → **UNETLoader/CLIPLoader 列表全空**（`value_not_in_list`）。
- **解法**：判断 `[ ! -L models ]` 再删链重建（`setup_image.sh` 已固化），而不是判断 `[ -d ]`。

## 坑 6：hf-mirror 共享配额 429

- hf-mirror 对外有全局 resolvers 配额（100000 次/5 分钟共享窗口），高峰期 `resolve/main`
  可能被 429，下载到的"文件"其实是几 KB 的限流文案。
- **解法**：下载脚本带**大小校验 + 断点续传**（`-C -`），不完整就重跑；
  大文件错峰下载（本仓库 46GB 实测约 40 分钟）。

## 坑 7：`--cache-classic` 不要带进副本

- 视频主服务启动参数里有 `--cache-classic`（H3 视频工作流同步用），0.45 副本不需要，
  语义也可能随版本变化。副本启动脚本不携带该参数。

## 坑 8：启动脚本覆盖 PATH → triton-ascend 找不到 bisheng → comfy_kitchen 导入崩溃

- **现象**：`python3 main.py` 在 `import comfy_kitchen` 阶段崩，
  `RuntimeError: 0 active drivers ([]). There should only be one.`，
  前置警告 `Couldn't find executable bisheng or TRITON_NPU_COMPILER_PATH`。
- **根因链**：ComfyUI 0.45 的 `comfy/quant_ops.py` 在**导入时**加载 comfy_kitchen；
  其 triton 后端 `quantization.py` 在模块级执行 `@triton.autotune` → 触发 triton
  驱动初始化。机器上的 triton 是 CANNLab 镜像的 triton-ascend，初始化需要 CANN 的
  bisheng 编译器（PATH 或 TRITON_NPU_COMPILER_PATH）。
- **致命一步**：启动脚本 `export PATH="$VENV/bin:/usr/...:/bin"` **整段覆盖** PATH，
  把 `set_env.sh` 刚注入的 CANN 编译器目录冲掉 → bisheng 不可见 → 0 驱动。
  0.32 视频版启动脚本没覆盖 PATH，所以它不踩。
- **解法**：改为 `export PATH="$VENV/bin:$PATH"` 前置；再加 bisheng 自动探测
  （find CANN 目录）→ `TRITON_NPU_COMPILER_PATH` 兜底。
- **真机复验（2026-11-18）**：PATH 前置后 `0 active drivers` 消失，comfy_kitchen 正常
  导入，eager 后端可用（capabilities 含全部 convrot/int8 算子），triton 后端优雅降级。
- **二次坑（版本反向降级）**：排查期间把 comfy-kitchen 降到 0.32 时代的 0.2.30，换来
  `ModuleNotFoundError: comfy_kitchen.int8_decode`——ComfyUI v0.45.4 在 requirements.txt
  里**精确 pin `comfy-kitchen==0.2.41`**（comfy-aimdo==0.6.0）。教训：**不要手动降级
  comfy 系依赖**，版本不对时用 requirements 重装对齐：
  `grep -viE '^torch' requirements.txt | pip install -r /dev/stdin`

## 坑 9：分辨率不是 32 的倍数 → 4K 直出发糊

- **现象**：studio 图片模块 3840×2160（4K）直出，构图正常但整图发软发糊。
- **根因**：官方要求宽高为 **32 的倍数**（docs.comfy.org 明确"any width/height on a
  32-px multiple works"，官方模板 ResolutionSelector 步进也是 32）。2160÷32=67.5
  **不是 32 倍数**——内部网格错位导致细节塌陷。3840 合法（÷32=120），2160 不合法。
- **连带纠正**：此前文档把"约 1MP/768 短边"当成 image 模型口径是张冠李戴——那是
  **video 模型**的口径。官方 image 教程明确 H3 image **原生支持约 16MP 直出**
  （示例 4096×4096、16:9 为 5472×3072，"4096×4096 是单次生成而非放大链"），
  无需放大链路。
- **解法**：4K 用 **4096×2304**（16:9 且 32 网格合法）；studio 默认回退已验证清晰的
  2048×1152，高分辨率按需上调。
- **待复验**：4096×2304 合法网格下 4K 是否清晰（同 seed 三连对比：2048×1152 /
  4096×2304 / 3840×2160）；若合法网格仍糊则另查量化版高分退化。

## 坑 10：蒸馏 image 模型跑 30 步 → 脏斑杂糅（烧图）

- **现象**：2048×1152 出图，皮肤/衣物上大量黑点污渍样伪影，整图发软，提示词为
  真实人像摄影（bf16 模型 + 910C 真机）。
- **根因**：image 模型是**蒸馏调度**（docs.comfy.org t2i 教程：6 步 euler / simple /
  cfg=1）。蒸馏模型被推到远超设计步数（30 步 res_multistep，参数抄自官方 **fl2va
  视频模型**模板）→ 采样噪声累积"烧图"，脏斑+发软。
- **教训**：官方两份口径对应**两个不同模型**——image 模型（MiniMax-H3-Image 仓）=
  6 步 euler/simple；fl2va 视频模型挂载出静图的模板 = 30 步 res_multistep。按所载
  模型选调度，不跨模型抄参数。
- **解法**：studio 图片模块回 6 步 euler/simple；要细节在 6~10 步内微调，禁止 30 步。
- **连带**：bf16 切换与坑 9 的三连诊断被此坑污染（30 步本身就会糊），待 6 步口径下
  重新做 int8/bf16 与分辨率对比。

## 环境速查

- CANN / torch_npu / Python 版本快照见 `docs/ENVIRONMENT-910B.txt`。
- NPU 卡数自适应：`/dev/davinci[0-9]*` 计数，`ASCEND_RT_VISIBLE_DEVICES` 注入。
- aarch64 必须 `LD_PRELOAD=/lib/aarch64-linux-gnu/libgomp.so.1`（torchaudio TLS 问题）。
