import AppKit
import AVFoundation
import Foundation
import OpenBeanKit
import VoiceRouting

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AnkerVoiceBridge", isDirectory: true)
private let env = ProcessInfo.processInfo.environment
private let ffmpeg = ToolLocator.resolve(name: "ffmpeg", override: env["BEANBRIDGE_FFMPEG"],
                                        preferred: ["/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"], searchPath: env["PATH"]) ?? ""
private let whisper = ToolLocator.resolve(name: "whisper-cli", override: env["BEANBRIDGE_WHISPER"], searchPath: env["PATH"]) ?? ""
let codex = ToolLocator.resolve(name: "codex", override: env["BEANBRIDGE_CODEX"],
    preferred: ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"], searchPath: env["PATH"]) ?? ""
private let model = env["BEANBRIDGE_MODEL"] ?? support.appendingPathComponent("Models/ggml-base.bin").path

private enum ButtonVoiceError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case let .message(value) = self { return value }; return "未知错误" }
}

func runTool(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    var captured = Data()
    try process.run()
    try? output.fileHandleForWriting.close()
    DispatchQueue.global(qos: .userInitiated).async {
        captured = output.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        throw ButtonVoiceError.message("处理超时；本次没有自动重试")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ButtonVoiceError.message("工具退出，状态码 \(process.terminationStatus)")
    }
    return String(decoding: captured, as: UTF8.self)
}

private func localTranscribe(_ wav: URL) throws -> String {
    let raw = try runTool(whisper, ["-m", model, "-l", "zh", "-nt", "-ng",
                                    "--prompt", "安克豆、Codex、飞书、语音识别、测试。",
                                    "-f", wav.path], timeout: 120)
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func transcribeFrames(_ frames: [UInt8]) throws -> String {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("anker-voice-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temp) }
    let ogg = temp.appendingPathComponent("capture.ogg")
    let wav = temp.appendingPathComponent("capture.wav")
    try Data(OggOpus.mux(frames: OggOpus.frames(from: frames))).write(to: ogg, options: .atomic)
    _ = try runTool(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-i", ogg.path,
                              "-ac", "1", "-ar", "16000", wav.path], timeout: 30)
    return try localTranscribe(wav)
}

final class VoicePanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let headline: NSTextField
    private let detail: NSTextField
    private let targetLabel: NSTextField
    var onPending: (() -> Void)?
    var onProbe: (() -> Void)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        headline = NSTextField(labelWithString: "正在连接录音豆…")
        detail = NSTextField(wrappingLabelWithString: "首次按键时锁定前台对话。")
        targetLabel = NSTextField(labelWithString: "目标：尚未开始录音")
        super.init()
        panel.title = "安克豆语音"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        headline.font = .systemFont(ofSize: 16, weight: .semibold)
        headline.frame = NSRect(x: 20, y: 168, width: 420, height: 25)
        detail.font = .systemFont(ofSize: 13)
        detail.maximumNumberOfLines = 3
        detail.frame = NSRect(x: 20, y: 65, width: 420, height: 62)
        targetLabel.frame = NSRect(x: 20, y: 135, width: 420, height: 23)
        targetLabel.font = .systemFont(ofSize: 12, weight: .medium)
        targetLabel.lineBreakMode = .byTruncatingMiddle
        panel.contentView?.addSubview(targetLabel)
        for (index, entry) in [("检测目标", #selector(probe)), ("待发箱", #selector(pending)), ("辅助功能授权", #selector(authorize))].enumerated() {
            let button = NSButton(title: entry.0, target: self, action: entry.1)
            button.frame = NSRect(x: 20 + index * 140, y: 15, width: 130, height: 32)
            panel.contentView?.addSubview(button)
        }
        panel.contentView?.addSubview(headline)
        panel.contentView?.addSubview(detail)
        panel.center()
        panel.orderFrontRegardless()
    }

    @objc private func probe() { onProbe?() }
    @objc private func pending() { onPending?() }
    @objc private func authorize() { Task { @MainActor in CurrentChat.requestAccess() } }

    func setTarget(_ text: String) {
        DispatchQueue.main.async { self.targetLabel.stringValue = "目标：" + text }
    }

    func show(_ title: String, _ text: String) {
        DispatchQueue.main.async {
            self.headline.stringValue = title
            self.detail.stringValue = text
        }
    }

    func showPreview(_ text: String, if active: @escaping () -> Bool) {
        DispatchQueue.main.async {
            guard active() else { return }
            self.headline.stringValue = "正在录音 · 识别预览"
            self.detail.stringValue = text
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }
}

private final class Energy: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: Float = 0
    func add(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var total: Float = 0
        for i in 0..<Int(buffer.frameLength) { total += samples[i] * samples[i] }
        let rms = sqrt(total / Float(buffer.frameLength))
        lock.lock(); highest = max(highest, rms); lock.unlock()
    }
    var hasSound: Bool { lock.lock(); defer { lock.unlock() }; return highest > 0.002 }
}

