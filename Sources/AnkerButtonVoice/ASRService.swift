import AVFoundation
import Foundation
import OpenBeanKit

// MARK: - 1. 热词管理 (HotwordManager，模型目录与下载管理已由 OpenBeanKit 提供)

final class HotwordManager: @unchecked Sendable {
    static let fileName = "hotwords.txt"

    static let defaultHotwords: [String] = [
        "安克豆",
        "BeanBridge",
        "Codex",
        "豆包",
        "Doubao",
        "飞书",
        "Feishu",
        "Whisper",
        "whisper-cli",
        "Opus",
        "BLE",
        "待发箱",
        "灵感收集箱",
        "工作台",
        "语音识别",
        "Prompt",
        "Agent",
        "Swift",
        "Python"
    ]

    let supportDirectory: URL
    let hotwordsFileURL: URL
    private let lock = NSLock()

    init(supportDirectory: URL = support) {
        self.supportDirectory = supportDirectory
        self.hotwordsFileURL = supportDirectory.appendingPathComponent(Self.fileName)
    }

    /// 首次不存在时自动生成默认热词文件（目录 0o700，文件 0o600）。
    @discardableResult
    func ensureDefaultFileIfNeeded() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try ASRModelManager.ensureSecureDir(supportDirectory, fileManager: fm)
        if !fm.fileExists(atPath: hotwordsFileURL.path) {
            let content = Self.formatFileContent(words: Self.defaultHotwords)
            try ASRModelManager.writeSecureFile(Data(content.utf8), to: hotwordsFileURL, fileManager: fm)
            return Self.defaultHotwords
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hotwordsFileURL.path)
        let raw = (try? String(contentsOf: hotwordsFileURL, encoding: .utf8)) ?? ""
        let parsed = Self.parseHotwords(from: raw)
        return parsed.isEmpty ? Self.defaultHotwords : parsed
    }

    /// 读取并去重热词列表；若文件尚不存在则自动初始化默认热词。
    func loadHotwords() -> [String] {
        if let words = try? ensureDefaultFileIfNeeded(), !words.isEmpty {
            return words
        }
        return Self.defaultHotwords
    }

    /// 覆盖保存热词列表（自动去重，保持顺序，权限 0o700/0o600）。
    @discardableResult
    func saveHotwords(_ words: [String]) throws -> [String] {
        let normalized = Self.deduplicate(words)
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try ASRModelManager.ensureSecureDir(supportDirectory, fileManager: fm)
        let content = Self.formatFileContent(words: normalized)
        try ASRModelManager.writeSecureFile(Data(content.utf8), to: hotwordsFileURL, fileManager: fm)
        return normalized
    }

    /// 从多行或分隔符文本直接保存热词列表。
    @discardableResult
    func saveFromText(_ rawText: String) throws -> [String] {
        let parsed = Self.parseHotwords(from: rawText)
        return try saveHotwords(parsed)
    }

    /// 新增单个或多个热词。
    @discardableResult
    func add(_ newWord: String) throws -> [String] {
        var current = loadHotwords()
        let additions = Self.parseHotwords(from: newWord)
        current.append(contentsOf: additions)
        return try saveHotwords(current)
    }

    /// 删除指定热词（大小写不敏感匹配）。
    @discardableResult
    func remove(_ word: String) throws -> [String] {
        let target = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return loadHotwords() }
        let filtered = loadHotwords().filter { $0.lowercased() != target }
        return try saveHotwords(filtered)
    }

    /// 修改替换某个热词。
    @discardableResult
    func update(oldWord: String, newWord: String) throws -> [String] {
        let oldTrimmed = oldWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let newTrimmed = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty else {
            return try add(newTrimmed)
        }
        var current = loadHotwords()
        if let idx = current.firstIndex(where: { $0.lowercased() == oldTrimmed }) {
            if newTrimmed.isEmpty {
                current.remove(at: idx)
            } else {
                current[idx] = newTrimmed
            }
        } else if !newTrimmed.isEmpty {
            current.append(newTrimmed)
        }
        return try saveHotwords(current)
    }

    /// 重置为默认热词表。
    @discardableResult
    func resetToDefaults() throws -> [String] {
        try saveHotwords(Self.defaultHotwords)
    }

    /// 去重合并为 `--prompt` 注入 `whisper-cli` 的引导词。
    func whisperPrompt(maxCount: Int = 48) -> String {
        let words = Array(loadHotwords().prefix(maxCount))
        guard !words.isEmpty else {
            return "以下是普通话与中英混说语音记录。"
        }
        return words.joined(separator: "、") + "。"
    }

    static func parseHotwords(from raw: String) -> [String] {
        var tokens: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }
            let parts = trimmedLine.components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
            for part in parts {
                let clean = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    tokens.append(clean)
                }
            }
        }
        return deduplicate(tokens)
    }

    static func deduplicate(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in words {
            let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let key = clean.lowercased()
            if seen.insert(key).inserted {
                result.append(clean)
            }
        }
        return result
    }

    private static func formatFileContent(words: [String]) -> String {
        let header = "# BeanBridge 语音识别热词表（每行一个词，支持中文与英文术语）\n"
        let body = words.joined(separator: "\n")
        return header + body + (body.isEmpty ? "" : "\n")
    }
}

