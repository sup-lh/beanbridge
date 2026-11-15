# 更新记录

## 0.5.1 — 2026-11-16

### 应用内 ASR 模型管理与下载中心、DoubaoWork 真机联调修复与 Paseo 适配器支持

- **新增应用内 ASR 模型管理与下载中心（`OpenBeanKit` + `AnkerButtonVoice`）**：
  - 将模型规格（`base` / `small-q5_1` / `small` / `medium`）与 `ASRModelManager` 抽离到 [ASRModelCatalog.swift](Sources/OpenBeanKit/ASRModelCatalog.swift)，新增 `ASRModelDownloadManager`：支持 `Hugging Face 官方源` 与 `HF 镜像源 (hf-mirror.com)`（保留 `BEANBRIDGE_MODEL_BASE_URL` 覆盖）、平滑速度与剩余时间估算、隐藏 `.part` 临时文件写入、后台分块流式 SHA-256 校验与原子替换（目录 `0o700`、模型 `0o600`），校验失败或取消时自动清理残留文件。
  - 新增原生面板 [ASRModelManagerWindow.swift](Sources/AnkerButtonVoice/ASRModelManagerWindow.swift)（菜单栏 `ASR 模型管理与下载…` 或工作台 `ASR 模型与下载` 入口），支持下载、取消、删除、手动切换当前模型、改为自动优选、后台校验本地模型 SHA-256、打开 `Models` 目录与复制 CLI 命令；关闭窗口后下载继续在后台进行，工作台状态栏与菜单栏下拉菜单动态显示实时进度。
  - 新增 6 项离线单测（[ASRModelCatalogTests.swift](Tests/OpenBeanKitTests/ASRModelCatalogTests.swift)），并已在本机新版应用内实测下载及校验 `ggml-small.bin`（465 MB）。
- **DoubaoWork (`com.work.pc.doubao`) 真机联调与单窗口唤醒修复**：
  - 在 [CurrentChat.swift](Sources/VoiceRouting/CurrentChat.swift)、[AppTargetAdapter.swift](Sources/VoiceRouting/AppTargetAdapter.swift) 与 [scripts/doubao-chat.py](scripts/doubao-chat.py) 中识别 `chrome://doubaowork-chat/chat` / `doubaowork://doubaowork-chat/chat` 为 `doubaowork-active`；修复冷启动或新建会话向 `open -b com.work.pc.doubao` 传入 `doubaowork://` 导致额外弹出 Chrome 外框 `DoubaoWork Browser.app` 的问题；放宽冷启动等待预算，并将临时诊断快照写入收敛至 `BEANBRIDGE_DOUBAO_DIAG=1`。
  - 修复 `@MainActor` 下 `CurrentChat.isDoubaoPlaceholderOrEmpty` 隔离修饰与长度守卫（过滤豆包自带 25 字空框提示 `"发消息或创建任务... / 使用技能 @ 添加资料"`），同时保留真实用户草稿防覆盖拦截，并在 `safeURLPreview` 加入 `paseo://`；`DoubaoWork.app` 实机探测、单窗口拉起与投递已通过本机联调验收。
- **新增 Paseo 目标适配器（`VoiceRouting` + `scripts`）**：
  - 实现 [PaseoTargetAdapter.swift](Sources/VoiceRouting/PaseoTargetAdapter.swift) 并注册到 `AppTargetRegistry`（`codex` / `doubao` / `paseo` 可随时在菜单栏、浮窗、工作台切换），支持 `paseo://h/<serverId>/agent/<id>`、`paseo://app/h/<serverId>/agent/<id>`、`paseo://agent/<id>` 与 `https://app.paseo.sh/h/<serverId>/agent/<id>` 链接解析及防穿越校验。
  - 在 [CurrentChat.swift](Sources/VoiceRouting/CurrentChat.swift) 实现 `inspectPaseoTarget` 与工作区解析：识别 `/h/<serverId>/workspace/<workspaceId>` 与 `/w/<workspaceId>`，在未产出标签树时激活 `AXManualAccessibility` 与 `AXEnhancedUserInterface` 并做 100ms 间隔双次一致性采样；优先校验 `workspace-tab-agent_*` / `workspace-tab-draft*`，当 macOS Chromium 未暴露 DOM ID 或 `AXSelected=1` 时回退到提取已选中无障碍标签及窗口标题（Paseo 同步写入 `kAXTitleAttribute` 的聚焦窗格活动标签名）并经 `resolve-workspace-tab` 向 Paseo 守护进程精确匹配唯一非归档对话（`"新建 Agent"` / `"New Agent"` / `"New tab"` 等草稿与空白标签触发自动建新会话），同名重复、多对话分屏、加载中或非对话标签均严格 fail-closed 不猜目标。
  - 新增 [scripts/paseo-chat.py](scripts/paseo-chat.py) 与 [scripts/paseo-daemon-helper.mjs](scripts/paseo-daemon-helper.mjs)：支持 `validate`（`paseo inspect --json` 只读校验）、`resolve-workspace-tab`（工作区选中标签消歧与空白标签识别）、`create`（通过 Paseo 内置 Electron Node 运行时调用本地 daemon 幂等创建无初始 prompt 的空闲会话并写入 `0o600` 凭据），以及 `submit`（`paseo send --no-wait --json --behavior steer --prompt-file` 投递语音文字）。
