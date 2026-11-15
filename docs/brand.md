# BeanBridge 视觉物料

中文名称：**豆桥**。英文名称：**BeanBridge**。短句：**Press. Speak. Send.**

Logo 由一颗豆子的轮廓、弯曲的声音通路和三根波形线组成。它是本项目原创图形，不是 Anker、飞书或 OpenAI 的标识。横幅中的设备与消息卡片是概念插画，不是实物照片或客户端截图。

| 物料 | SVG 源文件 | PNG 导出 | 用途 |
|---|---|---|---|
| Logo | [logo.svg](assets/logo.svg) | [logo.png](assets/logo.png) | 项目标识、应用图标源素材 |
| macOS 图标 | — | [BeanBridge.icns](assets/BeanBridge.icns) | 构建脚本自动装入应用资源 |
| README 横幅 | [banner.svg](assets/banner.svg) | [banner.png](assets/banner.png) | 仓库首页，1600 × 560 的逻辑尺寸 |
| 社交预览 | [social-preview.svg](assets/social-preview.svg) | [social-preview.png](assets/social-preview.png) | 1280 × 640 分享卡片 |
| 端到端数据流 | [flow.svg](assets/flow.svg) | [flow.png](assets/flow.png) | D3200 → 内存解密/ASR → 多应用路由主链路 |
| 多应用安全路由 | [multi-app-routing.svg](assets/multi-app-routing.svg) | [multi-app-routing.png](assets/multi-app-routing.png) | 首次按键锁定、空白页新建、04.92 轻敲与待发箱兜底决策图 |
| 常驻与工作台流水线 | [workbench-pipeline.svg](assets/workbench-pipeline.svg) | [workbench-pipeline.png](assets/workbench-pipeline.png) | BLE 自动重连、ASR 模型下载中心与离机 VAD 工作台架构 |
| 桌面界面导览 | [ui-tour.svg](assets/ui-tour.svg) | [ui-tour.png](assets/ui-tour.png) | 菜单栏浮窗、工作台面板与 ASR 下载中心界面示意 |
| 历史路由提案 | [routing-proposal.svg](assets/routing-proposal.svg) | [routing-proposal.png](assets/routing-proposal.png) | 早期 v0.1 路由设计归档（已由 `multi-app-routing` 实现替代） |

品牌配色：森林绿 `#12372D`、浅青柠 `#C6F38A`、米白 `#F6FAF0`。技术图使用白底、统一边框和有含义的箭头，保证在 GitHub 小尺寸下仍可读。

## 重生成

SVG 不依赖外部字体、脚本或图片请求：

```bash
python3 scripts/render-assets.py
```

导出 PNG 需要在独立 Python 环境安装 CairoSVG；macOS 可能还需指定 Cairo 动态库位置：

```bash
python3 -m venv /tmp/beanbridge-render
/tmp/beanbridge-render/bin/pip install cairosvg
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib /tmp/beanbridge-render/bin/python scripts/render-assets.py --png
```

重新生成 macOS 图标时，再安装 Pillow 并给生成器增加 `--icns` 参数；需要 macOS 自带的 `iconutil`。仓库已有图标文件，正常构建应用无需安装这些绘图依赖。

图形以英文避免不同渲染器的中文字体替代问题，正文说明保持中文。PNG、SVG 已进行 XML/标记检查和实际图片回看，`visual_review: passed`。本次没有验证 GitHub 社交分享页面的实际裁切行为；社交预览素材已备好，不代表已经配置到仓库设置。