private final class LivePreview: @unchecked Sendable {
    private let panel: VoicePanel
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "anker.button.preview")
    private var timer: DispatchSourceTimer?
    private var frames: [(UInt32, [UInt8])] = []
    private var received = 0
    private var lastSampled = 0
    private var busy = false
    private var closed = false

    init(panel: VoicePanel) { self.panel = panel }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.2, repeating: 1.5)
        timer.setEventHandler { [weak self] in self?.schedule() }
        self.timer = timer
        timer.resume()
    }

    func append(sequence: UInt32, frame: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        frames.append((sequence, frame))
        received += 1
        if frames.count > 750 { frames.removeFirst(frames.count - 750) }
    }

    func stop() {
        lock.lock(); closed = true; lock.unlock()
        timer?.cancel()
        timer = nil
    }

    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return !closed }

    private func schedule() {
        lock.lock()
        guard !closed, !busy, frames.count >= 40, received != lastSampled else { lock.unlock(); return }
        busy = true
        lastSampled = received
        let olderOmitted = received > frames.count
        let audio = frames.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = try? transcribeFrames(audio)
            self.lock.lock(); self.busy = false; let active = !self.closed; self.lock.unlock()
            guard active, let text, !text.isEmpty, !text.contains("[BLANK_AUDIO]") else { return }
            self.panel.showPreview((olderOmitted ? "…" : "") + text, if: { self.isActive })
        }
    }
}

private final class ButtonCoordinator: @unchecked Sendable {
    private let panel: VoicePanel
    private let router: VoiceRouter
    private var processing = false
    private let dryRun: Bool
    private let events = DispatchQueue(label: "anker.button.events")
    private let submissions = DispatchQueue(label: "anker.button.submissions")
    private var link: Link?
    private var session: D3200Session?
    private var active: (stream: RealtimeStream, energy: Energy, preview: LivePreview, route: Task<RouteResult, Never>, token: UUID)?

    init(panel: VoicePanel, router: VoiceRouter, dryRun: Bool) {
        self.panel = panel; self.router = router; self.dryRun = dryRun
    }

