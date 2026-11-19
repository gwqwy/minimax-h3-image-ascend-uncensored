# AGENTS.md · 本仓库代理协作规则

> 面向在本仓库工作的 AI 代理（ZCode 等）。这些规则由仓库所有者确立，优先级高于代理的默认习惯。

## Git 纪律（最高优先级）

- **禁止执行任何改变 git 状态的命令**：`git commit` / `add` / `push` / `rm` / `reset` / `stash` 等
  一律不做——提交、暂存、推送完全由仓库所有者在自己的客户端完成
- 允许只读诊断：`git status` / `log` / `diff` / `ls-files` / `ls-remote`
- 改动一律留在工作区，交付时给出待提交清单
- **新增文件必须显式提醒所有者 `git add`**：历史教训——独立下载脚本两次漏 add，导致
  真机端引用不存在的文件（见 CHANGELOG 2026-11-17"下载引擎内嵌自包含"条目）

## 验证纪律

- **所有脚本默认在昇腾主机上运行**（aarch64 Linux + CANN）：路径、环境变量、依赖都以
  主机为准（/mnt/workspace、set_env.sh、npu-smi），不写代理协作机（Windows）专属的
  假设；代理只做静态校验（bash -n），运行验证由所有者在主机完成
- shell 脚本改动后必须 `bash -n` 全量校验（用 Git 自带 bash；协作机上 WSL bash 损坏）
- workflow JSON 改动后必须校验：JSON 语法 + 拓扑一致性（连线双向引用、槽位、类型）；
  参考脚本模式见会话用的 PowerShell 拓扑断言
- **代理不做真机验证**——真机验证由所有者在昇腾主机完成；未验证项必须在 README /
  CHANGELOG 用 ⚠️ 明确标注，已验证结论与推测分开表述
- PowerShell 5.1 注意事项：.ps1 脚本内不能写中文（无 BOM UTF-8 会被按 GBK 误读），
  含中文的文件路径必须通过命令行参数传入

## 文档纪律

- 脚本 / 工作流 / 部署口径变更必须同步 `README.md`（中文为主，文末附英文段）+ `CHANGELOG.md`
- 新踩的坑写入 `docs/踩坑记录-image.md`（坑 N 递增编号；现象 → 根因 → 解法 → 真机复验）
- 修复依赖类问题时先查官方 requirements 的精确 pin，不要凭记忆降级/升级

## 部署口径快照（勿回退，2026-11-18）

- 统一 ComfyUI **v0.45.4** 单服务，端口 8188，主目录 `/mnt/workspace/ComfyUI`
- venv 依赖过滤**精确排除** `torch` / `torchvision` / `torchaudio` 三件套——禁止用
  `^torch` 前缀模糊匹配（历史教训：误伤 torchsde，踩坑记录坑 4）
- `comfy-kitchen==0.2.41` / `comfy-aimdo==0.6.0` 是 v0.45.4 的精确 pin，**禁止手动降级**
  （历史教训：降到 0.2.30 缺 `int8_decode`，踩坑记录坑 8）
- 启动脚本 PATH 必须**前置**（`$VENV/bin:$PATH`）而非覆盖——triton-ascend 需要在 PATH
  里找到 CANN 的 bisheng 编译器（踩坑记录坑 8）
- 官方 TE 本地放 `text_encoders/official/`，但下载 URL 用仓内真实路径（仓里没有
  `official/` 目录，URL 带上只会 404）
- 模型下载引擎内嵌于 `download_models_image.sh`（heredoc 自包含），**不要拆成独立 .py
  文件引用**；仅允许 `https://hf-mirror.com` 源（SSRF 白名单）
- 工作流为 UI 格式主控台（`minimax_h3_studio_ui.json`）+ 官方模板对照；视频口径：
  24fps、`length ≡ 5 (mod 17)`（5s=124 帧，上限约 345 帧）、非 Turbo 20 步 res_multistep
- 机型：**910C 1×128GB**（Atlas A3，系统呈现 `davinci0/1` 双 64GB 设备）；实例规格
  "240GiB" 指 RAM 而非显存；910B 2×64G 为已验证参考机型

## 已知门禁（Mimosa 安全扫描）

- push / commit 前有静态安全扫描并可能强制拦截；高危模式包括：env 变量拼路径做文件
  操作（路径穿越）、未校验 URL 的服务端请求（SSRF）
- 写下载/网络类脚本时：URL 白名单硬校验 + 目标路径边界校验要写进代码，且避免触发
  上述静态模式
