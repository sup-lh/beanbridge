# 第三方来源与修改范围

## OpenBean

- 项目：<https://github.com/imraywang/openbean>
- 基准提交：`13968d8ea27ca57fa254bf01c43c13c388f1a696`
- 许可：Apache-2.0；保留 [LICENSE-OpenBean](../LICENSE-OpenBean) 和 [NOTICE-OpenBean](../NOTICE-OpenBean)。
- 来源目录：`Sources/OpenBeanKit/`。BLE、握手、解密、帧解析、Ogg 封装及录音状态模型基于上游。

本仓库在 2026-11-14 至 2026-11-15 作了这些修改：

| 文件 | 修改 |
|---|---|
| `OggOpus.swift` | 将长数组拼接拆成追加语句，解决当前编译器类型检查超时 |
| `RecordingGuard.swift` | 新增 `LiveProbePolicy`，只允许明确空闲状态启动，并只选择唯一新增文件 |
| `Session.swift` | `live` 显式接收既有文件集合；移除选列表第一项的回退；外部停止/断线后不继续发停录命令 |
| `ToolLocator.swift` | 本项目新增的依赖路径查找逻辑，并非上游文件 |

`AnkerButtonVoice`、`AnkerVoiceBridge`、目标配置/模型安装脚本、项目文档与原创图形为本项目新增。本机调试时从上游 CLI 改造的临时诊断文件没有作为另一个官方客户端发布。

## 独立安装的依赖

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)：本地识别程序，按其 MIT 许可分发；本仓库仅调用已安装程序。
- [Whisper](https://github.com/openai/whisper) 与 [ggml 模型分发](https://huggingface.co/ggerganov/whisper.cpp)：模型通过脚本单独下载，不提交权重。
- [FFmpeg](https://ffmpeg.org/)：音频转换与音频设备输出；具体许可取决于所安装构建的配置，本仓库不打包其二进制。
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)：仅为可选的虚拟麦克风路径；独立安装，不复制驱动到本项目发布物。
- [Codex](https://github.com/openai/codex)：使用本地 CLI 与 app-server；模型与账号服务另依其条款。

未来发布安装包时，需要重新核对真正打包进去的组件及其许可。本仓库的 Apache-2.0 不替代外部组件的许可。