    func connect() async {
        do {
            for (name, path) in [("ffmpeg", ffmpeg), ("whisper-cli", whisper), ("codex", codex)] {
                guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                    throw ButtonVoiceError.message("找不到可执行程序：\(name)。请查看 README。")
                }
            }
            guard FileManager.default.fileExists(atPath: model) else {
                throw ButtonVoiceError.message("找不到本地语音模型，请运行 scripts/setup-model.sh。")
            }
            let link = Link()
            self.link = link
            link.onDisconnect = { [weak self] in
                guard let self else { return }
                self.events.async {
                    self.active?.preview.stop()
                    self.active = nil
                    self.panel.show("录音豆已断开", "请关闭窗口后重新启动；设备上的录音会保留。")
                }
            }
            try await link.waitPoweredOn()
            let devices = await link.scan(seconds: 5).filter(\.serviceMatch)
            guard devices.count == 1, let device = devices.first else {
                throw ButtonVoiceError.message(devices.isEmpty ? "没有找到录音豆，请断开手机飞书并唤醒设备。" : "附近发现多台录音豆，请先只保留一台。")
            }
            try await link.connect(device.peripheral)
            let session = D3200Session(link: link)
            self.session = session
            guard let info = try await session.deviceInfo(), info.recording == false else {
                throw ButtonVoiceError.message("录音豆正在录音或状态未知，请先结束录音后重启。")
            }
            try await session.handshake()
            guard let current = try await session.deviceInfo(), current.recording == false else {
                throw ButtonVoiceError.message("录音状态已变化，请先结束录音后重启。")
            }
            session.observeEvents { [weak self] event in
                self?.events.async { [weak self] in self?.handle(event) }
            }
            panel.show("准备就绪，按一下录音豆", "首次按键锁定目标，再按一次结束并\(dryRun ? "仅测试识别" : "排队发送")。目标不明时保存到待发箱。")
        } catch {
            panel.show("连接失败", String(describing: error))
        }
    }

    private func handle(_ event: DeviceEvent) {
        switch event {
        case let .recordingStarted(fileID):
            guard active == nil, let session else { return }
            guard !processing else {
                panel.show("上一条仍在处理", "本段不会发送；请再按一次停止设备录音，等处理完成后重试。")
                return
            }
            let token = UUID()
            let route = Task { await router.resolve() }
            panel.setTarget("正在读取…")
            do {
                let decoder = try OpusDecoder()
                let energy = Energy()
                let preview = LivePreview(panel: panel)
                let stream = try session.startRealtime(fileId: fileID) { sequence, frame in
                    if let decoded = try? decoder.decode(frame) { energy.add(decoded) }
                    preview.append(sequence: sequence, frame: frame)
                }
                active = (stream, energy, preview, route, token)
                Task {
                    let result = await route.value
                    self.events.async {
                        guard self.active?.token == token else { return }
                        self.panel.setTarget(result.createNew ? "录音结束后新建独立对话" : (result.target?.title ?? "待选择（不会自动发送）"))
                    }
                }
                preview.start()
                panel.show("正在录音", "稍等一秒后说话；再按一次录音豆结束。")
            } catch {
                panel.show("无法接收音频", "\(error)。设备可能仍在录音，请按录音豆按钮结束。")
            }
        case .recordingStopped:
            guard let current = active else { return }
            active = nil
            current.preview.stop()
            guard let transfer = current.stream.stop() else {
                panel.show("音频接收失败", "录音仍保存在设备上，本次没有发送。")
                return
            }
            guard transfer.decrypted, transfer.missingSeqs == 0, transfer.audio.count >= 160 * 15,
                  transfer.audio.count <= 160 * 50 * 300, current.energy.hasSound else {
                panel.show("没有发送", "音频为空、不完整或超过 5 分钟；录音仍保存在设备上。")
                return
            }
            panel.show("正在生成最终文字…", "\(dryRun ? "本轮只测试识别。" : "完成后放入指定对话的队列。")")
            processing = true
            let audio = transfer.audio
            Task {
                let destination = await current.route.value
                submissions.async { [weak self] in
                    guard let self else { return }
                    self.transcribeAndSubmit(audio, destination: destination)
                    self.events.async { self.processing = false }
                }
            }
        case .charging, .battery:
            break
        }
    }

    private func transcribeAndSubmit(_ audio: [UInt8], destination: RouteResult) {
        do {
            let text = try transcribeFrames(audio)
            guard !text.isEmpty, !text.contains("[BLANK_AUDIO]") else {
                panel.show("没有识别到内容", "本次没有发送；录音仍保存在设备上。")
                return
            }
            if dryRun {
                panel.show("识别完成（测试模式）", text)
                return
            }
            try router.deliver(text: text, destination: destination, panel: panel)
        } catch {
            panel.show("本次没有确认发送", "\(error)。请查看待发箱；录音仍保存在设备上。")
        }
    }
}

@main private struct Main {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--self-test-frames"),
           index + 1 < CommandLine.arguments.count {
            do {
                let audio = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                guard !audio.isEmpty, audio.count % OggOpus.frameSize == 0 else {
                    throw ButtonVoiceError.message("测试帧格式无效")
                }
                print(try transcribeFrames(Array(audio)))
            } catch { fputs("帧识别测试失败：\(error)\n", stderr); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--self-test"),
           index + 1 < CommandLine.arguments.count {
            do { print(try localTranscribe(URL(fileURLWithPath: CommandLine.arguments[index + 1]))) }
            catch { fputs("识别测试失败：\(error)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let router = VoiceRouter()
        if CommandLine.arguments.contains("--probe-target") {
            Task { @MainActor in
                if CommandLine.arguments.contains("--request-access") { CurrentChat.requestAccess() }
                let result = await router.resolve(forceCurrent: true)
                let payload = ProbeResult(target: result.target, error: result.reason)
                if let data = try? JSONEncoder().encode(payload) {
                    if let index = CommandLine.arguments.firstIndex(of: "--probe-output"), index + 1 < CommandLine.arguments.count {
                        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
                    } else { print(String(decoding: data, as: UTF8.self)) }
                }
                exit(result.target == nil ? 1 : 0)
            }
            app.run()
            return
        }
        let panel = VoicePanel()
        panel.onPending = { router.showPending(panel: panel) }
        panel.onProbe = {
            panel.show("三秒后检测目标", "请将目标 Codex 对话置于前台。检测不会发送消息。")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let result = await router.resolve(forceCurrent: true)
                panel.setTarget(result.target?.title ?? "未取得")
                panel.show(result.target == nil ? "未取得目标" : "目标检测成功", result.reason ?? "已读取并验证当前对话，未发送消息。")
            }
        }
        Task.detached {
            let dryRun = CommandLine.arguments.contains("--dry-run") || FileManager.default.fileExists(atPath: support.appendingPathComponent("dry-run").path)
            let coordinator = ButtonCoordinator(panel: panel, router: router, dryRun: dryRun)
            activeCoordinator = coordinator
            await coordinator.connect()
        }
        app.run()
    }
}

private var activeCoordinator: ButtonCoordinator?
