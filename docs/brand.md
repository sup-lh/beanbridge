# BeanBridge 视觉物料体系

中文名称：**豆桥**。英文名称：**BeanBridge**。核心短句：**Press. Speak. Route Safely.**

Logo 由一颗豆子的轮廓、弯曲的声音通路和三根声波线组成，为本项目原创视觉标识（不包含 Anker、飞书、OpenAI、字节跳动或 Paseo 的第三方商标标识）。首页 Hero 横幅融合了暗森绿工业设计硬件概念渲染与原生毛玻璃 HUD 卡片；其余架构、手势、Bento 与界面图均提供 **GitHub 深色 / 浅色双主题自适应（`<picture>` Dark / Light）** 矢量 SVG 源文件，且不依赖任何外部网络字体或外链徽章请求。

## 物料总览

| 物料类别 | 源文件 / 变体 | 导出或静态文件 | 用途与说明 |
|---|---|---|---|
| **Logo 与应用图标** | [logo.svg](assets/logo.svg) | [logo.png](assets/logo.png) · [BeanBridge.icns](assets/BeanBridge.icns) | 项目原创标识，`build-button-app.sh` 自动打入 `.app` 包 |
| **旗舰 Hero 头图** | [studio-hardware-bg.jpg](assets/studio-hardware-bg.jpg) · [banner.svg](assets/banner.svg) | [hero-banner.png](assets/hero-banner.png) · [hero-banner-en.png](assets/hero-banner-en.png) · [banner.png](assets/banner.png) | 中英文首页主视觉横幅（`1600 × 600` 圆角透明通道） |
| **社交分享海报** | [social-preview.svg](assets/social-preview.svg) | [social-preview.png](assets/social-preview.png) | GitHub OpenGraph / 社交平台 `1280 × 640` 分享卡片 |
| **定制胶囊徽章组** | [badges/*.svg](assets/badges/) | `platform` · `swift` · `whisper` · `targets` · `tests` · `license` | 零外链依赖的同色系品牌胶囊徽章 |
| **12 秒全链路动态演示** | [hero-demo.svg](assets/hero-demo.svg) · [hero-demo-en.svg](assets/hero-demo-en.svg) | 纯矢量 CSS `@keyframes` 自动循环（支持 `prefers-reduced-motion`） | 首屏动态展示「短按锁定 → 内存预览防串台 → 再按投递」 |
| **三段式物理手势卡** | [tactile-gestures-dark.svg](assets/tactile-gestures-dark.svg) · [tactile-gestures-light.svg](assets/tactile-gestures-light.svg)（含 `-en`） | 深浅双模自适应 | 短按锁定、`04.92` 轻敲震动分叉、歧义进 `Pending` 三定律 |
| **核心能力 Bento 墙** | [bento-overview-dark.svg](assets/bento-overview-dark.svg) · [bento-overview-light.svg](assets/bento-overview-light.svg)（含 `-en`） | [workbench-pipeline.png](assets/workbench-pipeline.png) | 5 宫格不对称便当盒总览图（兼容 `workbench-pipeline.svg`） |
| **原生界面导览图** | [ui-tour-dark.svg](assets/ui-tour-dark.svg) · [ui-tour-light.svg](assets/ui-tour-light.svg) · [ui-tour.svg](assets/ui-tour.svg) | [ui-tour.png](assets/ui-tour.png) | 菜单栏状态栏、语音浮窗、安克豆工作台、模型下载中心展示 |
| **端到端架构管线图** | [flow-dark.svg](assets/flow-dark.svg) · [flow-light.svg](assets/flow-light.svg) · [flow.svg](assets/flow.svg) | [flow.png](assets/flow.png) | D3200 BLE → Swift 内存降采样 → Whisper → 安全路由 |
| **多应用安全路由树** | [multi-app-routing-dark.svg](assets/multi-app-routing-dark.svg) · [multi-app-routing-light.svg](assets/multi-app-routing-light.svg) | [multi-app-routing.png](assets/multi-app-routing.png) | Paths A～D 分支消歧与 `0o600` 幂等回执架构图 |
| **早期路由设计归档** | [routing-proposal.svg](assets/routing-proposal.svg) | [routing-proposal.png](assets/routing-proposal.png) | `v0.1` 历史上下文路由提案归档（供 `context-routing.md` 引用） |

## 品牌色彩规范

- **深森绿主色**：`#0B1613`（暗底画布）/ `#12372D`（品牌主绿）
- **荧光青柠强调色**：`#C6F38A`（锁定态、声波脉冲与主操作按钮）
- **青碧辅助色**：`#5EEAD4` / `#0F766E`（`04.92` 轻敲分叉、内存重采样与 VAD 切片）
- **琥珀警示色**：`#FBBF24` / `#B45309`（Fail-Closed `Pending` 待发箱安全拦截）
- **暖米白浅底**：`#F6FAF3` / `#F6FAF0`（浅色模式底板与高对比正文）

## 重新生成矢量物料

所有矢量图与徽章均由 `scripts/render-assets.py` 确定性生成（刻意使用纯矢量几何图标替代操作系统 Emoji，确保在 macOS、Windows、Linux 与移动端渲染一致）：

```bash
python3 scripts/render-assets.py
```

如需批量刷新静态 PNG 导出（保留合成版 `hero-banner*.png` 与 `social-preview.png`），可在安装了 `cairosvg` 或 `resvg` 的环境中运行 `--png`，增加 `--icns` 可在 macOS 上通过 `iconutil` 重建 `BeanBridge.icns`。
