# 按键后自动选择目标对话（Codex 与豆包等多目标路由）

状态：**可插拔多目标前台路由、豆包适配器协议桥接、待发箱与关闭后新建独立会话已实现（Swift/Python 单元测试与脚本验证通过）**。2026-11-15，本机打包应用在获授辅助功能权限后，可自动执行两次复制链接，取得实际对话 ID，并通过只读接口校验。没有在该检测中投递消息。

> [!IMPORTANT]
> **真实硬件端到端实测范围边界**：
> - **已在真机 D3200 实体按键上端到端实测通过**：Codex 目标的前台会话读取锁定、切换对话后锁定原会话投递、未启动/无窗口下冷启动新建独立会话投递、以及录音中轻敲震动改发独立新会话。
> - **仅单元测试 / 静态编译与脚本离线验证通过（未进行真机 D3200 实体按键端到端实测）**：本次新增的可插拔多目标适配器协议（`AppTargetAdapter`）、豆包适配器（`DoubaoTargetAdapter`）与 `doubao-chat.py` 桥接、`doubao://` / `doubaowork://` 链接校验、以及多目标偏好切换（`TargetAppPreferenceStore`）。严禁将其表述为“已真机实测通过”。

## 可插拔多目标应用路由体系

为支持除 Codex 之外的桌面 AI 客户端（如豆包），系统重构了单一硬编码路由，建立统一的多目标适配层：

1. **`AppTargetAdapter` 协议**：定义目标应用接入的规范接口：
   - 基础元数据：`appID`（小写规范化标识，如 `"codex"`、`"doubao"`）、`displayName`（用户友好名称）、`bundleIdentifiers`（支持多包名匹配，如豆包的个人版、工作版或自定义覆盖）、`linkPlaceholder`。
   - 目标捕获与校验：`needsNewChat()`、`captureCurrentTarget(copyKeyCode:)`、`parseLink(_:)`、`validate(id:supportDirectory:)`、`canonicalLink(for:)`。
   - 会话生命周期与投递：`createNewSession(messageID:supportDirectory:)`、`openSession(_:)`、`submit(text:to:supportDirectory:)`。
2. **`CodexTargetAdapter`**：封装既有 Codex 路由链路（`com.openai.codex`），调用 `set-target.py` 进行 `thread/read` 只读验证，调用 `create-chat.py` 创建无绑定项目的独立会话，并通过 CLI `codex queue --thread` 投递。
3. **`DoubaoTargetAdapter`**：接入豆包 macOS 桌面端：
   - 默认支持候选 Bundle Identifier 列表：`com.bot.pc.doubao`、`com.work.pc.doubao`、`com.bytedance.doubao`，并支持环境变量 `BEANBRIDGE_DOUBAO_BUNDLE_ID` 显式覆盖与优先级排序。
   - 链接支持深层链接与网页链接解析：支持 `doubao://chat/<id>`、`doubaowork://chat/<id>` 以及 `https://www.doubao.com/chat/<id>`。
   - 脚本桥接：通过独立脚本 `scripts/doubao-chat.py` 提供 `validate`、`create` 与 `submit` 子命令，执行原子回执管理与投递。
4. **`AppTargetRegistry`**：全局线程安全的目标适配器注册表，支持运行时按 `appID` 规范化注册与查询，保证默认顺序与扩展能力。
5. **`TargetAppPreferenceStore`**：管理默认目标应用偏好持久化（存储于 `support/target-app`，目录 `0o700`，文件 `0o600` 原子写入）。支持环境变量 `BEANBRIDGE_TARGET_APP` 强制覆盖。
6. **所有目标应用统一复用的核心保障**：
   - **前台焦点一致性锁定**：首次按键即执行严格的辅助功能（AX）检查，前台应用、唯一窗口及标题在两次新鲜剪贴板读取期间若有任何跳动立即失败，拒绝使用不可靠旧目标。
   - **空白页自动新建**：前台与窗口合规但未取得链接（如新建空白聊天或超时），自动计划在最终文字就绪后创建独立新会话，不弹阻塞弹窗。
   - **录音中轻敲改发新会话**：D3200 固件 `04.92` 的分片标记 `userMarked` 会原子覆盖原有目标，触发该应用的独立新建流程。
   - **PendingStore 防重发保护**：投递前强制落盘 `submitting`；投递成功落盘 `queued`，出现网络中断或状态未知标记为 `uncertain`，禁止后台自动盲目重试，确保一次性投递安全。

