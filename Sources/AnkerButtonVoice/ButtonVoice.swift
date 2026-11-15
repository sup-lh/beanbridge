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

private let sharedASRService = ASRService(
    supportDirectory: support,
    whisperExecutable: whisper,
    ffmpegExecutable: ffmpeg
)

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
    try sharedASRService.transcribeFile(wav, isPreview: false)
}

private func transcribeFrames(_ frames: [UInt8]) throws -> String {
    try sharedASRService.transcribeOpusFrames(frames, isPreview: false)
}

// MARK: - 浮窗面板 (VoicePanel)

final class VoicePanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let headline: NSTextField
    private let detail: NSTextField
    private let targetLabel: NSTextField
    private let connectionLabel: NSTextField
    private let targetAppPopUp: NSPopUpButton
    private let targetLockBadge: NSTextField
    private let cancelButton: NSButton

    var onPending: (() -> Void)?
    var onProbe: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onOpenWorkbench: (() -> Void)?
    var onSelectDefaultApp: ((String) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    private var adapterIDs: [String] = []

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 285),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        headline = NSTextField(labelWithString: "正在连接录音豆…")
        detail = NSTextField(wrappingLabelWithString: "首次按键时锁定前台对话；关闭此窗口后仍在菜单栏常驻监听。")
        targetLabel = NSTextField(labelWithString: "目标：尚未开始录音")
        connectionLabel = NSTextField(labelWithString: "蓝牙：正在初始化…")
        targetAppPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        targetLockBadge = NSTextField(labelWithString: "")
        cancelButton = NSButton(title: "取消本条", target: nil, action: nil)
        super.init()

        panel.title = "安克豆语音"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        headline.font = .systemFont(ofSize: 16, weight: .semibold)
        headline.frame = NSRect(x: 20, y: 238, width: 500, height: 24)

        connectionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        connectionLabel.textColor = .secondaryLabelColor
        connectionLabel.lineBreakMode = .byTruncatingTail
        connectionLabel.frame = NSRect(x: 20, y: 212, width: 500, height: 18)

        let appPickerLabel = NSTextField(labelWithString: "默认目标应用：")
        appPickerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        appPickerLabel.frame = NSRect(x: 20, y: 180, width: 92, height: 20)
        panel.contentView?.addSubview(appPickerLabel)

        targetAppPopUp.frame = NSRect(x: 112, y: 177, width: 130, height: 26)
        targetAppPopUp.target = self
        targetAppPopUp.action = #selector(targetAppSelectionChanged)
        panel.contentView?.addSubview(targetAppPopUp)

        targetLockBadge.font = .systemFont(ofSize: 11, weight: .regular)
        targetLockBadge.textColor = .secondaryLabelColor
        targetLockBadge.lineBreakMode = .byTruncatingTail
        targetLockBadge.frame = NSRect(x: 250, y: 180, width: 270, height: 18)
        panel.contentView?.addSubview(targetLockBadge)

        targetLabel.frame = NSRect(x: 20, y: 148, width: 500, height: 22)
        targetLabel.font = .systemFont(ofSize: 12, weight: .medium)
        targetLabel.lineBreakMode = .byTruncatingMiddle
        panel.contentView?.addSubview(targetLabel)

        detail.font = .systemFont(ofSize: 13)
        detail.maximumNumberOfLines = 4
        detail.frame = NSRect(x: 20, y: 66, width: 500, height: 74)

        let buttons: [(String, Selector, CGFloat, CGFloat)] = [
            ("检测目标", #selector(probe), 20, 84),
            ("待发箱", #selector(pending), 112, 72),
            ("工作台/灵感箱", #selector(openWorkbench), 192, 118),
            ("辅助功能授权", #selector(authorize), 318, 108)
        ]
        for entry in buttons {
            let button = NSButton(title: entry.0, target: self, action: entry.1)
            button.bezelStyle = .rounded
            button.frame = NSRect(x: entry.2, y: 16, width: entry.3, height: 32)
            panel.contentView?.addSubview(button)
        }

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelCurrentRecording)
        cancelButton.frame = NSRect(x: 434, y: 16, width: 86, height: 32)
        cancelButton.isEnabled = false
        panel.contentView?.addSubview(cancelButton)

        panel.contentView?.addSubview(headline)
        panel.contentView?.addSubview(connectionLabel)
        panel.contentView?.addSubview(detail)
        panel.center()
        panel.orderFrontRegardless()
    }

    @objc private func probe() { onProbe?() }
    @objc private func pending() { onPending?() }
    @objc private func openWorkbench() { onOpenWorkbench?() }
    @objc private func cancelCurrentRecording() { onCancelRecording?() }
    @objc private func authorize() { Task { @MainActor in CurrentChat.requestAccess() } }

    @objc private func targetAppSelectionChanged() {
        let idx = targetAppPopUp.indexOfSelectedItem
        guard idx >= 0, idx < adapterIDs.count else { return }
        onSelectDefaultApp?(adapterIDs[idx])
    }

    func configureTargetApps(
        adapters: [any AppTargetAdapter],
        selectedAppID: String,
        lockedByEnvironment: Bool,
        asrModelSummary: String
    ) {
        DispatchQueue.main.async {
            self.targetAppPopUp.removeAllItems()
            self.adapterIDs = adapters.map(\.appID)
            for (idx, adapter) in adapters.enumerated() {
                self.targetAppPopUp.addItem(withTitle: adapter.displayName)
                if adapter.appID == selectedAppID {
                    self.targetAppPopUp.selectItem(at: idx)
                }
            }
            self.targetAppPopUp.isEnabled = !lockedByEnvironment
            if lockedByEnvironment {
                self.targetLockBadge.stringValue = "已由环境变量锁定 ｜ ASR: \(asrModelSummary)"
            } else {
                self.targetLockBadge.stringValue = "ASR: \(asrModelSummary)"
            }
        }
    }

    func setRecordingCancelable(_ cancelable: Bool) {
        DispatchQueue.main.async {
            self.cancelButton.isEnabled = cancelable
        }
    }

    func setConnectionSummary(_ text: String) {
        DispatchQueue.main.async {
            self.connectionLabel.stringValue = text
        }
    }

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

    func showPanel() {
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
            self.onVisibilityChanged?(true)
        }
    }

    func hidePanel() {
        DispatchQueue.main.async {
            self.panel.orderOut(nil)
            self.onVisibilityChanged?(false)
        }
    }

    func togglePanel() {
        DispatchQueue.main.async {
            if self.panel.isVisible {
                self.panel.orderOut(nil)
                self.onVisibilityChanged?(false)
            } else {
                NSApplication.shared.activate(ignoringOtherApps: true)
                self.panel.makeKeyAndOrderFront(nil)
                self.onVisibilityChanged?(true)
            }
        }
    }

    /// 关闭浮窗时仅隐藏窗口而不终止进程，保持菜单栏常驻与 BLE 不断线。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel.orderOut(nil)
        onVisibilityChanged?(false)
        return false
    }
}