// MARK: - 3. 内存 48kHz -> 16kHz PCM16 降采样与 WAV 封装 (AudioResampler)

enum AudioResampler {
    /// 将 `OpusDecoder` 解出的 48kHz 单声道 Float32 缓冲区按 3:1 低通均值降采样为 16kHz Int16 采样。
    static func downsample48kTo16kPCM16(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }
        let outCount = frameCount / 3
        guard outCount > 0 else { return [] }
        var out = [Int16]()
        out.reserveCapacity(outCount)
        for i in 0..<outCount {
            let base = i * 3
            let avg = (channel[base] + channel[base + 1] + channel[base + 2]) * (1.0 / 3.0)
            let clamped = max(-1.0, min(1.0, avg))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            out.append(scaled)
        }
        return out
    }

    /// 将多帧裸 Opus 字节流直接在内存中通过 `OpusDecoder` 解码并降采样为 16kHz PCM16。
    static func decodeOpusFramesTo16kPCM16(_ rawOpusBytes: [UInt8]) throws -> (samples: [Int16], peakRMS: Float) {
        let decoder = try OpusDecoder()
        let packets = OggOpus.frames(from: rawOpusBytes)
        var allSamples: [Int16] = []
        allSamples.reserveCapacity(packets.count * 320)
        var peakRMS: Float = 0
        for packet in packets where !packet.isEmpty {
            let pcmBuffer = try decoder.decode(packet)
            let rms = AudioVADslicer.calculateRMS(pcmBuffer)
            if rms > peakRMS { peakRMS = rms }
            allSamples.append(contentsOf: downsample48kTo16kPCM16(pcmBuffer))
        }
        return (allSamples, peakRMS)
    }

    /// 封装 16kHz 单声道 16-bit 小端 PCM 为标准 RIFF WAVE 文件字节。
    static func encodeWAV16kMono(samples: [Int16]) -> Data {
        let sampleRate: UInt32 = 16_000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let byteRate: UInt32 = sampleRate * UInt32(blockAlign)
        let dataBytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        let riffChunkSize = 36 + dataBytes

        var data = Data()
        data.reserveCapacity(44 + Int(dataBytes))

        func appendASCII(_ text: String) {
            data.append(contentsOf: text.utf8)
        }
        func appendU16LE(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendU32LE(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendU32LE(riffChunkSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32LE(16) // PCM fmt chunk size
        appendU16LE(1)  // AudioFormat = 1 (PCM)
        appendU16LE(numChannels)
        appendU32LE(sampleRate)
        appendU32LE(byteRate)
        appendU16LE(blockAlign)
        appendU16LE(bitsPerSample)
        appendASCII("data")
        appendU32LE(dataBytes)

        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                data.append(UnsafeBufferPointer(start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
                                                count: Int(dataBytes)))
            }
        }
        return data
    }
}

// MARK: - 4. 高精度语音识别与预览服务 (ASRService)

final class ASRService: @unchecked Sendable {
    let modelManager: ASRModelManager
    let downloadManager: ASRModelDownloadManager
    let hotwordManager: HotwordManager
    private let whisperExecutableOverride: String?
    private let ffmpegExecutableOverride: String?
    private let environmentProvider: @Sendable () -> [String: String]