## 当前行为（以 current 模式为例）

1. 默认 `current` 模式；首次按键接收音频的同时开始目标检测。
2. 根据 `TargetAppPreferenceStore` 取得当前有效目标应用（默认 `codex`，可切为 `doubao`）。
3. 检查对应应用的运行与窗口状态：若未运行或辅助功能确认已无窗口，锁定“录音结束后新建”计划；有窗口但在后台、最小化或状态未知不触发新建。若应用在前台，确认其 bundle ID 在适配器的合法列表中，且只有一个可访问窗口、窗口非 modal。
4. 记录窗口身份与标题，触发复制快捷键（默认 ⌘⌥L，键码 37）。只接受动作之后新产生的剪贴板值，并根据目标适配器规则进行链接格式校验。
5. 再独立复制一次；两次 ID 必须相同。等待期间持续检查前台应用、窗口和标题；发生变化即失败。
6. 通过适配器的只读接口（如 Codex 的 `thread/read`、豆包的只读校验）验证目标。浮窗持续显示目标标题；本段音频携带此不可变目标，提交时不重新查询前台。
7. 第二次按键后生成最终文字，先保存待发记录，再校验锁定 ID 可访问，最后调用适配器的 `submit` 投递。
8. 新建计划在非空最终文字后执行：持久化 creating 标记 → 调用适配器创建独立新会话返回 ID → 保存原子创建回执 → 激活/打开该会话 → 队列提交。
9. 无目标时保留文字供用户粘贴明确聊天链接（Codex 或豆包均可）。投递前将记录标记为 `submitting`；结果未知或重启后的中断不会自动重发。

剪贴板快照只保存在内存中；仅当 changeCount 和内容仍属于本次复制时恢复。用户在此后复制的新内容不会被覆盖。程序不会激活、导航或根据最近活跃记录猜测对话。浮窗不会在显示时抢走前台焦点。

## 链接校验与脚本桥接

### 链接格式与校验规范

`ChatLink.parse(_:defaultAppID:)` 提供了严格的 URL 防御性解析：
- 严格禁止携带用户名、密码、端口、Query 参数或 Fragment 锚点。
- 拒绝包含目录穿越（`..`、`/`、`\`）或保留字（如 `new`、`.`）的异常 ID。
- `doubao://chat/<id>`、`doubaowork://chat/<id>` 和 `https://www.doubao.com/chat/<id>` 均需严格验证 ID 仅包含 `[A-Za-z0-9._-]` 字符集且长度不超过 128 字节。
- 明确拦截根路径或空白页路径（如 `https://www.doubao.com/chat`、`doubao://chat/new` 等），将其安全归为未取得聊天链接，从而走空白页新建机制。

### 脚本桥接（scripts/doubao-chat.py）

`doubao-chat.py` 为豆包桌面端提供无侵入式的脚本桥接：
- **`--action validate --id <ID>`**：校验会话 ID 是否合法有效，返回标准化 `VoiceTarget` JSON。
- **`--action create --receipt <PATH>`**：通过排他性创建回执（`claim_exclusive_receipt`，`O_CREAT | O_EXCL`，权限 `0o600`）保障原子创建，生成独立新会话。
- **`--action submit --id <ID> --text <TEXT> --receipt <PATH>`**：投递消息至指定会话，原子保存投递回执，返回投递凭据。

单元测试 `scripts/test-doubao-chat.py` 与 Swift 测试 `MultiAppRoutingTests` 均已覆盖该链路的边界与异常恢复。

## 使用与恢复

- 构建：`./build-button-app.sh`，或传入应用输出路径。
- 浮窗「辅助功能授权」请求系统权限；需要用户在系统设置中开启。
- 「检测目标」会留出三秒切回前台应用，不接触录音设备或投递消息。
- 诊断入口：应用可执行文件 `--probe-target` 输出 JSON 后退出；`--probe-output /absolute/path.json` 将结果写入指定文件。
- 「待发箱」可逐条查看文字，支持在条目上直接看到归属应用标签（如 `[Codex·待发]`、`[豆包·需核对]`）。pending 消息可指定对应链接发送；submitting/uncertain 只提供复制核对，防止重复发送。
- `routing-mode` 设为 `fixed` 可保留显式绑定行为；默认 `current` 无论失败原因都不会回退到固定目标。
- 目标应用切换：通过菜单栏切换或写入 `support/target-app`（如 `doubao` 或 `codex`），也可通过环境变量 `BEANBRIDGE_TARGET_APP` 临时覆盖。

