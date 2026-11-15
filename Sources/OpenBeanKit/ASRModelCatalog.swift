// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

// MARK: - 1. ASR 模型规格与目录元数据 (ASRModelTier)

public enum ASRModelTier: String, CaseIterable, Sendable, Equatable {
    case base = "base"
    case smallQ5_1 = "small-q5_1"
    case small = "small"
    case medium = "medium"

    /// 自动探测高精度模型的优先级顺序：medium > small > small-q5_1 > base
    public static let autoDiscoveryPriority: [ASRModelTier] = [.medium, .small, .smallQ5_1, .base]

    public var fileName: String {
        switch self {
        case .base: return "ggml-base.bin"
        case .smallQ5_1: return "ggml-small-q5_1.bin"
        case .small: return "ggml-small.bin"
        case .medium: return "ggml-medium.bin"
        }
    }

    public var shortName: String {
        switch self {
        case .base: return "Base"
        case .smallQ5_1: return "Small-Q5_1"
        case .small: return "Small"
        case .medium: return "Medium"
        }
    }

    public var displayName: String {
        switch self {
        case .base: return "Base（轻量快速 · ~141MB）"
        case .smallQ5_1: return "Small-Q5_1（中英混说量化 · ~181MB）"
        case .small: return "Small（高精度中文/混说 · ~465MB）"
        case .medium: return "Medium（旗舰级高精度 · ~1.43GB）"
        }
    }

    public var recommendationSummary: String {
        switch self {
        case .base: return "体积最小、实时预览延迟最低；日常短句够用，专有名词识别相对一般。"
        case .smallQ5_1: return "量化高精度版本，体积适中且速度较快，适合兼顾响应速度与准确率。"
        case .small: return "推荐主力：中文与中英混说准确率显著提升，适合日常工作对话转写。"
        case .medium: return "旗舰精度：复杂术语与长句效果最佳，但磁盘占用和单次转写耗时较高。"
        }
    }

    public var isRecommended: Bool {
        self == .small
    }

    public var approxSizeBytes: Int64 {
        switch self {
        case .base: return 147_951_465
        case .smallQ5_1: return 190_000_000
        case .small: return 487_614_201
        case .medium: return 1_533_774_781
        }
    }

    /// 对应 `scripts/setup-model.sh` 中登记的官方 ggml SHA-256 校验值。
    public var expectedSHA256: String {
        switch self {
        case .base:
            return "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        case .smallQ5_1:
            return "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        case .small:
            return "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
        case .medium:
            return "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
        }
    }

    public static func parse(_ raw: String) -> ASRModelTier? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch token {
        case "base", "ggml-base", "ggml-base.bin":
            return .base
        case "small-q5_1", "small_q5_1", "ggml-small-q5_1", "ggml-small-q5_1.bin":
            return .smallQ5_1
        case "small", "ggml-small", "ggml-small.bin":
            return .small
        case "medium", "ggml-medium", "ggml-medium.bin":
            return .medium
        default:
            return nil
        }
    }

    public static func infer(fromPath path: String) -> ASRModelTier? {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return parse(name)
    }
}

