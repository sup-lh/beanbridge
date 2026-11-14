import AVFoundation
import Darwin
import Foundation
import OpenBeanKit

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    func request() { lock.lock(); requested = true; lock.unlock() }
    var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}

final class PCMWriter: @unchecked Sendable {
    private let output: FileHandle
    private let stop: StopFlag
    private let queue = DispatchQueue(label: "anker-voice.pcm")
    private let lock = NSLock()
    private var pending = 0
    private var announced = false
    private var dropped = 0
    private let maxPending = 48_000 * MemoryLayout<Float>.size

    init(_ output: FileHandle, stop: StopFlag) { self.output = output; self.stop = stop }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        guard bytes > 0 else { return }
        let data = Data(bytes: channel, count: bytes)
        lock.lock()
        guard pending + bytes <= maxPending else { dropped += 1; lock.unlock(); return }
        pending += bytes
        let first = !announced
        announced = true
        lock.unlock()
        if first { log("实时音频已接通，可以在 Codex 中开启语音输入。") }
        queue.async {
            do { try self.output.write(contentsOf: data) }
            catch { log("音频输出已中断：\(error.localizedDescription)"); self.stop.request() }
            self.lock.lock(); self.pending -= bytes; self.lock.unlock()
        }
    }

    func close() {
        queue.sync { try? output.close() }
        lock.lock(); let count = dropped; lock.unlock()
        if count > 0 { log("音频拥塞，丢弃了 \(count) 个音频片段。") }
    }
}

func outputIndex(ffmpeg: String) throws -> Int {
    let process = Process()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = ["-nostdin", "-hide_banner", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                         "-t", "0.01", "-f", "audiotoolbox", "-list_devices", "true", "-"]
    process.standardInput = FileHandle.nullDevice
    process.standardError = errorPipe
    process.standardOutput = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    guard finished.wait(timeout: .now() + 8) == .success else {
        process.terminate()
        throw LinkError.timeout("音频设备检测")
    }
    try? errorPipe.fileHandleForWriting.close()
    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)
    let regex = try NSRegularExpression(pattern: #"\[(\d+)\]\s+BlackHole 2ch,\s*BlackHole2ch_UID"#)
    let range = NSRange(output.startIndex..., in: output)
    guard let match = regex.firstMatch(in: output, range: range),
          let valueRange = Range(match.range(at: 1), in: output),
          let value = Int(output[valueRange]) else {
        throw LinkError.missing("BlackHole 2ch 虚拟音频设备；请先按 README 安装")
    }
    return value
}

func runBridge() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let ffmpeg = ToolLocator.resolve(name: "ffmpeg", override: env["BEANBRIDGE_FFMPEG"],
        preferred: ["/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"], searchPath: env["PATH"]) else {
        throw LinkError.missing("ffmpeg")
    }
    let index = try outputIndex(ffmpeg: ffmpeg)
    let stop = StopFlag()
    let deviceChanged = StopFlag()
    signal(SIGPIPE, SIG_IGN)
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { log("正在结束本次语音输入…"); stop.request() }
        source.resume()
        sources.append(source)
    }

    let link = Link()
    link.onDisconnect = { log("录音豆连接中断。"); deviceChanged.request(); stop.request() }
    try await link.waitPoweredOn()
    log("正在寻找录音豆，请保持 iPhone 飞书暂时断开连接…")
    let devices = await link.scan(seconds: 5).filter(\.serviceMatch)
    guard devices.count == 1, let device = devices.first else {
        throw LinkError.missing(devices.isEmpty ? "录音豆" : "唯一的录音豆（附近发现多台）")
    }
    try await link.connect(device.peripheral)
    let session = D3200Session(link: link)
    guard let info = try await session.deviceInfo(), LiveProbePolicy.mayStart(recording: info.recording) else {
        throw LinkError.missing("空闲的录音豆；设备正在录音或状态未知")
    }
    let existing = Set(try await session.listFiles().map(\.id))
    try await session.handshake()
    guard let latest = try await session.deviceInfo(), LiveProbePolicy.mayStart(recording: latest.recording) else {
        throw LinkError.missing("空闲的录音豆；连接时录音状态已变化")
    }
    let decoder = try OpusDecoder()
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error",
                         "-f", "f32le", "-ar", "48000", "-ac", "1", "-i", "pipe:0",
                         "-ac", "2", "-ar", "44100", "-f", "audiotoolbox",
                         "-audio_device_index", String(index), "-"]
    process.standardInput = pipe
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    let writer = PCMWriter(pipe.fileHandleForWriting, stop: stop)
    defer {
        writer.close()
        process.waitUntilExit()
        sources.forEach { $0.cancel() }
    }
    let inputSwitch = try SystemInputSwitch()
    defer { inputSwitch.restoreIfUnchanged() }
    try inputSwitch.activate()
    log("已将系统输入切换为 BlackHole 2ch，退出后会自动恢复。")
    link.onEvent = { packet in
        if case .recordingStopped = DeviceEvent(packet: packet) {
            deviceChanged.request()
            stop.request()
        }
    }
    log("已连接录音豆，准备开始本次语音输入（按 Control-C 结束）。")
    let transfer = try await session.live(
        seconds: 3600, existingFileIDs: existing,
        onFrame: { _, frame in
            do { writer.enqueue(try decoder.decode(frame)) }
            catch { log("音频解码失败：\(error.localizedDescription)"); stop.request() }
        },
        shouldStop: { stop.isRequested || !process.isRunning },
        mayStopDevice: { !deviceChanged.isRequested }
    ) { _, _ in }
    log("本次语音输入结束；设备中保留录音。接收分片缺失：\(transfer.missingSeqs)。")
}

@main struct Main {
    static func main() async {
        do { try await runBridge() }
        catch { log("无法启动语音桥：\(error)"); exit(1) }
    }
}