## 验证与验收状态

| 验证项 | 验证方式 | 状态与边界说明 |
|---|---|---|
| Codex 前台会话自动锁定 | D3200 实体按键真机实测 | **已真机实测通过**：获授辅助功能后，按键录音中切换到其他对话，最终文字仍准确投递原对话。 |
| Codex 关闭后冷启动新建 | D3200 实体按键真机实测 | **已真机实测通过**：关闭 Codex 后按键，生成独立会话、拉起桌面、排队投递并收到“收到。”回复。 |
| 录音中轻敲震动改发新会话 | D3200 实体按键真机实测 | **已真机实测通过**：D3200 固件 04.92 分片 `flags=01` 解析稳定，轻敲后成功在新会话产生消息。 |
| 多目标路由架构（`AppTargetAdapter`）与完整工程回归 | Swift XCTest 自动化测试 | **单元测试全量 36 项全绿**：覆盖 LiveProbePolicyTests 4 项、ToolLocatorTests 1 项、RoutingTests 5 项、MultiAppRoutingTests 10 项、ReconnectAndWorkbenchTests 16 项（含 .sleeping 断线保护、04.92 bit 0 与 VAD 时间戳搜索回归）。多适配器注册、查找、默认回退与格式隔离全部通过（0 失败）。*未在真机按键实测*。 |
| 豆包链接解析与非法字符拦截 | Swift XCTest 自动化测试 | **单元测试通过**：对 `doubao://`、`doubaowork://`、网页链接及越界注入进行了测试覆盖。 |
| 豆包与建聊脚本桥接（`doubao-chat.py` + `create-chat.py`） | Python unittest 自动化测试 | **脚本测试全量 9 项全绿**：CreationTests 3 项 + DoubaoChatBridgeTests 6 项，排他创建回执、参数防注入、会话校验测试全部通过。*未在真机按键实测*。 |
| 偏好持久化（`TargetAppPreferenceStore`） | Swift XCTest 自动化测试 | **单元测试通过**：权限 `0o700`/`0o600`、环境变量覆盖与异常恢复通过。 |
| Release 应用构建与资源打包校验 | `scripts/verify-release.sh` | **本地编译与自检 PASS**：`swift build -c release` 零错误通过（仅余 CBPeripheral 非 Sendable 预存警告），`dist/安克豆按键语音.app/Contents/Resources` 完整包含 `doubao-chat.py`、`create-chat.py`、`set-target.py`、`BeanBridge.icns`，`jfk.wav --self-test` 与只读 `--probe-target` 全部通过。 |

## 空白新建页处理

- 用户确认在尚未发送任何消息的新建空白页录音失败；记录为复制链接超时，已有对话检测成功。
- 用户明确要求不弹窗、直接发送。前台与窗口检查通过但复制链接超时（或返回空白页通用 URL）时，自动锁定新建独立会话计划，非空最终文字保存后创建并发送。
- 此策略也覆盖复制快捷键失效，不能据此声称准确识别了空白页面；不继承空白页项目、模型或草稿。
- 权限不足、窗口/焦点变化和剪贴板冲突等错误仍进入待发箱，不触发自动新建。只读检测入口始终不创建、不发送。
- 历史无目标待发消息保留手动新建入口；复用创建认领与投递去重保护。

## 明确的剩余边界