public struct ResolvedASRModel: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case environment = "环境变量 BEANBRIDGE_MODEL"
        case preference = "偏好配置 model-preference"
        case autoDiscovered = "本地高精度自动优选"
        case fallback = "默认回退 ggml-base.bin"
    }

    public let path: String
    public let tier: ASRModelTier?
    public let source: Source
    public let exists: Bool

    public init(path: String, tier: ASRModelTier?, source: Source, exists: Bool) {
        self.path = path
        self.tier = tier
        self.source = source
        self.exists = exists
    }

    public var displayLabel: String {
        if let tier {
            return "\(tier.shortName) (\(URL(fileURLWithPath: path).lastPathComponent))"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - 2. 下载源与字节格式化工具

public enum ASRDownloadSource: String, CaseIterable, Sendable, Equatable {
    case huggingFace = "huggingface"
    case hfMirror = "hf-mirror"

    public var displayName: String {
        switch self {
        case .huggingFace: return "Hugging Face 官方源"
        case .hfMirror: return "HF 镜像源 (hf-mirror.com)"
        }
    }

    public var baseURLString: String {
        switch self {
        case .huggingFace: return "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
        case .hfMirror: return "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main"
        }
    }

    /// 构造模型下载 URL（支持 `BEANBRIDGE_MODEL_BASE_URL` 覆盖用于私有镜像或测试）。
    public func url(for tier: ASRModelTier, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let override = environment["BEANBRIDGE_MODEL_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBase = (override?.isEmpty == false ? override! : baseURLString)
        let cleanBase = rawBase.hasSuffix("/") ? String(rawBase.dropLast()) : rawBase
        guard let baseURL = URL(string: cleanBase) else { return nil }
        return baseURL.appendingPathComponent(tier.fileName)
    }
}

public enum ASRByteFormatter {
    public static func formatSize(_ bytes: Int64) -> String {
        let mb = Double(max(0, bytes)) / (1024.0 * 1024.0)
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.1f MB", mb)
    }

    public static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "-- MB/s" }
        let mbps = bytesPerSecond / (1024.0 * 1024.0)
        if mbps < 1.0 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024.0)
        }
        return String(format: "%.1f MB/s", mbps)
    }

    public static func formatETA(remainingBytes: Int64, bytesPerSecond: Double) -> String? {
        guard remainingBytes > 0, bytesPerSecond > 1024 else { return nil }
        let seconds = Int((Double(remainingBytes) / bytesPerSecond).rounded())
        if seconds < 60 {
            return "约 \(max(1, seconds)) 秒"
        }
        let mins = seconds / 60
        let secs = seconds % 60
        return "约 \(mins) 分 \(secs) 秒"
    }
}

// MARK: - 3. 模型管理、校验与偏好持久化 (ASRModelManager)

public enum ASRModelError: Error, LocalizedError, CustomStringConvertible {
    case invalidDownloadURL(String)
    case httpError(statusCode: Int)
    case checksumMismatch(expected: String, actual: String)
    case fileOperationFailed(String)

    public var description: String {
        switch self {
        case let .invalidDownloadURL(raw):
            return "无效的模型下载地址：\(raw)"
        case let .httpError(code):
            return "下载请求返回异常 HTTP 状态码：\(code)"
        case let .checksumMismatch(expected, actual):
            return "模型文件 SHA-256 校验未通过（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…），已清理异常文件。"
        case let .fileOperationFailed(detail):
            return detail
        }
    }

    public var errorDescription: String? { description }
}

public final class ASRModelManager: @unchecked Sendable {
    public static let environmentKey = "BEANBRIDGE_MODEL"
    public static let preferenceFileName = "model-preference"

    public let supportDirectory: URL
    public let modelsDirectory: URL
    public let preferenceFileURL: URL
    private let environmentProvider: @Sendable () -> [String: String]
    private let lock = NSLock()

    public init(
        supportDirectory: URL,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.supportDirectory = supportDirectory
        self.modelsDirectory = supportDirectory.appendingPathComponent("Models", isDirectory: true)
        self.preferenceFileURL = supportDirectory.appendingPathComponent(Self.preferenceFileName)
        self.environmentProvider = environmentProvider
    }

    public var isOverriddenByEnvironment: Bool {
        if let raw = environmentProvider()[Self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return true
        }
        return false
    }

    public func modelURL(for tier: ASRModelTier) -> URL {
        let primary = modelsDirectory.appendingPathComponent(tier.fileName)
        if FileManager.default.fileExists(atPath: primary.path) {
            return primary
        }
        let lowercaseDir = supportDirectory.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(tier.fileName)
        if FileManager.default.fileExists(atPath: lowercaseDir.path) {
            return lowercaseDir
        }
        return primary
    }