// MARK: - 菜单栏常驻控制器 (MenuBarController)

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let panel: VoicePanel
    private let router: VoiceRouter
    private let workbench: WorkbenchPanel
    private let asrService: ASRService

    var onProbe: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onReconnectNow: (() -> Void)?

    private var connectionStatusText = "蓝牙：正在初始化…"
    private var deviceBatteryText = "电量：未知"
    private var isRecording = false

    init(
        panel: VoicePanel,
        router: VoiceRouter,
        workbench: WorkbenchPanel,
        asrService: ASRService
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = panel
        self.router = router
        self.workbench = workbench
        self.asrService = asrService
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusBarAppearance(state: .disconnected, status: DeviceStatus())
        rebuildMenu()
    }

    func updateStatusBarAppearance(state: BLEConnectionState, status: DeviceStatus, countdownSeconds: Int? = nil) {
        isRecording = (status.recording == true)
        let title: String
        switch state {
        case .connected:
            if status.recording == true {
                title = "🔴 安克豆·录音中"
            } else if let bat = status.micBattery {
                title = "🎙️ 安克豆 \(bat)%"
            } else {
                title = "🎙️ 安克豆"
            }
        case let .reconnecting(attempt):
            if let cd = countdownSeconds, cd > 0 {
                title = "🔄 重连#\(attempt)(\(cd)s)"
            } else {
                title = "🔄 重连#\(attempt)"
            }
        case .scanning, .connecting:
            title = "⏳ 安克豆…"
        case .sleeping:
            title = "🌙 安克豆·休眠"
        case .disconnected:
            title = "⚪️ 安克豆·未连接"
        }
        statusItem.button?.title = title

        connectionStatusText = Self.describeConnection(state: state, countdownSeconds: countdownSeconds)
        deviceBatteryText = Self.describeDeviceStatus(status)
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }

    func rebuildMenu() {
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let connItem = NSMenuItem(title: connectionStatusText, action: nil, keyEquivalent: "")
        connItem.isEnabled = false
        menu.addItem(connItem)

        let batItem = NSMenuItem(title: deviceBatteryText, action: nil, keyEquivalent: "")
        batItem.isEnabled = false
        menu.addItem(batItem)

        let modelResolved = asrService.modelManager.resolveModel()
        let asrItem = NSMenuItem(title: "识别模型：\(modelResolved.displayLabel)", action: nil, keyEquivalent: "")
        asrItem.isEnabled = false
        menu.addItem(asrItem)

        if let activeDownload = asrService.downloadManager.activeProgressSummary() {
            let dlItem = NSMenuItem(title: activeDownload, action: nil, keyEquivalent: "")
            dlItem.isEnabled = false
            menu.addItem(dlItem)
        }

        menu.addItem(.separator())

        let toggleTitle = panel.panel.isVisible ? "隐藏语音浮窗" : "显示语音浮窗"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(togglePanel), keyEquivalent: "v")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let wbItem = NSMenuItem(title: "打开灵感收集箱与工作台…", action: #selector(openWorkbench), keyEquivalent: "b")
        wbItem.target = self
        menu.addItem(wbItem)

        let pendingItem = NSMenuItem(title: "打开待发箱…", action: #selector(openPending), keyEquivalent: "p")
        pendingItem.target = self
        menu.addItem(pendingItem)

        let probeItem = NSMenuItem(title: "3 秒后检测当前目标对话", action: #selector(probeTarget), keyEquivalent: "")
        probeItem.target = self
        menu.addItem(probeItem)

        let cancelItem = NSMenuItem(title: "取消本条录音（不转写不发送）", action: #selector(cancelRecording), keyEquivalent: "")
        cancelItem.target = self
        cancelItem.isEnabled = isRecording
        menu.addItem(cancelItem)

        menu.addItem(.separator())

        // 默认目标 App 子菜单
        let targetSubmenu = NSMenu()
        let currentAppID = router.defaultAppID()
        let locked = router.isTargetAppLockedByEnvironment
        if locked {
            let lockNotice = NSMenuItem(title: "已由环境变量 BEANBRIDGE_TARGET_APP 锁定", action: nil, keyEquivalent: "")
            lockNotice.isEnabled = false
            targetSubmenu.addItem(lockNotice)
            targetSubmenu.addItem(.separator())
        }
        for adapter in router.availableAdapters {
            let item = NSMenuItem(title: adapter.displayName, action: #selector(selectTargetApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = adapter.appID
            item.state = (adapter.appID == currentAppID) ? .on : .off
            item.isEnabled = !locked
            targetSubmenu.addItem(item)
        }
        let targetRoot = NSMenuItem(title: "默认目标应用（当前：\(router.defaultAdapter().displayName)）", action: nil, keyEquivalent: "")
        targetRoot.submenu = targetSubmenu
        menu.addItem(targetRoot)

        // ASR 模型与热词设置
        let modelItem = NSMenuItem(title: "ASR 模型管理与下载…", action: #selector(openModelSettings), keyEquivalent: "")
        modelItem.target = self
        menu.addItem(modelItem)

        let hotwordItem = NSMenuItem(title: "编辑专业术语热词表…", action: #selector(openHotwordSettings), keyEquivalent: "")
        hotwordItem.target = self
        menu.addItem(hotwordItem)

        let reconnectItem = NSMenuItem(title: "立即重新连接录音豆", action: #selector(reconnectNow), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出安克豆语音", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func togglePanel() {
        panel.togglePanel()
        rebuildMenu()
    }

    @objc private func openWorkbench() {
        workbench.showWindow()
    }

    @objc private func openPending() {
        router.showPending(panel: panel)
    }

    @objc private func probeTarget() {
        onProbe?()
    }

    @objc private func cancelRecording() {
        onCancelRecording?()
    }

    @objc private func selectTargetApp(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? String else { return }
        _ = try? router.setDefaultAppID(appID)
        rebuildMenu()
    }

    @objc private func openModelSettings() {
        workbench.openModelSelector()
        rebuildMenu()
    }

    @objc private func openHotwordSettings() {
        workbench.openHotwordEditor()
        rebuildMenu()
    }

    @objc private func reconnectNow() {
        onReconnectNow?()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    nonisolated static func describeConnection(state: BLEConnectionState, countdownSeconds: Int? = nil) -> String {
        switch state {
        case .connected:
            return "蓝牙：已连接录音豆"
        case .scanning:
            return "蓝牙：正在扫描附近录音豆…"
        case .connecting:
            return "蓝牙：正在连接并握手…"
        case let .reconnecting(attempt):
            if let cd = countdownSeconds, cd > 0 {
                return "蓝牙：断线自动重连中（第 \(attempt) 次，\(cd) 秒后重试）"
            }
            return "蓝牙：断线自动重连中（第 \(attempt) 次尝试）"
        case .sleeping:
            return "蓝牙：系统睡眠挂起（唤醒后自动重连）"
        case .disconnected:
            return "蓝牙：未连接"
        }
    }

    nonisolated static func describeDeviceStatus(_ status: DeviceStatus) -> String {
        var parts: [String] = []
        if let mic = status.micBattery {
            parts.append("录音豆 \(mic)%\(status.micCharging ? "(充电中)" : "")")
        }
        if let box = status.caseBattery {
            parts.append("充电盒 \(box)%\(status.caseCharging ? "(充电中)" : "")")
        }
        if let rec = status.recording {
            parts.append(rec ? "状态：录音中" : "状态：空闲")
        }
        if !status.firmware.isEmpty {
            parts.append("固件 \(status.firmware)")
        }
        return parts.isEmpty ? "设备信息：等待同步" : parts.joined(separator: " ｜ ")
    }
}

// MARK: - 能量检测与无 ffmpeg 内存滑动窗口预览 (Energy & LivePreview)

private final class Energy: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: Float = 0

    @discardableResult
    func add(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var total: Float = 0
        for i in 0..<Int(buffer.frameLength) { total += samples[i] * samples[i] }
        let rms = sqrt(total / Float(buffer.frameLength))
        lock.lock(); highest = max(highest, rms); lock.unlock()
        return rms
    }

    var hasSound: Bool { lock.lock(); defer { lock.unlock() }; return highest > 0.002 }
}

/// 实时预览器：在内存中直接累积由 `OpusDecoder` 解码并降采样后的 16kHz PCM16 样本与每帧能量，
/// 避免每次预览拉起 `ffmpeg` 子进程，且仅当滑动窗口内新增有效人声能量帧时才触发 `whisper-cli`。
private final class LivePreview: @unchecked Sendable {
    private static let maxWindowFrames = 750 // 约 15 秒滑动窗口（每帧 20ms）
    private static let minFramesForPreview = 40
    private static let voiceEnergyThreshold: Float = 0.003

    private struct DecodedFrame {
        let sequence: UInt32
        let samples16k: [Int16]
        let rms: Float
    }

    private let panel: VoicePanel
    private let asrService: ASRService
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "anker.button.preview")
    private var timer: DispatchSourceTimer?
    private var frames: [DecodedFrame] = []
    private var fallbackDecoder: OpusDecoder?
    private var received = 0
    private var voicedReceived = 0
    private var lastSampled = 0
    private var lastVoicedSampled = 0
    private var busy = false
    private var closed = false

    init(panel: VoicePanel, asrService: ASRService = sharedASRService) {
        self.panel = panel
        self.asrService = asrService
        self.fallbackDecoder = try? OpusDecoder()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.2, repeating: 1.5)
        timer.setEventHandler { [weak self] in self?.schedule() }
        self.timer = timer
        timer.resume()
    }

    /// 直接追加已由 `OpusDecoder` 解码的 48kHz PCM 缓冲及对应 RMS 能量（零重复解码、零 `ffmpeg` 进程）。
    func appendDecoded(sequence: UInt32, pcmBuffer48k: AVAudioPCMBuffer, rms: Float) {
        let samples16k = AudioResampler.downsample48kTo16kPCM16(pcmBuffer48k)
        guard !samples16k.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        frames.append(DecodedFrame(sequence: sequence, samples16k: samples16k, rms: rms))
        received += 1
        if rms >= Self.voiceEnergyThreshold {
            voicedReceived += 1
        }
        if frames.count > Self.maxWindowFrames {
            frames.removeFirst(frames.count - Self.maxWindowFrames)
        }
    }

    /// 兼容直接传入裸 Opus 帧的入口（内部使用内存 `OpusDecoder` 解码降采样）。
    func append(sequence: UInt32, frame: [UInt8]) {
        lock.lock()
        let isClosed = closed
        let decoder = fallbackDecoder
        lock.unlock()
        guard !isClosed, let decoder, let pcm = try? decoder.decode(frame) else { return }
        let rms = AudioVADslicer.calculateRMS(pcm)
        appendDecoded(sequence: sequence, pcmBuffer48k: pcm, rms: rms)
    }

    func stop() {
        lock.lock(); closed = true; frames.removeAll(); lock.unlock()
        timer?.cancel()
        timer = nil
    }

    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return !closed }

    private func schedule() {
        lock.lock()
        // 仅当收到新帧且自上次采样以来存在新增有效语音能量帧时才触发 whisper-cli
        guard !closed,
              !busy,
              frames.count >= Self.minFramesForPreview,
              received != lastSampled,
              voicedReceived > lastVoicedSampled else {
            lock.unlock()
            return
        }
        busy = true
        lastSampled = received
        lastVoicedSampled = voicedReceived
        let olderOmitted = received > frames.count
        let orderedFrames = frames.sorted { $0.sequence < $1.sequence }
        var windowSamples: [Int16] = []
        windowSamples.reserveCapacity(orderedFrames.count * 320)
        for item in orderedFrames {
            windowSamples.append(contentsOf: item.samples16k)
        }
        lock.unlock()

        let asr = self.asrService
        DispatchQueue.global(qos: .userInitiated).async {
            let text = try? asr.transcribePCM16Samples(windowSamples, isPreview: true)
            self.lock.lock()
            self.busy = false
            let active = !self.closed
            self.lock.unlock()
            guard active, let text, !text.isEmpty else { return }
            self.panel.showPreview((olderOmitted ? "…" : "") + text, if: { self.isActive })
        }
    }
}

// MARK: - 蓝牙与录音主协调器 (ButtonCoordinator)

private final class ButtonCoordinator: @unchecked Sendable {
    private let panel: VoicePanel
    private let router: VoiceRouter
    private let asrService: ASRService
    private let workbench: WorkbenchPanel
    private let menuBar: MenuBarController
    private let reconnectCoordinator: ReconnectCoordinator
    private var processing = false
    private let dryRun: Bool
    private let events = DispatchQueue(label: "anker.button.events")
    private let submissions = DispatchQueue(label: "anker.button.submissions")
    private var countdownTask: Task<Void, Never>?
    private var cancelledRecording = false
    private var active: (
        fileID: UInt32,
        stream: RealtimeStream,
        energy: Energy,
        preview: LivePreview,
        route: Task<RouteResult, Never>,
        token: UUID,
        marked: Bool
    )?

    init(
        panel: VoicePanel,
        router: VoiceRouter,
        asrService: ASRService,
        workbench: WorkbenchPanel,
        menuBar: MenuBarController,
        dryRun: Bool
    ) {
        self.panel = panel
        self.router = router
        self.asrService = asrService
        self.workbench = workbench
        self.menuBar = menuBar
        self.dryRun = dryRun
        self.reconnectCoordinator = ReconnectCoordinator()
        setupReconnectCallbacks()
    }

    var currentSession: D3200Session? {
        reconnectCoordinator.session
    }

    private func setupReconnectCallbacks() {
        reconnectCoordinator.onConnectionStateChange = { [weak self] newState in
            guard let self else { return }
            self.events.async {
                self.handleConnectionStateChange(newState)
            }
        }
        reconnectCoordinator.onStatusChange = { [weak self] updatedStatus in
            guard let self else { return }
            self.refreshConnectionUI(state: self.reconnectCoordinator.state, status: updatedStatus)
        }
        reconnectCoordinator.onDeviceEvent = { [weak self] event in
            guard let self else { return }
            self.events.async {
                self.reconnectCoordinator.updateStatus(with: event)
                self.handle(event)
            }
        }
        reconnectCoordinator.onSessionReady = { [weak self] _, info in
            guard let self else { return }
            self.events.async {
                if let info {
                    self.reconnectCoordinator.updateStatus(with: info)
                }
                self.cancelledRecording = false
                if info?.recording == true {
                    self.panel.show("已连接（设备正在录音）", "检测到录音豆正在录音中，请按一下录音豆结束当前录音后再开始新对话。")
                } else {
                    let appName = self.router.defaultAdapter().displayName
                    self.panel.show(
                        "准备就绪，按一下录音豆",
                        "首次按键锁定\(appName)目标，再按一次结束并\(self.dryRun ? "仅测试识别" : "排队发送")。目标不明时保存到待发箱。"
                    )
                }
            }
        }
    }

    private func handleConnectionStateChange(_ state: BLEConnectionState) {
        countdownTask?.cancel()
        countdownTask = nil

        switch state {
        case .scanning:
            panel.show("正在寻找录音豆…", "请确认手机飞书已暂时断开连接并唤醒录音豆。")
            refreshConnectionUI(state: state, status: reconnectCoordinator.status)
        case .connecting:
            panel.show("正在连接录音豆…", "已发现设备，正在完成蓝牙握手与状态同步。")
            refreshConnectionUI(state: state, status: reconnectCoordinator.status)
        case .connected:
            refreshConnectionUI(state: state, status: reconnectCoordinator.status)
        case let .reconnecting(attempt):
            if let current = active {
                current.preview.stop()
                active = nil
                panel.setRecordingCancelable(false)
            }
            let totalSeconds = max(1, Int(reconnectCoordinator.policy.delay(forAttempt: attempt).rounded()))
            panel.show(
                "录音豆连接中断 · 自动重连中",
                "正在进行第 \(attempt) 次后台重连（退避等待约 \(totalSeconds) 秒）；设备上的录音会完整保留，可通过工作台增量同步。"
            )
            startReconnectCountdown(attempt: attempt, seconds: totalSeconds)
        case .sleeping:
            if let current = active {
                current.preview.stop()
                active = nil
                panel.setRecordingCancelable(false)
            }
            panel.show("系统进入睡眠", "蓝牙监听已挂起；Mac 唤醒后将自动恢复连接。")
            refreshConnectionUI(state: state, status: reconnectCoordinator.status)
        case .disconnected:
            if let current = active {
                current.preview.stop()
                active = nil
                panel.setRecordingCancelable(false)
            }
            refreshConnectionUI(state: state, status: reconnectCoordinator.status)
        }
    }

    private func startReconnectCountdown(attempt: Int, seconds: Int) {
        refreshConnectionUI(state: .reconnecting(attempt: attempt), status: reconnectCoordinator.status, countdownSeconds: seconds)
        countdownTask = Task { [weak self] in
            var remaining = seconds
            while remaining > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                guard let self, self.reconnectCoordinator.state == .reconnecting(attempt: attempt) else { return }
                self.refreshConnectionUI(
                    state: .reconnecting(attempt: attempt),
                    status: self.reconnectCoordinator.status,
                    countdownSeconds: max(0, remaining)
                )
            }
        }
    }

    private func refreshConnectionUI(state: BLEConnectionState, status: DeviceStatus, countdownSeconds: Int? = nil) {
        let connDesc = MenuBarController.describeConnection(state: state, countdownSeconds: countdownSeconds)
        let devDesc = MenuBarController.describeDeviceStatus(status)
        panel.setConnectionSummary("\(connDesc) ｜ \(devDesc)")
        Task { @MainActor in
            self.menuBar.updateStatusBarAppearance(state: state, status: status, countdownSeconds: countdownSeconds)
        }
    }

    func connect() async {
        do {
            for (name, path) in [("ffmpeg", ffmpeg), ("whisper-cli", whisper)] {
                guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                    throw ButtonVoiceError.message("找不到可执行程序：\(name)。请查看 README。")
                }
            }
            if router.defaultAppID() == "codex" {
                guard !codex.isEmpty, FileManager.default.isExecutableFile(atPath: codex) else {
                    throw ButtonVoiceError.message("找不到可执行程序：codex。请查看 README 或切换默认目标应用。")
                }
            }
            let resolvedModel = asrService.modelManager.resolveModel()
            guard resolvedModel.exists else {
                throw ButtonVoiceError.message("找不到本地语音模型（\(resolvedModel.path)），请运行 scripts/setup-model.sh。")
            }
            _ = try await reconnectCoordinator.connect(scanSeconds: 5.0)
        } catch {
            panel.show("连接失败", "\(error)（可在菜单栏点击“立即重新连接录音豆”重试）")
            refreshConnectionUI(state: reconnectCoordinator.state, status: reconnectCoordinator.status)
        }
    }

    /// 录音进行中用户点击“取消本条”：立即停止/丢弃当前流与实时预览，后续收到硬件 `.recordingStopped` 时静默忽略。
    func cancelActiveRecording() {
        events.async { [weak self] in
            guard let self, let current = self.active else { return }
            self.active = nil
            self.cancelledRecording = true
            current.route.cancel()
            current.preview.stop()
            _ = current.stream.stop()
            self.panel.setRecordingCancelable(false)
            self.panel.setTarget("本条已取消（不会转写或投递）")
            self.panel.show("已取消本条录音", "当前实时语音流已丢弃；若设备红灯仍亮，再按一下录音豆结束硬件录音即可（将自动静默忽略）。")
        }
    }

    private func handle(_ event: DeviceEvent) {
        switch event {
        case let .recordingStarted(fileID):
            cancelledRecording = false
            guard active == nil, let session = reconnectCoordinator.session else { return }
            guard !processing else {
                panel.show("上一条仍在处理", "本段不会发送；请再按一次停止设备录音，等处理完成后重试。")
                return
            }
            let token = UUID()
            let defaultApp = router.defaultAdapter()
            let route = Task { await router.resolve() }
            panel.setTarget("正在读取 \(defaultApp.displayName) 目标…")
            do {
                let decoder = try OpusDecoder()
                let energy = Energy()
                let preview = LivePreview(panel: panel, asrService: asrService)
                let stream = try session.startRealtime(fileId: fileID, onUserMark: { [weak self] in
                    self?.events.async { [weak self] in
                        guard let self, self.active?.token == token else { return }
                        self.active?.marked = true
                        let appName = self.router.defaultAdapter().displayName
                        self.panel.setTarget("轻敲已确认 · 结束后发往\(appName)新会话并归档灵感箱")
                    }
                }) { sequence, frame in
                    if let decoded = try? decoder.decode(frame) {
                        let rms = energy.add(decoded)
                        preview.appendDecoded(sequence: sequence, pcmBuffer48k: decoded, rms: rms)
                    }
                }
                active = (fileID, stream, energy, preview, route, token, false)
                panel.setRecordingCancelable(true)
                Task {
                    let result = await route.value
                    self.events.async {
                        guard self.active?.token == token, self.active?.marked == false else { return }
                        let appLabel = self.router.adapter(for: result.appID)?.displayName ?? result.appID
                        if result.createNew {
                            self.panel.setTarget("\(appLabel) · 录音结束后新建独立对话")
                        } else if let target = result.target {
                            self.panel.setTarget("\(appLabel) · \(target.title)")
                        } else {
                            self.panel.setTarget("\(appLabel) · 待选择（不会自动发送）")
                        }
                    }
                }
                preview.start()
                panel.show("正在录音", "稍等一秒后说话；再按一次录音豆结束，或点击“取消本条”放弃发送。")
            } catch {
                panel.setRecordingCancelable(false)
                panel.show("无法接收音频", "\(error)。设备可能仍在录音，请按录音豆按钮结束。")
            }
        case .recordingStopped:
            if cancelledRecording, active == nil {
                cancelledRecording = false
                panel.setRecordingCancelable(false)
                panel.show("本条录音已取消", "硬件已停止录音，本次未执行语音转写与投递。")
                return
            }
            guard let current = active else { return }
            active = nil
            panel.setRecordingCancelable(false)
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
            let fileID = current.fileID
            let audio = transfer.audio
            let userMarked = transfer.userMarked || current.marked
            Task {
                let initialDestination = await current.route.value
                let destination = initialDestination.applyingUserMark(userMarked)
                submissions.async { [weak self] in
                    guard let self else { return }
                    self.transcribeAndSubmit(
                        fileID: fileID,
                        audio: audio,
                        userMarked: userMarked,
                        destination: destination
                    )
                    self.events.async { self.processing = false }
                }
            }
        case .charging, .battery:
            break
        }
    }

    private func transcribeAndSubmit(
        fileID: UInt32,
        audio: [UInt8],
        userMarked: Bool,
        destination: RouteResult
    ) {
        do {
            let text = try asrService.transcribeOpusFrames(audio, isPreview: false)
            guard !text.isEmpty else {
                panel.show("没有识别到内容", "本次没有发送；录音仍保存在设备上。")
                return
            }
            Task { @MainActor in
                self.workbench.ingestRealtimeRecording(
                    fileId: fileID,
                    rawOpus: audio,
                    userMarked: userMarked,
                    transcript: text
                )
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

// MARK: - CLI 入口与应用生命周期 (@main)

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
                let payload = ProbeResult(target: result.target, error: result.reason, appID: result.appID)
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
        MainActor.assumeIsolated {
            let workbench = WorkbenchPanel(
                supportDirectory: support,
                asrService: sharedASRService,
                router: router,
                voicePanel: panel
            )
            let menuBar = MenuBarController(
                panel: panel,
                router: router,
                workbench: workbench,
                asrService: sharedASRService
            )
            activeWorkbench = workbench
            activeMenuBar = menuBar

            let syncTargetSelectorUI: () -> Void = {
                let modelSummary = sharedASRService.modelManager.resolveModel().displayLabel
                panel.configureTargetApps(
                    adapters: router.availableAdapters,
                    selectedAppID: router.defaultAppID(),
                    lockedByEnvironment: router.isTargetAppLockedByEnvironment,
                    asrModelSummary: modelSummary
                )
                workbench.refreshTargetAdapters()
                workbench.refreshASRInfo()
                menuBar.rebuildMenu()
            }

            syncTargetSelectorUI()

            router.onTargetAppChanged = { selectedAdapter in
                syncTargetSelectorUI()
                panel.setTarget("默认应用已切换为 \(selectedAdapter.displayName)")
            }

            workbench.onASRConfigurationChanged = {
                syncTargetSelectorUI()
            }

            panel.onSelectDefaultApp = { appID in
                do {
                    _ = try router.setDefaultAppID(appID)
                } catch {
                    panel.show("无法切换默认目标应用", String(describing: error))
                }
            }

            panel.onVisibilityChanged = { _ in
                menuBar.rebuildMenu()
            }

            let triggerProbe: () -> Void = {
                let appName = router.defaultAdapter().displayName
                panel.show("三秒后检测目标", "请将目标 \(appName) 对话置于前台。检测不会发送消息。")
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let result = await router.resolve(forceCurrent: true)
                    let appLabel = router.adapter(for: result.appID)?.displayName ?? result.appID
                    if let target = result.target {
                        panel.setTarget("\(appLabel) · \(target.title)")
                    } else {
                        panel.setTarget("\(appLabel) · 未取得")
                    }
                    panel.show(
                        result.target == nil ? "未取得目标" : "目标检测成功",
                        result.reason ?? "已读取并验证当前 \(appLabel) 对话，未发送消息。"
                    )
                }
            }

            panel.onPending = { router.showPending(panel: panel) }
            panel.onProbe = triggerProbe
            panel.onOpenWorkbench = { workbench.showWindow() }
            panel.onCancelRecording = { activeCoordinator?.cancelActiveRecording() }

            menuBar.onProbe = triggerProbe
            menuBar.onCancelRecording = { activeCoordinator?.cancelActiveRecording() }
            menuBar.onReconnectNow = {
                Task.detached {
                    await activeCoordinator?.connect()
                }
            }

            workbench.sessionProvider = { activeCoordinator?.currentSession }

            let dryRun = CommandLine.arguments.contains("--dry-run")
                || FileManager.default.fileExists(atPath: support.appendingPathComponent("dry-run").path)
            let coordinator = ButtonCoordinator(
                panel: panel,
                router: router,
                asrService: sharedASRService,
                workbench: workbench,
                menuBar: menuBar,
                dryRun: dryRun
            )
            activeCoordinator = coordinator
            Task.detached {
                await coordinator.connect()
            }
        }
        app.run()
    }
}

private var activeCoordinator: ButtonCoordinator?
@MainActor private var activeWorkbench: WorkbenchPanel?
@MainActor private var activeMenuBar: MenuBarController?