- 首次按键到取得稳定目标存在短暂检测窗口；请等浮窗出现目标标题再切换页面。系统没有提供原子性的「物理按键时刻 + 当前聊天」接口，快速 A→B→A 瞬间变化无法得到绝对保证。
- 多窗口全部拒绝自动路由；选择器采用粘贴确切链接，尚未提供聊天列表。
- 设置页、特殊弹窗、自定义快捷键及客户端升级仍需实测。复制动作超时或得到非聊天内容时不会发送。
- 不自动重试结果不明的投递，不承诺严格的一次投递。已入队不等于已经出现或完成处理。
- 豆包目标尚未接入实体按键实测；BLE 自动重连与离机增量同步处于模块实现与测试阶段（`ReconnectCoordinator` 覆盖指数退避与休眠唤醒状态机，已通过 16 项回归测试，但尚未在 D3200 真实硬件全天休眠场景中进行跑测）。
- `ASRService`（多层级 Whisper 模型与 `support/hotwords.txt` 热词表）、`LivePreview` 无 ffmpeg 内存 48k->16k 降采样、NSStatusItem 菜单栏常驻、取消本条录音以及 `WorkbenchPanel` 灵感收集箱均已完成代码实现并通过本地编译与回归自检，未作真机端到端已通过声明。详见 [产品设想](product-ideas.md) 与 [实验记录](field-notes.md)。

## 当前行为

1. 默认 `current` 模式；首次按键接收音频的同时开始目标检测。
2. 若 Codex 未运行，或辅助功能确认已无窗口，锁定“录音结束后新建”计划；有窗口但在后台、最小化或状态未知不触发新建。否则确认前台 bundle ID 为 `com.openai.codex`，且只有一个可访问窗口、窗口非 modal。
3. 记录窗口身份与标题，触发 ⌘⌥L。只接受动作之后新产生的剪贴板值，并严格校验本地 UUID 深层链接。
4. 再独立复制一次；两次 ID 必须相同。等待期间持续检查前台应用、窗口和标题；发生变化即失败。
5. 通过只读 `thread/read` 验证目标。浮窗持续显示标题；本段音频携带此不可变目标，提交时不重新查询前台。
6. 第二次按键后生成最终文字，先保存待发记录，再校验锁定 ID 可访问，最后使用既有 `codex queue --thread` 投递。
7. 新建计划在非空最终文字后执行：持久化 creating 标记 → `thread/start` 返回 ID → 保存创建回执 → 关闭创建助手 → 深层链接打开该 ID → 使用原有队列提交。每条语音使用独立工作目录，不绑定项目。
8. 无目标时保留文字供用户粘贴明确聊天链接。投递前将记录标记为 `submitting`；结果未知或重启后的中断不会自动重发。

剪贴板快照只保存在内存中；仅当 changeCount 和内容仍属于本次复制时恢复。用户在此后复制的新内容不会被覆盖。程序不会激活、导航或根据最近活跃记录猜测 Codex 对话。浮窗不会在显示时抢走前台焦点。

## 使用与恢复

- 构建：`./build-button-app.sh`，或传入应用输出路径。
- 浮窗「辅助功能授权」请求系统权限；需要用户在系统设置中开启。
- 「检测目标」会留出三秒切回 Codex，不接触录音设备或投递消息。
- 诊断入口：应用可执行文件 `--probe-target` 输出 JSON 后退出；`--probe-output /absolute/path.json` 将结果写入指定文件。
- 「待发箱」可逐条查看文字。pending 消息可指定链接发送；submitting/uncertain 只提供复制核对，防止重复发送。
- `routing-mode` 设为 `fixed` 可保留旧版显式绑定行为；默认 `current` 无论失败原因都不会回退到固定目标。

## 新会话验证记录

- 2026-11-15，用户关闭 Codex 后完成按键测试并提供生成的聊天链接；读取该会话确认测试文字与“收到。”回复，创建回执为 created、投递记录为 queued。真实会话 ID 和录音文字未写入仓库。

- 创建真实持久会话，`projectId` 为空；创建进程退出后，独立只读查询仍可访问。
- 桌面通过真实 ID 深层链接打开；只读前台探针核对到此 ID。
- 向该会话排队测试消息，实际出现用户消息并得到“新会话测试收到”的回复。
- 9 项 Swift 测试和 3 项 Python 测试通过，覆盖创建抢占、崩溃后不重复创建、创建失败的持久标记与原子回执。

## 前台路由验证记录

