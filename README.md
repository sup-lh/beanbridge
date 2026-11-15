<p align="center">
  <img src="docs/assets/banner.svg" alt="BeanBridge — Press. Speak. Send." width="100%" />
</p>

<h1 align="center">豆桥 · BeanBridge</h1>

<p align="center">给 Codex 对话接上一颗实体语音按钮。</p>
<p align="center"><b>按一下说话 · 看浮窗预览 · 再按一下发送</b></p>
<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="docs/field-notes.md">完整实验记录</a> ·
  <a href="docs/context-routing.md">自动选对话方案</a> ·
  <a href="docs/brand.md">视觉物料</a>
</p>

---

BeanBridge 将 soundcore Work / 安克 AI 录音豆 D3200 通过蓝牙连接到 Mac，在本机完成语音识别，并把最终文字发送到指定的 Codex 对话。你可以离开键盘口述需求，再用录音豆的第二次按键结束这一条消息。

**这是已在一台 Mac、一颗 04.92 固件设备上验证的实验原型。** 固定对话的完整发送链路已成功；新版已实现首次按键读取并锁定前台对话，自动读取与“录音后切换对话、仍投递原目标”的实体按键入队链路在本机通过测试。录音开始时 Codex 未运行或已无窗口，会在识别后创建独立新会话、打开桌面并投递；关闭后的真实按键测试已收到新会话回复。后台重连仍属于设计阶段。

## 两种使用方式

| | 按键语音应用 · 推荐 | 虚拟麦克风桥 |
|---|---|---|
| 开始 | 按一次录音豆 | 启动脚本，由程序开始录音 |
| 说话 | 浮窗显示本地识别预览 | 在 Codex 点麦克风输入 |
| 结束 | 再按一次，最终文字自动排队发送 | 终端按 Control-C |
| 识别 | whisper.cpp，在 Mac 本地完成 | 由使用麦克风的应用处理 |
| 发送目标 | 首次按键时读取并锁定的前台 Codex 对话 | 当前由你操作的输入框 |
| 额外依赖 | 本地 Whisper 模型，约 141 MiB | BlackHole 2ch |

![当前按键语音的数据流](docs/assets/flow.svg)

音频在本机转写，**最终文字会进入 Codex**，并按你使用的 Codex 账号和模型配置处理。录音豆仍会保存自己的录音，恢复手机连接后可能同步到飞书。

## 已经验证

- [x] D3200 蓝牙发现、握手和实时音频解码。
- [x] 实体按键开始 / 结束，浮窗实时预览。
- [x] 中文短句本地转写，以及最终文字进入指定对话队列。
- [x] 对话实际收到按键助手发送的消息，而不只是显示“已入队”。
- [x] BlackHole 麦克风方式接入 Codex 语音输入。
- [x] 麦克风桥启动时切换输入，正常退出时恢复原输入。

> **每段录音的目标在首次按键时锁定。** 浮窗显示目标标题，录音中切换对话不会改目标。读取失败时文字保存在本地待发箱，绝不使用旧的固定目标。第二次按键会自动提交最终识别文字，预览和最终结果可能有差异。

## 快速开始

### 1. 准备环境

实测环境：Apple 芯片、macOS 26.6.2、Xcode 26.2、Codex CLI 0.167.0、whisper.cpp 1.9.5。Swift 包声明最低 macOS 14，但更早系统和 Intel Mac 尚未实测。

需要 Xcode / Swift 开发工具、Python 3、已登录的 Codex，以及以下程序：

```bash
gh repo clone sup-lh/beanbridge
cd beanbridge
brew install ffmpeg whisper.cpp
./scripts/setup-model.sh
```

模型安装脚本核对 SHA-256；若已有正确模型会直接复用。它不会安装 BlackHole，按键模式也不需要 BlackHole。

### 2. 选择路由方式

默认使用 `current` 模式，无需预先绑定。打开目标 Codex 对话，并保持它在前台。程序会在第一次按键时触发官方 **⌘⌥L** 复制聊天链接，两次独立复制一致且窗口未变后，通过只读 `thread/read` 校验并锁定目标。

首次使用，在浮窗点击「辅助功能授权」，然后在「系统设置 → 隐私与安全性 → 辅助功能」中允许「安克豆按键语音」。点击「检测目标」后有 3 秒切回 Codex，检测仅显示目标，不发送消息。