    init(
        supportDirectory: URL = support,
        modelManager: ASRModelManager? = nil,
        downloadManager: ASRModelDownloadManager? = nil,
        hotwordManager: HotwordManager? = nil,
        whisperExecutable: String? = nil,
        ffmpegExecutable: String? = nil,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        let resolvedModelManager = modelManager ?? ASRModelManager(
            supportDirectory: supportDirectory,
            environmentProvider: environmentProvider
        )
        self.modelManager = resolvedModelManager
        self.downloadManager = downloadManager ?? ASRModelDownloadManager(
            modelManager: resolvedModelManager,
            environmentProvider: environmentProvider
        )
        self.hotwordManager = hotwordManager ?? HotwordManager(supportDirectory: supportDirectory)
        self.whisperExecutableOverride = whisperExecutable
        self.ffmpegExecutableOverride = ffmpegExecutable
        self.environmentProvider = environmentProvider
        _ = try? self.hotwordManager.ensureDefaultFileIfNeeded()
    }

    var whisperExecutable: String {
        if let whisperExecutableOverride, !whisperExecutableOverride.isEmpty {
            return whisperExecutableOverride
        }
        let env = environmentProvider()
        return ToolLocator.resolve(
            name: "whisper-cli",
            override: env["BEANBRIDGE_WHISPER"],
            searchPath: env["PATH"]
        ) ?? ""
    }

    var ffmpegExecutable: String {
        if let ffmpegExecutableOverride, !ffmpegExecutableOverride.isEmpty {
            return ffmpegExecutableOverride
        }
        let env = environmentProvider()
        return ToolLocator.resolve(
            name: "ffmpeg",
            override: env["BEANBRIDGE_FFMPEG"],
            preferred: ["/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"],
            searchPath: env["PATH"]
        ) ?? ""
    }