- 原有 4 项协议/工具定位测试继续通过。
- 新增 4 项路由测试：链接边界、持久化后不能重发/改向、目标不明时文字恢复及私有权限、并发投递只有一个成功认领。
- release 应用构建与签名成功；沿用现有录音帧的本地识别回归成功。
- 真实按键录音生成“这是自动路由测试。”；因最终包重新签名后辅助功能权限失效，文字准确进入 pending 状态且 target 为空，没有自动发送。
- 定向重置后重新添加最终应用，独立进程再次成功读取并校验本对话。
- 实体按键第二轮：用户确认开始后切换到其他对话，再按键结束；文字“这是自动路由测试第二次。”仍进入原对话队列，CLI 返回消息 UUID。随后原对话实际收到该消息，完整投递链路已确认。
- 系统 tccd 日志确认重建后的签名与旧辅助功能授权不匹配；仅切换开关未恢复，需要定向重置本应用授权并重新添加当前包。
- 临时签名每次重建可能使辅助功能授权失效；最终应用默认位于 `dist/安克豆按键语音.app`，授权应针对该路径。
- 无辅助功能权限时拒绝自动读取；权限开启后自动检测得到真实当前对话，且只读查询成功。

## 空白新建页处理

- 用户确认在尚未发送任何消息的新建空白页录音失败；记录为复制链接超时，已有对话检测成功。
- 用户明确要求不弹窗、直接发送。前台与窗口检查通过但复制链接超时时，自动锁定新建独立会话计划，非空最终文字保存后创建并发送。
- 此策略也覆盖复制快捷键失效，不能据此声称准确识别了空白页面；不继承空白页项目、模型或草稿。
- 权限不足、窗口/焦点变化和剪贴板冲突等错误仍进入待发箱，不触发自动新建。只读检测入口始终不创建、不发送。
- 历史无目标待发消息保留手动新建入口；复用创建认领与投递去重保护。
- 蓝牙授权若晚于启动等待的 20 秒，当前版本需要重启同一应用才能连接；此前日志确认重启后恢复。

## 明确的剩余边界

- 首次按键到取得稳定目标存在短暂检测窗口；请等浮窗出现目标标题再切换页面。系统没有提供原子性的「物理按键时刻 + 当前聊天」接口，快速 A→B→A 瞬间变化无法得到绝对保证。
- 多窗口全部拒绝自动路由；选择器采用粘贴确切链接，尚未提供聊天列表。
- 设置页、特殊弹窗、自定义快捷键及客户端升级仍需实测。复制动作超时或得到非聊天内容时不会发送。
- 用户完成关闭 Codex 后的真实按键测试；程序创建独立会话、打开桌面、投递最终文字，目标会话实际出现用户消息并回复“收到。”。冷启动链路已在本机验收。
- 不自动重试结果不明的投递，不承诺严格的一次投递。已入队不等于已经出现或完成处理。
- 蓝牙重连、系统睡眠恢复和全天运行仍是后续工作（模块单元测试已通过，真机长期稳定性仍待实测）。
- `ASRService` 多层模型及热词注入、`LivePreview` 纯内存降采样、菜单栏常驻交互与灵感收集箱已实现并通过自动化回归验证。

## 已核对的接口边界

### 发送到明确 ID：已验证

本机 CLI 0.167.0 支持 `codex queue --thread <ID> --message <TEXT>`。本项目通过参数数组调用，没有把识别文字拼进 shell。消息会进入目标会话队列，运行中的会话可能等待当前回合结束。

