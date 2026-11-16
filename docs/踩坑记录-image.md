# 部署踩坑记录（H3-Image 昇腾版）

> 从零把 MiniMax-H3-Image 搬上昇腾 910B 的完整踩坑过程，按时间顺序。
> 结论已固化进 `scripts/setup_image.sh` 与 `scripts/download_models_image.sh`，这里保留过程与原理。

## 坑 0：H3-Image 需要 ComfyUI ≥ 0.45，而昇腾环境普遍是 0.32

- H3-Image 原生节点（`MiniMaxH3ImageConditioning` / `MiniMaxH3LatentUpscaleWithModel` 等）
  在 ComfyUI v0.45.0 进入核心（2026-11-10，day-0 支持）。
- 昇腾视频版主服务锁定 0.32 + 昇腾补丁（`comfy-ui-changes.patch` 是对着 0.32 写的），
  直接升级主服务风险极大（补丁冲突 + Turbo 插件兼容未知）。
- **解法**：git worktree 副本。`git fetch v0.45.4` → `git worktree add ComfyUI-045 v0.45.4`，
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

## 环境速查

- CANN / torch_npu / Python 版本快照见 `docs/ENVIRONMENT-910B.txt`。
- NPU 卡数自适应：`/dev/davinci[0-9]*` 计数，`ASCEND_RT_VISIBLE_DEVICES` 注入。
- aarch64 必须 `LD_PRELOAD=/lib/aarch64-linux-gnu/libgomp.so.1`（torchaudio TLS 问题）。
