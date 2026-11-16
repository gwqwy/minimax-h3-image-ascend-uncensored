# 更新记录（H3-Image 昇腾版）

> 本仓库由 [minimax-h3-ascend-uncensored](https://gitcode.com/sazhihou/minimax-h3-ascend-uncensored)
> （视频版）衍生，聚焦 **MiniMax-H3-Image 文生图**在昇腾 910B 上的部署与实测。

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