    public func isTierInstalled(_ tier: ASRModelTier) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(for: tier).path)
    }

    public func installedFileSizeBytes(for tier: ASRModelTier) -> Int64? {
        let url = modelURL(for: tier)
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    public func installedTiers() -> [ASRModelTier] {
        ASRModelTier.autoDiscoveryPriority.filter { isTierInstalled($0) }
    }

    /// 保证模型目录存在且权限为 0o700，供 UI“打开目录”与下载前调用。
    @discardableResult
    public func ensureModelsDirectory() throws -> URL {
        let fm = FileManager.default
        try Self.ensureSecureDir(supportDirectory, fileManager: fm)
        try Self.ensureSecureDir(modelsDirectory, fileManager: fm)
        return modelsDirectory
    }

    /// 流式分块计算任意本地大文件的 SHA-256 十六进制小写摘要（恒定小内存开销）。
    public static func streamingSHA256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1_048_576
        while true {
            let chunk = try autoreleasepool { () -> Data? in
                try handle.read(upToCount: chunkSize)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 校验已安装模型是否匹配预期 SHA-256。
    public func verifyInstalledModel(_ tier: ASRModelTier, expectedSHA256: String? = nil) throws -> Bool {
        let url = modelURL(for: tier)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let actual = try Self.streamingSHA256Hex(of: url)
        let expected = (expectedSHA256 ?? tier.expectedSHA256).lowercased()
        return actual.lowercased() == expected
    }

    /// 删除指定已安装模型；若其正好是 `model-preference` 当前指向，自动清理偏好以回退默认优先级。
    public func deleteInstalledModel(tier: ASRModelTier) throws {
        let fm = FileManager.default
        let primary = modelsDirectory.appendingPathComponent(tier.fileName)
        let secondary = supportDirectory.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(tier.fileName)
        for pathURL in [primary, secondary] where fm.fileExists(atPath: pathURL.path) {
            try fm.removeItem(at: pathURL)
        }
        if preferredTier() == tier {
            try clearPreference()
        }
    }

    /// 按优先级解析当前生效模型：
    /// `BEANBRIDGE_MODEL` > `support/model-preference` > 本地已存在高精度模型 (medium > small > small-q5_1 > base) > 回退 `Models/ggml-base.bin`
    public func resolveModel() -> ResolvedASRModel {
        let fm = FileManager.default
        let env = environmentProvider()

        if let envRaw = env[Self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envRaw.isEmpty {
            if let tier = ASRModelTier.parse(envRaw) {
                let url = modelURL(for: tier)
                return ResolvedASRModel(
                    path: url.path,
                    tier: tier,
                    source: .environment,
                    exists: fm.fileExists(atPath: url.path)
                )
            }
            let expanded = (envRaw as NSString).expandingTildeInPath
            return ResolvedASRModel(
                path: expanded,
                tier: ASRModelTier.infer(fromPath: expanded),
                source: .environment,
                exists: fm.fileExists(atPath: expanded)
            )
        }

        if let pref = readPreference() {
            if let tier = ASRModelTier.parse(pref) {
                let url = modelURL(for: tier)
                if fm.fileExists(atPath: url.path) {
                    return ResolvedASRModel(
                        path: url.path,
                        tier: tier,
                        source: .preference,
                        exists: true
                    )
                }
            } else {
                let expanded = (pref as NSString).expandingTildeInPath
                if fm.fileExists(atPath: expanded) {
                    return ResolvedASRModel(
                        path: expanded,
                        tier: ASRModelTier.infer(fromPath: expanded),
                        source: .preference,
                        exists: true
                    )
                }
                let inModels = modelsDirectory.appendingPathComponent(pref)
                if fm.fileExists(atPath: inModels.path) {
                    return ResolvedASRModel(
                        path: inModels.path,
                        tier: ASRModelTier.infer(fromPath: inModels.path),
                        source: .preference,
                        exists: true
                    )
                }
            }
        }

        for tier in ASRModelTier.autoDiscoveryPriority {
            let url = modelURL(for: tier)
            if fm.fileExists(atPath: url.path) {
                return ResolvedASRModel(
                    path: url.path,
                    tier: tier,
                    source: .autoDiscovered,
                    exists: true
                )
            }
        }

        let fallbackURL = modelsDirectory.appendingPathComponent(ASRModelTier.base.fileName)
        return ResolvedASRModel(
            path: fallbackURL.path,
            tier: .base,
            source: .fallback,
            exists: fm.fileExists(atPath: fallbackURL.path)
        )
    }

    public func readPreference() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: preferenceFileURL.path),
              let raw = try? String(contentsOf: preferenceFileURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func preferredTier() -> ASRModelTier? {
        guard let pref = readPreference() else { return nil }
        return ASRModelTier.parse(pref)
    }

    public func setPreferredTier(_ tier: ASRModelTier?) throws {
        if let tier {
            try writePreference(tier.rawValue)
        } else {
            try clearPreference()
        }
    }

    public func writePreference(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clearPreference()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try Self.ensureSecureDir(supportDirectory, fileManager: fm)
        try Self.writeSecureFile(Data((trimmed + "\n").utf8), to: preferenceFileURL, fileManager: fm)
    }

    public func clearPreference() throws {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        if fm.fileExists(atPath: preferenceFileURL.path) {
            try fm.removeItem(at: preferenceFileURL)
        }
    }

    public static func ensureSecureDir(_ url: URL, fileManager: FileManager = .default) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func writeSecureFile(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - 4. 模型下载进度与状态管理 (ASRModelDownloadManager)

public enum ASRModelDownloadPhase: Sendable, Equatable {
    case idle
    case downloading(receivedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double)
    case verifying
    case completed(modelURL: URL, sizeBytes: Int64)
    case failed(message: String)
    case cancelled
}

public struct ASRModelDownloadSnapshot: Sendable, Equatable {
    public let tier: ASRModelTier
    public let source: ASRDownloadSource
    public let phase: ASRModelDownloadPhase
    public let setAsDefaultOnSuccess: Bool

    public init(
        tier: ASRModelTier,
        source: ASRDownloadSource,
        phase: ASRModelDownloadPhase,
        setAsDefaultOnSuccess: Bool
    ) {
        self.tier = tier
        self.source = source
        self.phase = phase
        self.setAsDefaultOnSuccess = setAsDefaultOnSuccess
    }

    public var isInProgress: Bool {
        switch phase {
        case .downloading, .verifying:
            return true
        case .idle, .completed, .failed, .cancelled:
            return false
        }
    }

    public var fractionCompleted: Double {
        switch phase {
        case let .downloading(received, total, _):
            let denom = total > 0 ? total : tier.approxSizeBytes
            guard denom > 0 else { return 0 }
            return min(1.0, max(0.0, Double(received) / Double(denom)))
        case .verifying, .completed:
            return 1.0
        case .idle, .failed, .cancelled:
            return 0.0
        }
    }

    public var statusText: String {
        switch phase {
        case .idle:
            return "未下载"
        case let .downloading(received, total, bps):
            let effectiveTotal = total > 0 ? total : tier.approxSizeBytes
            let pct = Int((fractionCompleted * 100.0).rounded())
            let speedStr = ASRByteFormatter.formatSpeed(bps)
            let progressPart = "\(ASRByteFormatter.formatSize(received)) / \(ASRByteFormatter.formatSize(effectiveTotal))"
            if let eta = ASRByteFormatter.formatETA(remainingBytes: max(0, effectiveTotal - received), bytesPerSecond: bps) {
                return "下载中 \(pct)%（\(progressPart) · \(speedStr) · 剩余\(eta)）"
            }
            return "下载中 \(pct)%（\(progressPart) · \(speedStr)）"
        case .verifying:
            return "正在校验 SHA-256 完整性…"
        case let .completed(_, sizeBytes):
            return "已下载并验证通过（\(ASRByteFormatter.formatSize(sizeBytes))）"
        case let .failed(message):
            return "下载失败：\(message)"
        case .cancelled:
            return "已取消下载"
        }
    }
}

public final class ASRModelDownloadManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias ExpectedSHAResolver = @Sendable (ASRModelTier) -> String

    public let modelManager: ASRModelManager
    private let environmentProvider: @Sendable () -> [String: String]
    private let expectedSHAResolver: ExpectedSHAResolver
    private let delegateQueue: OperationQueue
    private let verificationQueue = DispatchQueue(label: "openbeankit.asr.model-verify", qos: .utility)
    private let lock = NSLock()
    private var session: URLSession!

    private struct ActiveTransfer {
        let task: URLSessionDownloadTask
        var snapshot: ASRModelDownloadSnapshot
        var lastSampleTime: Date
        var lastSampleBytes: Int64
        var smoothedBytesPerSecond: Double
        var lastEmitTime: Date
    }

    private var activeByTier: [ASRModelTier: ActiveTransfer] = [:]
    private var tierByTaskID: [Int: ASRModelTier] = [:]
    private var terminalSnapshots: [ASRModelTier: ASRModelDownloadSnapshot] = [:]

    /// 状态或下载进度变更时回调（已对高频写入做节流，线程安全）。
    public var onSnapshotsChanged: (@Sendable ([ASRModelTier: ASRModelDownloadSnapshot]) -> Void)?

    public init(
        modelManager: ASRModelManager,
        sessionConfiguration: URLSessionConfiguration = .default,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        expectedSHAResolver: @escaping ExpectedSHAResolver = { $0.expectedSHA256 }
    ) {
        self.modelManager = modelManager
        self.environmentProvider = environmentProvider
        self.expectedSHAResolver = expectedSHAResolver

        let opQueue = OperationQueue()
        opQueue.name = "openbeankit.asr.model-download"
        opQueue.maxConcurrentOperationCount = 1
        self.delegateQueue = opQueue

        super.init()
        let config = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .default
        if config.timeoutIntervalForRequest < 60 {
            config.timeoutIntervalForRequest = 60
        }
        if config.timeoutIntervalForResource < 3600 {
            config.timeoutIntervalForResource = 3600
        }
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
        cleanupOrphanedPartials()
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func snapshots() -> [ASRModelTier: ASRModelDownloadSnapshot] {
        lock.lock()
        let map = currentSnapshotsLocked()
        lock.unlock()
        return map
    }

    public func snapshot(for tier: ASRModelTier) -> ASRModelDownloadSnapshot? {
        lock.lock()
        let snap = activeByTier[tier]?.snapshot ?? terminalSnapshots[tier]
        lock.unlock()
        return snap
    }

    public func isDownloadingAny() -> Bool {
        lock.lock()
        let active = !activeByTier.isEmpty
        lock.unlock()
        return active
    }

    /// 为顶部栏或菜单栏生成紧凑的下载中摘要文本。
    public func activeProgressSummary() -> String? {
        lock.lock()
        let activeList = activeByTier.values.map(\.snapshot).sorted { $0.tier.rawValue < $1.tier.rawValue }
        lock.unlock()
        guard let first = activeList.first else { return nil }
        let suffix = activeList.count > 1 ? " 等 \(activeList.count) 个任务" : ""
        return "正在下载 \(first.tier.shortName)：\(first.statusText)\(suffix)"
    }

    public func startDownload(
        tier: ASRModelTier,
        source: ASRDownloadSource = .huggingFace,
        setAsDefaultOnSuccess: Bool = true
    ) {
        lock.lock()
        if activeByTier[tier] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let env = environmentProvider()
        guard let url = source.url(for: tier, environment: env) else {
            let errSnap = ASRModelDownloadSnapshot(
                tier: tier,
                source: source,
                phase: .failed(message: ASRModelError.invalidDownloadURL(source.baseURLString).description),
                setAsDefaultOnSuccess: setAsDefaultOnSuccess
            )
            storeTerminalSnapshot(errSnap)
            return
        }

        do {
            _ = try modelManager.ensureModelsDirectory()
        } catch {
            let errSnap = ASRModelDownloadSnapshot(
                tier: tier,
                source: source,
                phase: .failed(message: "无法创建模型目录：\(error.localizedDescription)"),
                setAsDefaultOnSuccess: setAsDefaultOnSuccess
            )
            storeTerminalSnapshot(errSnap)
            return
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let task = session.downloadTask(with: request)
        let now = Date()
        let initialSnapshot = ASRModelDownloadSnapshot(
            tier: tier,
            source: source,
            phase: .downloading(receivedBytes: 0, totalBytes: tier.approxSizeBytes, bytesPerSecond: 0),
            setAsDefaultOnSuccess: setAsDefaultOnSuccess
        )

        lock.lock()
        terminalSnapshots.removeValue(forKey: tier)
        activeByTier[tier] = ActiveTransfer(
            task: task,
            snapshot: initialSnapshot,
            lastSampleTime: now,
            lastSampleBytes: 0,
            smoothedBytesPerSecond: 0,
            lastEmitTime: .distantPast
        )
        tierByTaskID[task.taskIdentifier] = tier
        let map = currentSnapshotsLocked()
        lock.unlock()

        emit(map)
        task.resume()
    }

    public func cancelDownload(tier: ASRModelTier) {
        lock.lock()
        let transfer = activeByTier[tier]
        lock.unlock()
        transfer?.task.cancel()
    }

    public func cancelAll() {
        lock.lock()
        let tasks = activeByTier.values.map(\.task)
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    public func clearSnapshot(for tier: ASRModelTier) {
        lock.lock()
        guard activeByTier[tier] == nil else {
            lock.unlock()
            return
        }
        terminalSnapshots.removeValue(forKey: tier)
        let map = currentSnapshotsLocked()
        lock.unlock()
        emit(map)
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finishWithError(
                taskID: downloadTask.taskIdentifier,
                message: ASRModelError.httpError(statusCode: http.statusCode).description
            )
            downloadTask.cancel()
            return
        }

        let now = Date()
        var shouldEmit: [ASRModelTier: ASRModelDownloadSnapshot]?

        lock.lock()
        if let tier = tierByTaskID[downloadTask.taskIdentifier], var transfer = activeByTier[tier] {
            let dt = now.timeIntervalSince(transfer.lastSampleTime)
            var speed = transfer.smoothedBytesPerSecond
            if dt >= 0.35 {
                let instant = Double(max(0, totalBytesWritten - transfer.lastSampleBytes)) / dt
                speed = speed > 0 ? (0.35 * instant + 0.65 * speed) : instant
                transfer.lastSampleTime = now
                transfer.lastSampleBytes = totalBytesWritten
                transfer.smoothedBytesPerSecond = speed
            }

            let expectedTotal = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : tier.approxSizeBytes
            transfer.snapshot = ASRModelDownloadSnapshot(
                tier: tier,
                source: transfer.snapshot.source,
                phase: .downloading(
                    receivedBytes: totalBytesWritten,
                    totalBytes: expectedTotal,
                    bytesPerSecond: transfer.smoothedBytesPerSecond
                ),
                setAsDefaultOnSuccess: transfer.snapshot.setAsDefaultOnSuccess
            )

            if now.timeIntervalSince(transfer.lastEmitTime) >= 0.1 {
                transfer.lastEmitTime = now
                activeByTier[tier] = transfer
                shouldEmit = currentSnapshotsLocked()
            } else {
                activeByTier[tier] = transfer
            }
        }
        lock.unlock()

        if let shouldEmit {
            emit(shouldEmit)
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finishWithError(
                taskID: downloadTask.taskIdentifier,
                message: ASRModelError.httpError(statusCode: http.statusCode).description
            )
            return
        }

        lock.lock()
        guard let tier = tierByTaskID[downloadTask.taskIdentifier],
              var transfer = activeByTier[tier] else {
            lock.unlock()
            return
        }
        // Detach taskID mapping before background verification so didCompleteWithError won't overwrite verifying state.
        tierByTaskID.removeValue(forKey: downloadTask.taskIdentifier)
        transfer.snapshot = ASRModelDownloadSnapshot(
            tier: tier,
            source: transfer.snapshot.source,
            phase: .verifying,
            setAsDefaultOnSuccess: transfer.snapshot.setAsDefaultOnSuccess
        )
        activeByTier[tier] = transfer
        let verifyingMap = currentSnapshotsLocked()
        lock.unlock()

        let stagedURL: URL
        do {
            let modelsDir = try modelManager.ensureModelsDirectory()
            stagedURL = modelsDir.appendingPathComponent(".\(tier.fileName).part.\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: stagedURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        } catch {
            lock.lock()
            let finished = ASRModelDownloadSnapshot(
                tier: tier,
                source: transfer.snapshot.source,
                phase: .failed(message: "无法保存临时模型文件：\(error.localizedDescription)"),
                setAsDefaultOnSuccess: transfer.snapshot.setAsDefaultOnSuccess
            )
            activeByTier.removeValue(forKey: tier)
            terminalSnapshots[tier] = finished
            let map = currentSnapshotsLocked()
            lock.unlock()
            emit(map)
            return
        }

        emit(verifyingMap)

        let expectedSHA = expectedSHAResolver(tier).lowercased()
        let shouldSetDefault = transfer.snapshot.setAsDefaultOnSuccess
        let source = transfer.snapshot.source

        verificationQueue.async { [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: stagedURL)
                return
            }
            defer {
                if FileManager.default.fileExists(atPath: stagedURL.path) {
                    try? FileManager.default.removeItem(at: stagedURL)
                }
            }

            do {
                let actualSHA = try ASRModelManager.streamingSHA256Hex(of: stagedURL).lowercased()
                guard actualSHA == expectedSHA else {
                    throw ASRModelError.checksumMismatch(expected: expectedSHA, actual: actualSHA)
                }

                let finalURL = self.modelManager.modelsDirectory.appendingPathComponent(tier.fileName)
                let secondaryURL = self.modelManager.supportDirectory
                    .appendingPathComponent("models", isDirectory: true)
                    .appendingPathComponent(tier.fileName)
                let fm = FileManager.default
                if fm.fileExists(atPath: finalURL.path) {
                    _ = try fm.replaceItemAt(finalURL, withItemAt: stagedURL)
                } else {
                    try fm.moveItem(at: stagedURL, to: finalURL)
                }
                if fm.fileExists(atPath: secondaryURL.path),
                   !Self.refersToSameFile(finalURL, secondaryURL) {
                    try? fm.removeItem(at: secondaryURL)
                }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)

                let attrs = try fm.attributesOfItem(atPath: finalURL.path)
                let finalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

                if shouldSetDefault {
                    try self.modelManager.setPreferredTier(tier)
                }

                let completedSnap = ASRModelDownloadSnapshot(
                    tier: tier,
                    source: source,
                    phase: .completed(modelURL: finalURL, sizeBytes: finalSize),
                    setAsDefaultOnSuccess: shouldSetDefault
                )
                self.completeVerification(tier: tier, snapshot: completedSnap)
            } catch {
                let message = (error as? ASRModelError)?.description ?? error.localizedDescription
                let failedSnap = ASRModelDownloadSnapshot(
                    tier: tier,
                    source: source,
                    phase: .failed(message: message),
                    setAsDefaultOnSuccess: shouldSetDefault
                )
                self.completeVerification(tier: tier, snapshot: failedSnap)
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            finishWithCancelled(taskID: task.taskIdentifier)
        } else {
            finishWithError(taskID: task.taskIdentifier, message: error.localizedDescription)
        }
    }

    // MARK: - 内部状态转换辅助

    private func completeVerification(tier: ASRModelTier, snapshot: ASRModelDownloadSnapshot) {
        lock.lock()
        activeByTier.removeValue(forKey: tier)
        terminalSnapshots[tier] = snapshot
        let map = currentSnapshotsLocked()
        lock.unlock()
        emit(map)
    }

    private func storeTerminalSnapshot(_ snapshot: ASRModelDownloadSnapshot) {
        lock.lock()
        terminalSnapshots[snapshot.tier] = snapshot
        let map = currentSnapshotsLocked()
        lock.unlock()
        emit(map)
    }

    private func finishWithCancelled(taskID: Int) {
        lock.lock()
        guard let tier = tierByTaskID.removeValue(forKey: taskID),
              let transfer = activeByTier.removeValue(forKey: tier) else {
            lock.unlock()
            return
        }
        terminalSnapshots[tier] = ASRModelDownloadSnapshot(
            tier: tier,
            source: transfer.snapshot.source,
            phase: .cancelled,
            setAsDefaultOnSuccess: transfer.snapshot.setAsDefaultOnSuccess
        )
        let map = currentSnapshotsLocked()
        lock.unlock()
        emit(map)
    }

    private func finishWithError(taskID: Int, message: String) {
        lock.lock()
        guard let tier = tierByTaskID.removeValue(forKey: taskID),
              let transfer = activeByTier.removeValue(forKey: tier) else {
            lock.unlock()
            return
        }
        terminalSnapshots[tier] = ASRModelDownloadSnapshot(
            tier: tier,
            source: transfer.snapshot.source,
            phase: .failed(message: message),
            setAsDefaultOnSuccess: transfer.snapshot.setAsDefaultOnSuccess
        )
        let map = currentSnapshotsLocked()
        lock.unlock()
        emit(map)
    }

    private func currentSnapshotsLocked() -> [ASRModelTier: ASRModelDownloadSnapshot] {
        var combined = terminalSnapshots
        for (tier, transfer) in activeByTier {
            combined[tier] = transfer.snapshot
        }
        return combined
    }

    private func emit(_ snapshots: [ASRModelTier: ASRModelDownloadSnapshot]) {
        onSnapshotsChanged?(snapshots)
    }

    private static func refersToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsID = (try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject,
              let rhsID = (try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject else {
            return lhs.standardizedFileURL.path.lowercased() == rhs.standardizedFileURL.path.lowercased()
        }
        return lhsID.isEqual(rhsID)
    }

    private func cleanupOrphanedPartials() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: modelManager.modelsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in entries where url.lastPathComponent.contains(".part.") {
            try? fm.removeItem(at: url)
        }
    }
}
