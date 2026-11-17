# 更新记录（H3-Image 昇腾版）

> 本仓库由 [minimax-h3-ascend-uncensored](https://gitcode.com/sazhihou/minimax-h3-ascend-uncensored)
> （视频版）衍生，聚焦 **MiniMax-H3-Image 文生图**在昇腾 910B 上的部署与实测。

## 2026-11-17 · 统一 v0.45.4 单服务方案

- **部署口径变更**：废弃 "0.32 视频主服务（8188）+ 0.45.4 worktree 副本（8189）" 双服务结构，
  主目录 `/mnt/workspace/ComfyUI` 直接升级到 v0.45.4，**单端口 8188 单服务**
- `scripts/setup_image.sh` 重写为统一升级脚本：
  - **全新机器直接浅克隆 v0.45.4**（`git clone --depth 1 --branch v0.45.4`，`--branch` 支持
    tag，无需先拉默认分支再 checkout）；已有 0.32 旧仓走备份升级流程
  - 升级前自动备份主目录本地改动（0.32 昇腾补丁等）到 `runtime/upgrade-backup-*`，
    备份内含回滚命令（`previous-head.txt` + `local-changes.patch`）
  - venv（过滤 torch 系）+ cast_weight device 守卫补丁逻辑不变，幂等
- `scripts/start_comfyui.sh` 合并为唯一启动脚本：venv PATH 前置、去掉 `--cache-classic`
  （坑 7）与 0.32 补丁时代的多卡并行联动；默认端口 8188
- `scripts/start_comfyui_image.sh` 删除；`test_t2i.sh` 默认端口改 8188
- 安全整改：移除 `scripts/set_npu_count.py`（0.32 时代视频多卡并行配置工具，统一后已无引用；
  含 env 路径拼接无校验的路径穿越风险点）。视频并行配置仍可用姊妹仓库的同名工具
- `scripts/download_models_image.sh` 扩展为全家桶：`image` / `video` / `all` 三档 +
  `WITH_LORA=1` 可选 Turbo LoRA，双官方仓寻源（TE 同名同内容共用，不重复下载）；
  补 scope 参数校验
- **保留视频版仓库**（[sazhihou/minimax-h3-ascend-uncensored](https://gitcode.com/sazhihou/minimax-h3-ascend-uncensored)
  `scripts/dl_models.py`）**的全部下载地址**：
  - 完整版 `fl2va_int8_convrot`（34GB，视频段默认档；`LOWVRAM=1` 时与视频版 `--lowvram`
    一致地换 pruned 21GB）
  - `video_vae_int8_convrot`（INT8 视频 VAE，32GB 低配档工作流用）
  - 无审查 heretic TE（ethanfel 仓，26.4GB）：地址保留，但本仓库**默认改为不下载**
    （`WITH_HERETIC_TE=1` 开启）——非官方渠道 convrot 档，layer_conf 与 0.45 官方加载器
    兼容性未验证（大概率踩坑 ①）；0.32 口径视频服务可继续使用
- **全新主机部署流程默认包含图生视频模型下载**：README 三步法第 ② 步在
  `setup.sh`（部署 + 文生图 46GB）后紧跟 `download_models_image.sh video`
  （图生视频 62GB），合计约 108GB，磁盘前提同步上调至 ≥150GB
- **移植视频版分片并行下载器** `scripts/dl_models_fast.py`（引擎来自视频版仓库
  `dl_models.py` 真机实测：32 连接/文件 × 2 文件并行，聚合 ~40MB/s；分片级断点续传
  `.p<offset>`；精确大小校验 + 预期字节数防限流错误页；仅允许 `https://hf-mirror.com` 源）。
  `download_models_image.sh` 默认走它，无 python3/requests 时自动回退单连接 curl；
  `MAX_CONN` / `FILES_PARALLEL` 可调并发
- **修复官方 TE 下载 URL**：Comfy-Org/MiniMax-H3-Image 仓内**不存在** `text_encoders/official/`
  路径（API 实证），`official/` 只是本地隔离目录、不应出现在 URL 里——原 URL 会 404 拿到
  错误页。现脚本仓内路径与本地路径分离（`add <仓库> <仓内路径> <本地路径> <字节>`），
  下载 URL 改用仓内真实路径 `text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors`
- 下载脚本新增启动提醒横幅（档位/文件数/总量/磁盘余量检查）
- **新增下载进度观测**：`scripts/dl_progress.sh` 进度快照（每文件 du 实测落盘字节 vs
  预期大小的百分比 + 总计 + 活动分片数，配 `watch -n 10` 刷新）；分片下载器 reporter
  每 30s 增加每文件百分比输出；curl 回退模式补 `--progress-bar` 进度条
- **修复：下载引擎内嵌自包含**。曾以独立 `scripts/dl_models_fast.py` 分发，该文件漏入库时
  主机端 `python3: can't open file` → 静默退化为 curl 慢速（真机复现）。现引擎以 heredoc
  内嵌于 `download_models_image.sh`，运行时落临时文件执行，**单文件自包含**，杜绝
  "配套文件缺失"故障；独立 `.py` 已移除
- `setup_image.sh` 新增 **`REDEPLOY=1` 重新部署模式**：停旧服务 → 旧主目录整体挪走留档
  （`ComfyUI-old-<时间戳>`，同盘改名不耗时）→ 全新克隆 v0.45.4 → `models` / `output` /
  `user` 自动迁回（`custom_nodes` 不迁回，0.32 时代插件与 0.45 不兼容）→ venv + 补丁；
  适合老目录状态混乱时的推倒重来，模型无需重新下载
- **修复启动脚本覆盖 PATH 导致 comfy_kitchen 导入崩溃**（踩坑记录坑 8）：PATH 改前置
  保留 CANN 编译器目录 + bisheng 自动探测注入 `TRITON_NPU_COMPILER_PATH`；
  `start_comfyui.sh` 启动前打印日志位置与测试指引
  （真机复验：修复后 comfy_kitchen 正常导入，且 comfy-kitchen 0.2.41 自带
  **Ascend 原生后端**，INT8/convrot 算子走 NPU 原生实现）
- **修复 venv 依赖过滤误伤 torchsde**（踩坑记录坑 4 补充）：`^torch` 前缀 grep 把
  独立包 torchsde 一起滤掉（真机复现 `No module named 'torchsde'`），改为精确排除
  torch/torchvision/torchaudio 三件套
- **未验证项（升级先行，真机复验待做）**：
  - 统一部署脚本本身（升级/备份/回滚路径）未在 910B 真机复验
  - 0.32 昇腾视频适配补丁（comfy-ui-changes.patch）与 Turbo 采样节点在 v0.45.4 下的
    兼容性未知，视频链路暂按不可用处理（模型可先行下载）
  - 0.32 口径完整视频方案仍见姊妹仓库 [minimax-h3-ascend-uncensored](https://gitcode.com/sazhihou/minimax-h3-ascend-uncensored)

## 2026-11-17 · 首个公开版本

- **910B 2×64G 真机跑通 H3-Image 文生图**（6 步蒸馏采样，2048×1152 出片）
- **ComfyUI v0.45.4 worktree 副本方案**：与 0.32 视频主服务共存，主服务零改动
  - `scripts/setup_image.sh`：一键部署（worktree + venv + 兼容性补丁，幂等）
- **模型三件套脚本化**：`scripts/download_models_image.sh`
  - Comfy-Org/MiniMax-H3-Image 官方档（DiT convrot 19.5G + 官方 TE 25.3G + image VAE 1.1G）
  - hf-mirror 直连，大小校验 + 断点续传
  - **TE 必须官方版并放 `official/` 子目录**：旧档 layer_conf 与 0.45 官方加载器不兼容
    （`JSONDecodeError: char 0`），详见 `docs/踩坑记录-image.md` 坑 2
- **cast_weight device 守卫补丁**：torch_npu 劫持 `nn.Module.to()` 后以 device 调用钩子，
  ComfyUI 0.45 实现取 `input.dtype` 崩溃（`AttributeError`），sed 补丁自动注入
  （`docs/踩坑记录-image.md` 坑 3）
- **工作流两份**：官方 UI 模板（subgraph）+ API 格式（`/prompt` 直用）+ 一键测试脚本
- 实测数据：46GB 模型 hf-mirror ~20MB/s 约 40 分钟；首次加载 45GB 权重后 6 步采样秒级出片