    /// 解析语音识别语言配置（默认 `zh`，支持环境变量 `BEANBRIDGE_ASR_LANG` 覆盖，如 `auto` 或 `zh`）。
    var language: String {
        if let raw = environmentProvider()["BEANBRIDGE_ASR_LANG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        return "zh"
    }

    /// 构造最终高精度转写参数（中文及中英混说友好：注入热词 prompt、温度回退、抑制非语音标记）。
    func finalTranscriptionArguments(wavPath: String, modelPath: String? = nil) -> [String] {
        let resolvedModel = modelPath ?? modelManager.resolveModel().path
        let prompt = hotwordManager.whisperPrompt()
        var args: [String] = [
            "-m", resolvedModel,
            "-l", language,
            "-nt",
            "-sns",
            "--temperature", "0.0",
            "--temperature-inc", "0.2",
            "--entropy-thold", "2.40",
            "--no-speech-thold", "0.60"
        ]
        if environmentProvider()["BEANBRIDGE_WHISPER_NO_GPU"] == "1" {
            args.append("-ng")
        }
        if !prompt.isEmpty {
            args += ["--prompt", prompt]
        }
        args += ["-f", wavPath]
        return args
    }

    /// 构造实时快速预览参数（Greedy 解码、关闭温度回退以降低延迟）。
    func previewTranscriptionArguments(wavPath: String, modelPath: String? = nil) -> [String] {
        let resolvedModel = modelPath ?? modelManager.resolveModel().path
        let prompt = hotwordManager.whisperPrompt(maxCount: 24)
        var args: [String] = [
            "-m", resolvedModel,
            "-l", language,
            "-nt",
            "-nf",
            "-sns",
            "-bo", "1",
            "-bs", "1"
        ]
        if environmentProvider()["BEANBRIDGE_WHISPER_NO_GPU"] == "1" {
            args.append("-ng")
        }
        if !prompt.isEmpty {
            args += ["--prompt", prompt]
        }
        args += ["-f", wavPath]
        return args
    }

    /// 对单个 WAV/音频文件执行最终高精度转写并清洗噪声占位符。
    func transcribeFile(_ fileURL: URL, isPreview: Bool = false) throws -> String {
        let exe = whisperExecutable
        guard !exe.isEmpty, FileManager.default.isExecutableFile(atPath: exe) else {
            throw ASRServiceError.message("找不到可执行程序：whisper-cli。请查看 README。")
        }
        let resolved = modelManager.resolveModel()
        guard resolved.exists else {
            throw ASRServiceError.message("找不到本地语音模型（\(resolved.path)），请运行 scripts/setup-model.sh。")
        }
        let args = isPreview
            ? previewTranscriptionArguments(wavPath: fileURL.path, modelPath: resolved.path)
            : finalTranscriptionArguments(wavPath: fileURL.path, modelPath: resolved.path)
        let raw = try runTool(exe, args, timeout: isPreview ? 25 : 120)
        return Self.cleanTranscript(raw)
    }

    /// 直接从内存 16kHz PCM16 样本写出临时 WAV 并调用 `whisper-cli`（用于无 `ffmpeg` 开销的实时预览或快速转写）。
    func transcribePCM16Samples(_ samples: [Int16], isPreview: Bool = true) throws -> String {
        guard !samples.isEmpty else { return "" }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anker-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let wavURL = tempDir.appendingPathComponent("slice.wav")
        let wavData = AudioResampler.encodeWAV16kMono(samples: samples)
        try wavData.write(to: wavURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wavURL.path)
        return try transcribeFile(wavURL, isPreview: isPreview)
    }

    /// 对裸 Opus 帧串执行转写：优先使用内存 `OpusDecoder` 解码降采样为 16kHz WAV，若失败则回退 `ffmpeg` 转码。
    func transcribeOpusFrames(_ frames: [UInt8], isPreview: Bool = false) throws -> String {
        if let decoded = try? AudioResampler.decodeOpusFramesTo16kPCM16(frames),
           !decoded.samples.isEmpty {
            return try transcribePCM16Samples(decoded.samples, isPreview: isPreview)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("anker-voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temp,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temp) }
        let ogg = temp.appendingPathComponent("capture.ogg")
        let wav = temp.appendingPathComponent("capture.wav")
        try Data(OggOpus.mux(frames: OggOpus.frames(from: frames))).write(to: ogg, options: .atomic)
        let ffmpegExe = ffmpegExecutable
        guard !ffmpegExe.isEmpty, FileManager.default.isExecutableFile(atPath: ffmpegExe) else {
            throw ASRServiceError.message("找不到可执行程序：ffmpeg。请查看 README。")
        }
        _ = try runTool(
            ffmpegExe,
            ["-nostdin", "-loglevel", "error", "-y", "-i", ogg.path, "-ac", "1", "-ar", "16000", wav.path],
            timeout: 30
        )
        return try transcribeFile(wav, isPreview: isPreview)
    }

    /// 自动过滤 `[BLANK_AUDIO]`、`(字幕...)` 等常见 Whisper 静音幻觉与噪声占位文本。
    static func cleanTranscript(_ raw: String) -> String {
        let inlineNoisePatterns = [
            #"\[BLANK_AUDIO\]"#,
            #"\[(?i:silence|music|applause|laughter|noise|blank|inaudible|\s+)\]"#,
            #"\[(?:音乐|掌声|笑声|空白|噪音|静音|字幕[^\]]*)\]"#,
            #"[\(（](?:字幕[^\)）]*|空白|静音|音乐|掌声|笑声|噪音|无声|停顿)[\)）]"#
        ]

        let fullLineHallucinations: Set<String> = [
            "字幕由 amara.org 社群提供",
            "字幕由amara.org社群提供",
            "由 amara.org 社群提供",
            "amara.org",
            "优优独播剧场——yoyo television series exclusive",
            "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
            "明镜与点点",
            "谢谢观看",
            "感谢观看",
            "thank you for watching"
        ]

        var cleanedLines: [String] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            for pattern in inlineNoisePatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let range = NSRange(line.startIndex..., in: line)
                    line = regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
                }
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let normalizedLower = line
                .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces))
                .lowercased()
            if fullLineHallucinations.contains(normalizedLower) {
                continue
            }
            cleanedLines.append(line)
        }
        return cleanedLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ASRServiceError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case let .message(value): return value
        }
    }
}