- **测试、全屏兼容与构建脚本更新**：
  - 在 [CurrentChat.swift](Sources/VoiceRouting/CurrentChat.swift) 增加 `isAuxiliaryWindowMetadata` / `resolveSingleConversationWindow`，过滤 macOS 全屏最大化/状态栏顶部条（如高 `33px` 工具条与非 `AXStandardWindow` 浮层）干扰，确保 Paseo / 豆包 / Codex 全屏最大化时仍可正常锁定单一主会话窗口。
  - 新增 [PaseoRoutingTests.swift](Tests/VoiceRoutingTests/PaseoRoutingTests.swift) 与 [scripts/test-paseo-chat.py](scripts/test-paseo-chat.py)（全仓共 49 项 Swift + 16 项 Python 单元测试通过），更新 [build-button-app.sh](build-button-app.sh) 与 [scripts/verify-release.sh](scripts/verify-release.sh)。
  - **Paseo 真机工作区端到端验收通过**：在最大化 `Paseo.app` 工作区窗口下，实测通过 `kAXTitleAttribute` + `resolve-workspace-tab` 精确锁定当前非归档 Agent 会话，并用实体按键录音将语音文字真实送达并触发本对话响应；空白/草稿标签自动建聊及轻敲改发新会话仍待后续实测。

## 0.5.0 — 2026-11-15

### 核心演进（多应用路由、高精度 ASR 与随身工作台）

- **可插拔多目标应用路由与豆包支持（`VoiceRouting`）**：
  - 将原先绑定 Codex 的上下文路由重构为 `AppTargetAdapter` 协议与 `AppTargetRegistry`、`TargetAppPreferenceStore`（`support/target-app` `0o700`/`0o600` 原子持久化，支持 `BEANBRIDGE_TARGET_APP` 覆盖）。
  - 保留并迁移 `CodexTargetAdapter`，新增 `DoubaoTargetAdapter` 与无侵入式脚本桥接 `scripts/doubao-chat.py`（支持 `doubao://chat/<id>`、`doubaowork://chat/<id>` 与 `https://www.doubao.com/chat/<id>` 解析、严格字符/防穿越校验与排他创建/投递回执），并打包进 `build-button-app.sh`。
  - 前台窗口一致性锁定、条件式剪贴板恢复、空白页自动新建、录音中轻敲（`04.92` `userMarked` bit 0）改发独立新会话及 `PendingStore` 先落盘后幂等投递防重发机制现已在各适配器间通用复用。
- **本地 ASR 准确率提升、热词与预览开销优化（`AnkerButtonVoice`）**：
  - 新增 [ASRService.swift](Sources/AnkerButtonVoice/ASRService.swift)：实现 `ASRModelManager`（按 `BEANBRIDGE_MODEL` > `support/model-preference` > 本地高精度自动优选 `medium > small > small-q5_1 > base` > 默认 `ggml-base.bin` 解析）、`HotwordManager`（读写 `support/hotwords.txt` 生成去重 `--prompt`）、与 `AudioResampler`（内存中将 48kHz Opus 解码输出降采样为 16kHz PCM16 WAV）。
  - 更新 `scripts/setup-model.sh` 支持 `--tier base|small|small-q5_1|medium` 与 `--set-default` 校验下载。
  - 重构 `LivePreview`：取消每次实时预览启动 `ffmpeg` 子进程，改为内存态解码与滑动能量增量触发 `whisper-cli`。
- **菜单栏常驻、取消录音与灵感收集箱工作台（`AnkerButtonVoice`）**：
  - 引入 `NSStatusItem` 菜单栏常驻与可隐藏 `VoicePanel` 浮窗、默认目标选择器、BLE 重连/休眠/电量/录音实时状态展示、录音中“取消本条”功能。
  - 新增 [WorkbenchPanel.swift](Sources/AnkerButtonVoice/WorkbenchPanel.swift)，整合离机增量同步、VAD 分段检索、试听回放、复制、一键发往目标、热词表编辑、模型切换与待发箱入口。