CLI `--resume` 不等价于“把桌面切到这个对话”，也不能假定它能接管桌面自己的 app-server。需要分别验证会话归属、运行状态与界面展示。[CLI 实现](https://github.com/openai/codex/blob/main/codex-rs/tui/src/session_queue_commands.rs)

### 当前前台对话：官方复制命令已经手动验证

本次查看的本地生成协议，以及桌面会话列表结果，没有 `focusedThreadId` 或等价的界面选择字段。列表包含 ID、标题、状态和更新时间；这些信息不表示窗口正在显示哪一项。`thread/loaded/list` 也只是内存中已加载的会话。[官方说明](https://learn.chatgpt.com/docs/app-server)

`CODEX_THREAD_ID` 表示正在执行当前代理工具的会话，不会随着用户切换桌面窗口自动变化。根据更新时间、正在运行状态、窗口标题或剪贴板里的旧值去猜目标都不可靠。

Codex 会话内可调用的 `create_thread`、导航等工具不等于第三方常驻程序可以调用的公共本地服务。限定在原生语音聊天中使用的屏幕上下文工具，也不能当作这个后台程序的通用接口。本次未绕过应用界面访问限制。

不过，官方桌面命令文档提供了另一条明确入口：macOS 的 **Command + Option + L（⌘⌥L）** 对应 “Copy chat deep link”，产生 `codex://threads/<thread-id>`。[官方快捷键与深层链接说明](https://learn.chatgpt.com/docs/app/commands)

本次人工验证：

| 操作 | 核对结果 |
|---|---|
| 用户在对话 A 按 ⌘⌥L 并粘贴链接 | 解析出的 UUID 与当前代理的真实 `CODEX_THREAD_ID` 一致 |
| 用户切到另一个已有对话 B，再按 ⌘⌥L | 得到不同 UUID，通过只读 `thread/read` 验证对话存在；未更改目标配置或向 B 发送内容 |

这是直接取出应用生成的标识，不是按标题猜测。出于隐私，A/B 的真实 ID 和对话标题未写入仓库。验证由用户手动操作，后台程序没有模拟快捷键，也没有绕过本会话对 Codex 自身界面的控制限制。

## 录音中轻敲改发新会话

2026-11-15，D3200 固件 04.92 三段对照：两段轻敲震动录音的 1A/08 分片出现 flags=01；无轻敲对照只出现 00 和结束标记 04。延迟轻敲实验在录音约 4.5 秒后首次出现 01，与用户操作对应。此证据来自设备通知，不是根据音频敲击声猜测；其他固件未验证。

实时流解密成功的分片带 bit 0 时，将本段标记为 userMarked，只通知一次。最终 Transfer 保留该标记，因此 UI 回调与停止事件的排队顺序不决定发送目标。录音结束时标记覆盖旧目标，复用一次性创建与投递保护；下一段重新置零。空白页已有新建计划时仍只创建一条，不弹窗。

诊断工具 `swift run AnkerEventProbe` 只记录控制包及音频分片标记，不落盘音频、不转写、不发送；运行前必须关闭正式应用，测试结束需用实体键停止录音。

9 项原有测试通过，新增普通/轻敲/停止/截断分片解析测试通过。真实发送验收完成：用户在历史对话中开始录音，轻敲后浮窗确认新会话；投递记录为 queued，独立读取新会话确认用户文字及“收到。”回复。

## 6. Paseo 桌面端/守护进程适配与豆包空框占位符过滤（2026-11-16）

### 6.1 Paseo 适配器路由设计（参考 Codex 模型）

1. **前台目标读取（`CurrentChat.inspectPaseoTarget` + `PaseoTargetAdapter.captureCurrentTarget`）**：
   - Paseo（`sh.paseo.desktop`）默认无全局复制聊天链接快捷键，改由 Accessibility 先过滤全屏/边缘辅助窗口（`isAuxiliaryWindowMetadata`），并在工作区未产出标签树时激活 `AXManualAccessibility = true` 与 `AXEnhancedUserInterface = true` 对聚焦主窗口做 100ms 间隔双次一致性采样：
     - 独立会话页 URL（`paseo://app/h/<serverId>/agent/<id>`、`paseo://h/<serverId>/agent/<id>`、`https://app.paseo.sh/h/<serverId>/agent/<id>`）直接解析为 `.agentID(id)`。
     - 首页、新建页、会话列表、定时任务、打开项目等空路由识别为 `.blankChat`，触发自动新建独立对话（`CurrentChatError.noChatLink`）。
     - Workspace 工作区路由（`.../h/<serverId>/workspace/<workspaceId>` 与 `.../h/<serverId>/w/<workspaceId>`）：优先读取 `AXDOMIdentifier`/`AXIdentifier` 为 `workspace-tab-*` 的标签节点并校验 `AXSelected`；若 React Native Web 未暴露 DOM ID 或 macOS Chromium 在 `role="button"` 上未暴露 `AXSelected=1`，则提取已选中控件标签或 Paseo 桌面端实时同步到窗口 `kAXTitleAttribute`（`document.title`）的当前聚焦窗格活动标签标题，经 `paseo-chat.py --action resolve-workspace-tab` 向本地守护进程精确比对唯一非归档对话标题（同名重复、多对话分屏、加载中或非对话标签均 **fail-closed** 拒绝猜目标，保留文字在 `PendingStore`；`"新建 Agent"` / `"New Agent"` / `"New tab"` / `"新建标签页"` 识别为 `.blankChat`）。
     - 每次探测都会将脱敏结构摘要写入 `~/Library/Application Support/AnkerVoiceBridge/paseo-ax-diag.json`（也可设 `BEANBRIDGE_PASEO_DIAG=1` 输出到 stderr）用于现场排查。

2. **只读校验、冷启动建聊与投递（`scripts/paseo-chat.py` + `scripts/paseo-daemon-helper.mjs`）**：
   - **校验**：`paseo inspect <id> --json` 校验存在性与非归档状态并读取标题，绝不触发发送或改动会话。
   - **创建**：利用 Paseo 客户端内置 `Paseo Helper`（`ELECTRON_RUN_AS_NODE=1`）运行 `paseo-daemon-helper.mjs`（若 daemon 未运行则先执行 `paseo daemon start`），携带 `idempotencyKey = beanbridge-<messageID>` 在专属目录（默认 `~/Library/Application Support/AnkerVoiceBridge/PaseoVoice`，或通过 `BEANBRIDGE_PASEO_CWD` / `BEANBRIDGE_PASEO_WORKSPACE_ID` 指定）下幂等新建无初始 prompt 的空闲 Agent，生成 `0o600` 创建凭据后再用 `paseo://h/<serverId>/agent/<id>` 拉起 Paseo 窗口。
   - **投递**：生成 `0o600` 排他发送凭据与临时正文文件后执行 `paseo send --no-wait --json --behavior steer --prompt-file <tmp> <id>`；若发送成功写入 `submitted`，若异常或超时则标为 `uncertain` 阻断自动重发。

### 6.2 `DoubaoWork`（`com.work.pc.doubao`）真机适配、空框过滤与单窗口修复

- **工作版窗口状态映射**：`DoubaoWork.app` 在主对话或任务界面暴露 `chrome://doubaowork-chat/chat` 或 `doubaowork://doubaowork-chat`，适配层将其映射为 `.chatID("doubaowork-active")`，并直接通过应用内 Accessibility 焦点激活与粘贴回车提交文字（可设 `BEANBRIDGE_DOUBAO_DIAG=1` 按需开启诊断快照）。
- **25 字空框提示误拦截修复**：实机复现显示，`DoubaoWork.app` 空输入框会将提示文案 `"发消息或创建任务... / 使用技能 @ 添加资料"`（去空格后 25 字）放入 `AXValue` 且不提供 `AXPlaceholderValue`。`CurrentChat.isDoubaoPlaceholderOrEmpty`（标记 `nonisolated`）对该内置空框提示文案做精确前缀+关键字+长度上限（`<= 32`）过滤，确保视觉空框可正常投递，而包含真实用户草稿的任意内容仍继续触发防覆盖保护。
- **冷启动/新建避免弹出双窗口**：实机测试中发现向 `/usr/bin/open -b com.work.pc.doubao` 附加 `doubaowork://...` URL 会让豆包工作版额外拉起一个带 Chrome 外框的 `DoubaoWork Browser.app`（`--saman-launched-by-url`）。修复 [scripts/doubao-chat.py](../../scripts/doubao-chat.py) 与 `DoubaoTargetAdapter.openSession` 后，仅通过 Bundle ID 拉起主应用与辅助功能聚焦唯一主窗口，经用户本机多次退出冷启动与轻敲新建验证，双窗口问题已消除。

### 6.3 本轮验证结果（2026-11-16）

- **Paseo 最大化工作区实机端到端验收**：在本机最大化 `Paseo.app` 工作区（`/workspace/<id>`）窗口下，实测确认 `kAXTitleAttribute` 回退 + `resolve-workspace-tab` 准确锁定当前唯一非归档会话，实体按键录音后成功投递语音文字并真实触发当前 Paseo 会话响应；空白/草稿页（如 `"新建 Agent"`）自动建新会话与轻敲改发新会话待后续实测。
- **全量回归**：`swift test` 共 49 项 XCTest 全部通过；`unittest` 覆盖 `test-create-chat.py`（3 项）、`test-doubao-chat.py`（7 项）、`test-paseo-chat.py`（6 项）共 16 项全部通过。