Codex 不在前台、存在多个窗口、未取得新链接或缺少权限时，继续接收录音，最终文字进入「待发箱」。可以在待发箱粘贴明确的聊天链接后发送；不会读取旧剪贴板猜目标。

若要继续使用原来的固定目标模式：

```bash
python3 scripts/set-target.py --thread-id "替换为目标会话的 UUID"
printf 'fixed\n' > "$HOME/Library/Application Support/AnkerVoiceBridge/routing-mode"
```

删除 `routing-mode` 文件或将内容改为 `current` 即恢复自动模式。固定目标保存在同目录的 `target-thread`；`set-target.py --check` 仅验证，`--json` 返回校验结果，均不改配置。

### 3. 构建并连接

```bash
./build-button-app.sh
open "dist/安克豆按键语音.app"
```

在 iPhone「设置 → 蓝牙」暂时关闭蓝牙，或以其他方式确保手机飞书没有占用录音豆连接。将录音豆放到 Mac 附近，确认它当前没有在录音。保留原有设备绑定即可。

首次运行需要蓝牙权限。如果没有自动弹窗，可在「系统设置 → 隐私与安全性 → 蓝牙」添加 `安克豆按键语音.app`，授权后退出并重新打开。

### 4. 按一下，说话，再按一下

| 步骤 | 你做什么 | 浮窗表现 |
|---|---|---|
| 就绪 | 等待连接成功 | 准备就绪，按一下录音豆 |
| 开始 | 将 Codex 对话置前，短按一次，等目标标题出现再切换页面 | 正在录音，显示锁定目标和识别预览 |
| 结束 | 再短按一次 | 正在生成最终文字 |
| 提交 | 无需再点发送 | 已放入 Codex 队列 |

Codex 忙时消息可能等待当前回合结束。**“已放入队列”表示入队成功，不保证模型立即开始处理。** 最终应以目标对话实际出现消息为准。

结束使用时先用实体键停止录音，再关闭浮窗。关闭浮窗会退出应用，但不保证设备本身停止录音。之后可以恢复手机蓝牙。

<details>
<summary><b>只测试识别，不自动发送</b></summary>

关闭应用后运行：

```bash
touch "$HOME/Library/Application Support/AnkerVoiceBridge/dry-run"
open "dist/安克豆按键语音.app"
```

恢复自动发送：关闭应用，删除上述 `dry-run` 标记，再打开应用。

</details>

<details>
<summary><b>使用 BlackHole 虚拟麦克风</b></summary>

这条路径适合继续使用 Codex 自带的麦克风输入。先安装 [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)，按安装器要求重启。仓库不附带其安装包。

```bash
brew install blackhole-2ch
swift build -c release --product anker-voice-bridge
.build/release/anker-voice-bridge
```

等待“实时音频已接通”，然后在 Codex 点击麦克风。程序自动开始录音，这时不要再按录音豆按钮。终端按 Control-C 结束；正常退出会恢复启动前的系统输入。如果运行期间你手动换了输入，它会保留你的选择。

异常退出时请检查录音灯及系统输入。程序最长运行一小时；它不是全天录音服务。请勿与按键应用同时运行。

</details>

## 自动路由与待发箱

| 场景 | 当前行为 |
|---|---|
| Codex 在前台、只有一个窗口且显示已有对话 | 首次按键读取并校验该对话，锁定到本段录音结束 |
| 刚打开的新建空白页，没有聊天链接 | 录音结束后自动新建独立会话并发送，不弹确认框 |
| 录音中切换到其他对话 | 仍然投递到浮窗显示的锁定目标 |
| 无权限、Codex 在后台、多窗口或未取得链接 | 保存文字；在待发箱粘贴明确链接后发送 |
| 提交超时、程序中断或结果不明 | 保留记录供核对，不自动重试 |
| Codex 未运行或已关闭所有窗口 | 识别完成后创建独立会话，启动/打开 Codex 并投递 |

空白页尚未建立可复制的对话 ID。按用户设置：前台与窗口检查通过，但复制链接超时后，会在录音结束时自动新建独立会话。快捷键失效也会走这个新建路径，不会误投旧会话；新会话不继承空白页里选的项目、模型或草稿。权限不足、焦点变化等其他错误仍进入待发箱。待发箱里尚无目标的文字也可直接选择“新建独立会话并发送”。