- **BLE 后台重连与离机增量同步工作台底座（`OpenBeanKit`）**：
  - 新增 [ReconnectCoordinator.swift](Sources/OpenBeanKit/ReconnectCoordinator.swift)：实现指数退避后台自动重连、`NSWorkspace` 睡眠挂起（保留 `.sleeping` 状态不误判重连）与唤醒恢复、电量/充电状态监听；为 `Transfer` 等补全 `Sendable` 兼容。
  - 新增 [WorkbenchSync.swift](Sources/OpenBeanKit/WorkbenchSync.swift)：实现 `SyncManifestStore` 幂等断点清单、`OfflineSyncCoordinator` 离机增量拉取、`AudioVADslicer` 能量切片及 `WorkbenchArchive` 带毫秒时间戳全文索引检索，并保持实时 Opus 解密与 `04.92` bit 0 分片标记回归兼容。
- **验证与文档边界**：
  - 新增并更新 Swift 单元测试（全包 5 个测试套共 36 项全绿）及 Python 单元测试（`test-create-chat.py` + `test-doubao-chat.py` 共 9 项全绿）、发布自检脚本 [scripts/verify-release.sh](scripts/verify-release.sh)（含 `release` 全量构建、App 资源校验、本地 `jfk.wav --self-test` 及只读 `--probe-target`）。
  - 豆包真机按键发送、D3200 全天休眠重连稳定性与海量离机录音积压同步尚待实体硬件实测。

## 0.4.0 — 2026-11-15

- 录音中轻敲触发设备震动后，将本段改发独立新会话；重复轻敲不会重复建聊。
- 两次轻敲与一次无轻敲对照确认 D3200 04.92 的分片标记，普通结束不触发。
- 浮窗显示轻敲确认，目标读取的迟到结果不能覆盖它。
- 历史对话录音中轻敲后改发新会话的真机链路通过，新会话实际收到消息并回复。

## 0.3.1 — 2026-11-15

- 按用户要求，前台窗口稳定但未取得聊天链接时，保存最终文字后自动新建独立会话并发送，不弹确认框。
- 无目标的历史待发消息也可直接新建会话投递。
- 复制快捷键失效也可能触发新建，不继承页面项目或草稿；权限与焦点错误仍保留到待发箱。

## 0.3.0 — 2026-11-15

- Codex 未运行或已关闭全部窗口时，非空录音结束后创建不绑定项目的独立会话，打开桌面并入队。
- 每条新会话使用独立工作目录；记录 creating 状态与原子创建回执，未知结果不重建。
- 热启动与用户关闭 Codex 后的冷启动均通过真机验收：新会话实际收到语音文字并回复。
- 共 9 项 Swift 测试、3 项 Python 测试通过。

## 0.2.0 — 2026-11-15

- 默认在首次录音按键时自动读取、校验并锁定前台 Codex 对话；保留 fixed 模式。
- 两次新鲜链接一致性、前台窗口校验和条件式剪贴板恢复。
- 浮窗显示目标，提供不发消息的检测入口及辅助功能授权入口。
- 持久化待发箱支持明确链接投递；结果不明或中断的消息不自动重试。
- 新增 4 项路由回归；打包应用的自动读取与实体按键切换对话后的原目标入队通过本机实测。
- 尚未实现自动启动建聊及后台重连。

## 2026-11-15 · 路由可行性补充

- 官方 ⌘⌥L 复制聊天深层链接通过 A/B 对话手动验证，可取得随当前对话变化的真实 ID。
- 补充剪贴板新鲜度、前后焦点一致性和失败回退设计；后台自动触发尚未实现。

## 0.1.0 — 2026-11-15

首个仓库化版本。

- 安克 D3200 实体按键开始/结束语音，本地 Whisper 转写和浮窗预览。
- 向显式绑定的 Codex 对话自动排队发送；真实消息已被对话接收。
- 可选 BlackHole 麦克风桥，正常退出恢复此前系统输入。
- 新增依赖查找、模型校验安装、目标对话只读验证与绑定脚本。
- 提供 Logo、README 横幅、社交预览、数据流图、SVG 源文件和 PNG 导出。
- 汇总实验记录、第三方来源、产品设想，以及上下文路由的可行性与未验证部分。

自动读取前台对话、自动启动并创建桌面对话、常驻重连与全天记忆均未在此版本实现。
