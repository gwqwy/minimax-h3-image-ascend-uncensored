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
- **新增工作流两份 + 三份全部专业化重构**（节点接线对照官方模板
  `video_minimax_h3_i2v.json` / `image_minimax_h3_t2i.json`）：
  - 采样栈统一升级为官方架构：`RandomNoise → KSamplerSelect → BasicScheduler →
    BasicGuider → SamplerCustomAdvanced`（BasicGuider 单条件 ≡ cfg 1.0，噪声/采样器/
    调度器解耦）；NPU 上不挂 `ModelAttentionBackend`（comfy kitchen attention 未验证）
  - `minimax_h3_image_t2i_api.json`：文生图（image DiT，6 步 euler/simple，结构专业化，
    采样语义与已验证链一致）
  - `minimax_h3_i2v_api.json`：图生视频——LoadImage 首帧 → MiniMaxH3ImageToVideo
    （自带 LATENT）→ 专业采样栈（20 步 res_multistep/simple）→ 视频/音频双 VAEDecode
    → CreateVideo(fps=24) → SaveVideo
  - `minimax_h3_t2i_i2v_api.json`：文生图→图生视频一键链——t2i 在 1344×768 出图
    直接作首帧（中间帧经 SaveImage 留档），两颗 DiT 共享同一 CLIPLoader（TE 只加载一次）
  - 文生图两份采样语义已验证；视频链路 ⚠️ 未验证
- **新增双模块控制台工作流** `workflows/minimax_h3_studio_ui.json`（UI 格式）：
  图片模块默认开启（Queue 先出图），视频模块默认旁路（框选整组 Ctrl-B 解除后 Queue，
  自动完成 文生图→图生视频 一条龙）；同 seed 同图保证首帧与上次完全一致；工作流内附
  使用说明节点；拓扑经脚本校验（30 条连线双向一致、旁路 13/活动 12）
- **新增 4K 直出文生图工作流** `workflows/minimax_h3_t2i_4k_api.json`：
  3840×2160（8.3MP，节点上限 20MP 内）+ `VAEDecodeTiled`(tile 1024) 分块解码防 OOM；
  4K 直出未实测，OOM 退 `LOWVRAM=1` 或 2MP+潜空间放大
- **studio 控制台增强为唯一主力工作流 + 收敛工作流目录**：
  - 图片模块升级：**4K（3840×2160）直出** + **30 步 res_multistep**（官方画质口径，
    原注释"30 默认、50 细节最多"）+ `VAEDecodeTiled`(tile 1024) 分块解码防 OOM
  - 新增首帧自动解耦支路：4K 图经 `ImageScaleToTotalPixels`(0.9MP) 缩放后喂给视频模块，
    一次 Queue 完成 4K 出图 → 视频；`SaveImage` 前缀改 `h3image_studio_4k`
  - **移除被替代的 4 份独立工作流**：`minimax_h3_image_t2i_api.json`（已验证的 6 步
    快速链，语义并入 studio 图片模块）、`minimax_h3_i2v_api.json`、
    `minimax_h3_t2i_i2v_api.json`、`minimax_h3_t2i_4k_api.json`；最终保留
    `minimax_h3_studio_ui.json`（主力）+ `image_minimax_h3_t2i.json`（官方模板对照）
  - 快速预览口径：steps 调回 6 + 分辨率 1344×768 即秒级出图
- **新增服务看门狗** `scripts/watchdog.sh`（真机反馈：出图后偶发假死——进程活着、
  SSH 正常、网页打不开，需手动重启+重新转发端口）：每 30s 探测 /system_stats，
  连续 3 次失败自动杀进程并拉起（tmux 里 nohup 挂载；watchdog.pause 文件可暂停）；
  `start_comfyui.sh` 新增 `NO_SMART_MEM=1` 开关（关闭 RAM pressure cache，
  假死嫌疑源之一）；README 新增假死处理 FAQ（py-spy 抓栈 + npu-smi + free 三件套）
- **4K bf16 OOM 真机定位 + 显存账本入文档**：bf16 DiT 38.4GB + TE 25.9GB = 64.3GB
  超单设备 61GB（2MP 靠乒乓卸载腾挪成功，4K 激活压穿）——4K 跑 bf16 需 `LOWVRAM=1`；
  或换 int8 DiT（46GB 从容，6 步口径复验中）。另真机踩坑：**denoise 0.9 残留噪声**
  （文生图必须 1.0），已写入 studio 说明与 README
- **image DiT 切换 bf16 全量**（真机反馈：4096×2304 合法网格下 int8 版仍糊，疑似
  量化高分退化）：下载清单/studio 控制台/test_t2i.sh 全部切换到
  `minimax_h3_image_pruned_bf16.safetensors`（40.23GB，官方标注 full precision），
  int8 退出下载清单（主机端旧文件由所有者验证 bf16 后自行删除）；
  image 档下载量 46GB→约 66GB；⚠️ bf16 版 4K 清晰度待真机复验
- **修复烧图脏斑（真机反馈）+ 新增踩坑记录坑 10**：studio 图片模块曾用 30 步
  res_multistep（参数误抄自官方 fl2va 模板）——image 模型是蒸馏调度，docs 明确
  **6 步 euler/simple cfg=1**，超步数烧图（皮肤/衣物脏斑+发软，2048×1152 真机复现）。
  已回退 6 步 euler；连带说明：坑 9 的 int8/bf16 与分辨率对比需在 6 步口径下重做
- **修复 4K 直出发糊（真机反馈）+ 新增踩坑记录坑 9**：分辨率必须在 **32 倍数网格**——
  3840×2160 的 2160 非 32 倍数（÷32=67.5），网格错位导致整图发软；4K 正确尺寸
  **4096×2304**。连带纠正文档口径错误：H3 **image** 模型原生支持约 16MP 直出
  （官方示例 4096×4096 / 5472×3072，无需放大链），此前误引 video 模型的"1MP/768
  短边"口径。studio 默认回退已验证清晰的 2048×1152，内嵌说明更新
- **新增古风提示词范本** `workflows/prompt_gufeng_4k.md`：约 500 字中文长提示词
  （月下剑舞·竹海仙山场景，主体/环境/光影/构图/色调/风格七维要素拆解表 + studio
  配套参数与快速预览口径），studio 两处提示词同步换为中文版（Qwen3-VL 中英双语
  原生支持；中文出图质量未实测，README 已标注对比方法）
- **910C 口径**：Atlas A3（1 卡 128GB，系统呈现 davinci0/1 双 64GB 设备）实测进行中，
  脚本全自动适配无需改动；对 ComfyUI 的显存形态与 910B 双卡相同（v0.45 原生不做卡间
  切分，超单设备部分走内存卸载）；README 新增视频时长上限（≈15s / 345 帧）与 4K 直出 FAQ
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