待发记录位于 `~/Library/Application Support/AnkerVoiceBridge/Pending`，文件权限为 600、目录为 700，不上传仓库。包含最终文字、目标和投递状态；入队后的记录也保留在本机，可自行清理。`queued` 只说明 CLI 返回成功，最终以目标聊天实际出现消息为准。

新会话不绑定项目，每条使用 `~/Library/Application Support/AnkerVoiceBridge/Chats/<消息 ID>` 作为独立工作目录。空录音不建聊，首次按键时决定创建计划；录音中手动打开其他聊天也不会改发到该聊天。Codex 仅在后台或最小化时不视为关闭。已退出应用不需要辅助功能来判定；判断“所有窗口已关闭”仍需要辅助功能权限。`fixed` 模式继续遵守固定目标。

创建回执保存在同目录下的 `Creation` 文件夹。先取得真实 ID 并持久化，再打开桌面和排队投递；超时或结果不明时不会自动再建一个会话。创建助手在取得持久会话后退出，模型执行交给桌面，不在独立助手中启动模型回合。

实测与剩余边界见 [自动选对话实现说明](docs/context-routing.md)。

## 限制与排错

- **识别准确度**：当前使用 Whisper base，专有名词、中英混说和短音节可能误听；不要把预览当作最终稿。
- **长度**：按键模式在结束后检查音频，超过 5 分钟不自动发送；这不是录满 5 分钟就自动停录。
- **重连**：应用初次扫描约 5 秒，断线后需重新打开；后台重连、开机启动尚未实现。
- **轻量程度**：空闲时保持 BLE 连接；说话时预览反复启动识别进程，尚未做 CPU、续航和全天压力测试。
- **声音数据**：仓库没有原始录音；程序正常处理完成会清理本机临时音频，崩溃时仍可能残留临时文件。设备录音不会自动删除。
- **权限与签名**：应用是本机临时签名，重建会改变签名，可能需要重新授权蓝牙及辅助功能；没有 Apple 公证发布包。若辅助功能列表显示开启但检测仍无权限，可运行 `tccutil reset Accessibility dev.codex.anker-button-voice` 仅重置本应用，再用“+”添加当前 `dist/安克豆按键语音.app` 并开启。
- **发送失败**：先持久化文字再提交；超时或中断的消息不会自动重发，需在目标聊天核对。CLI 没有本项目可用的幂等投递键，因此不承诺严格的一次投递保证。

更多故障现象和原因见 [踩坑记录](docs/field-notes.md)。

## 开发与验证

```bash
swift build -c release
swift test
python3 scripts/set-target.py --check
python3 scripts/test-create-chat.py
```

程序会查找常见安装目录及 `PATH`。特殊位置可使用 `BEANBRIDGE_FFMPEG`、`BEANBRIDGE_WHISPER`、`BEANBRIDGE_CODEX`、`BEANBRIDGE_MODEL`；通过环境变量配置时应从同一终端直接运行可执行文件，Finder 启动的应用不保证继承终端环境。路由可用 `BEANBRIDGE_ROUTING=current|fixed` 覆盖；若仅改了复制快捷键的字母，可用 `BEANBRIDGE_COPY_KEYCODE` 指定 macOS 虚拟键码（默认 37，即 L，修饰键仍为 Command + Option）。

```text
Sources/AnkerButtonVoice/    按键事件、预览、本地识别、队列发送
Sources/AnkerVoiceBridge/    音频桥、系统输入切换与恢复
Sources/OpenBeanKit/         改编自 OpenBean 的协议实现
Sources/VoiceRouting/        前台目标检测、链接校验、持久化投递状态
scripts/                    模型安装、对话绑定、视觉物料生成
docs/                       实验记录、产品设想、路由方案、品牌物料
```

## 来源与许可

设备协议及相关 Swift 实现来自 [OpenBean](https://github.com/imraywang/openbean)，基准提交 `13968d8ea27ca57fa254bf01c43c13c388f1a696`。本项目补充了 Codex 队列连接、独立浮窗、音频桥、状态检查、文档及视觉物料。变更范围见 [第三方来源](docs/third-party.md)。

仓库代码、文档及原创图形采用 [Apache-2.0](LICENSE)；上游声明保留在 [NOTICE-OpenBean](NOTICE-OpenBean)。外部安装的 BlackHole、whisper.cpp 和语音模型遵循各自许可。本项目与 Anker、飞书及 OpenAI 无官方关联。
