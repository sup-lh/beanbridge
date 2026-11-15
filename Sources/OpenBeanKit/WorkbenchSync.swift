// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

// MARK: - 1. 增量同步清单 (SyncManifestStore)

public enum SyncSource: String, Codable, Sendable, Equatable {
    case ble
    case wifi
}

public struct SyncedFileRecord: Codable, Sendable, Equatable {
    public var fileId: UInt32
    public var syncedAt: Date
    public var source: SyncSource
    public var durationMs: UInt32
    public var userMarked: Bool

    public init(
        fileId: UInt32,
        syncedAt: Date = Date(),
        source: SyncSource = .ble,
        durationMs: UInt32,
        userMarked: Bool = false
    ) {
        self.fileId = fileId
        self.syncedAt = syncedAt
        self.source = source
        self.durationMs = durationMs
        self.userMarked = userMarked
    }
}

/// 离机录音增量同步清单持久化存储（目录权限 0o700，文件权限 0o600，原子写入）。
public final class SyncManifestStore: @unchecked Sendable {
    public let directoryURL: URL
    public let manifestFileURL: URL

    private let lock = NSLock()
    private var recordsByFileID: [UInt32: SyncedFileRecord] = [:]
    private var loaded = false

    public init(directoryURL: URL, fileName: String = "sync-manifest.json") {
        self.directoryURL = directoryURL
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        self.manifestFileURL = directoryURL.appendingPathComponent(safeName.isEmpty ? "sync-manifest.json" : safeName)
    }

    /// 过滤出尚未同步过的设备录音文件（保持输入顺序，若输入无序则按 id 降序）。
    public func unsyncedFiles(from files: [RecordingFile]) throws -> [RecordingFile] {
        lock.lock()
        defer { lock.unlock() }
        try ensureLoadedLocked()
        return files.filter { recordsByFileID[$0.id] == nil }
    }

    public func isSynced(_ fileId: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try? ensureLoadedLocked()
        return recordsByFileID[fileId] != nil
    }

    public func record(for fileId: UInt32) -> SyncedFileRecord? {
        lock.lock()
        defer { lock.unlock() }
        try? ensureLoadedLocked()
        return recordsByFileID[fileId]
    }

    public func markSynced(_ record: SyncedFileRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureLoadedLocked()
        recordsByFileID[record.fileId] = record
        try persistLocked()
    }

    public func markSynced(
        fileId: UInt32,
        syncedAt: Date = Date(),
        source: SyncSource = .ble,
        durationMs: UInt32,
        userMarked: Bool = false
    ) throws {
        try markSynced(
            SyncedFileRecord(
                fileId: fileId,
                syncedAt: syncedAt,
                source: source,
                durationMs: durationMs,
                userMarked: userMarked
            )
        )
    }

    public func allRecords() throws -> [SyncedFileRecord] {
        lock.lock()
        defer { lock.unlock() }
        try ensureLoadedLocked()
        return recordsByFileID.values.sorted {
            if $0.syncedAt != $1.syncedAt { return $0.syncedAt > $1.syncedAt }
            return $0.fileId > $1.fileId
        }
    }

    private func ensureLoadedLocked() throws {
        guard !loaded else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: manifestFileURL.path) {
            let data = try Data(contentsOf: manifestFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let list = try decoder.decode([SyncedFileRecord].self, from: data)
            recordsByFileID = Dictionary(uniqueKeysWithValues: list.map { ($0.fileId, $0) })
        } else {
            recordsByFileID = [:]
        }
        loaded = true
    }

    private func persistLocked() throws {
        let fm = FileManager.default
        try ensureSecureDirectory(directoryURL, fileManager: fm)
        let sorted = recordsByFileID.values.sorted { $0.fileId < $1.fileId }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sorted)
        try writeSecureFile(data: data, to: manifestFileURL, fileManager: fm)
    }
}

// MARK: - 2. 增量同步编排器 (OfflineSyncCoordinator)

public enum OfflineSyncError: Error, Equatable, CustomStringConvertible {
    case notDecrypted(fileId: UInt32, detail: String?)
    case incompleteTransfer(fileId: UInt32, missingSeqs: Int)
    case emptyAudio(fileId: UInt32)

    public var description: String {
        switch self {
        case let .notDecrypted(id, detail):
            return "录音 \(id) 解密失败\(detail.map { "：\($0)" } ?? "")"
        case let .incompleteTransfer(id, missing):
            return "录音 \(id) 传输分片缺失（缺失 \(missing) 片）"
        case let .emptyAudio(id):
            return "录音 \(id) 音频为空"
        }
    }
}

public struct PulledRecording: Sendable {
    public let file: RecordingFile
    public let transfer: Transfer
    public let source: SyncSource
    public let record: SyncedFileRecord

    public init(file: RecordingFile, transfer: Transfer, source: SyncSource, record: SyncedFileRecord) {
        self.file = file
        self.transfer = transfer
        self.source = source
        self.record = record
    }
}

/// 离机录音增量拉取编排器（支持 BLE `D3200Session.pull` 与 `WifiExport.pull`）。
public final class OfflineSyncCoordinator: @unchecked Sendable {
    public let manifest: SyncManifestStore

    public init(manifest: SyncManifestStore) {
        self.manifest = manifest
    }

    /// 校验一次 `Transfer` 是否解密成功且分片完整。
    public static func validateTransfer(_ transfer: Transfer, allowMissingSeqs: Int = 0) throws {
        guard transfer.decrypted else {
            throw OfflineSyncError.notDecrypted(fileId: transfer.fileId, detail: transfer.decryptError)
        }
        guard !transfer.audio.isEmpty else {
            throw OfflineSyncError.emptyAudio(fileId: transfer.fileId)
        }
        guard transfer.missingSeqs <= allowMissingSeqs else {
            throw OfflineSyncError.incompleteTransfer(fileId: transfer.fileId, missingSeqs: transfer.missingSeqs)
        }
    }

    /// 通过 BLE 会话增量拉取尚未同步的录音文件。
    public func syncUnsyncedOverBLE(
        session: D3200Session,
        files: [RecordingFile]? = nil,
        idle: Double = 20,
        maxSeconds: Double? = nil,
        allowMissingSeqs: Int = 0,
        shouldCancel: () async -> Bool = { false },
        onFileProgress: (RecordingFile, Int, Int, Double) async -> Void = { _, _, _, _ in }
    ) async throws -> [PulledRecording] {
        let remoteFiles: [RecordingFile]
        if let files {
            remoteFiles = files
        } else {
            remoteFiles = try await session.listFiles()
        }
        let pending = try manifest.unsyncedFiles(from: remoteFiles)
        var results: [PulledRecording] = []
        for file in pending {
            if await shouldCancel() { break }
            let transfer = try await session.pull(
                file,
                idle: idle,
                maxSeconds: maxSeconds,
                shouldCancel: shouldCancel
            ) { bytes, expected, seconds in
                await onFileProgress(file, bytes, expected, seconds)
            }
            try Self.validateTransfer(transfer, allowMissingSeqs: allowMissingSeqs)
            let rec = SyncedFileRecord(
                fileId: file.id,
                syncedAt: Date(),
                source: .ble,
                durationMs: file.durationMs,
                userMarked: transfer.userMarked
            )
            try manifest.markSynced(rec)
            results.append(PulledRecording(file: file, transfer: transfer, source: .ble, record: rec))
        }
        return results
    }

    /// 通过 Wi-Fi 通道增量拉取尚未同步的录音文件。
    public func syncUnsyncedOverWifi(
        wifi: WifiExport,
        files: [RecordingFile],
        idle: Double = 20,
        maxSeconds: Double? = nil,
        allowMissingSeqs: Int = 0,
        shouldCancel: () async -> Bool = { false },
        onFileProgress: (RecordingFile, Int, Int, Double) async -> Void = { _, _, _, _ in }
    ) async throws -> [PulledRecording] {
        let pending = try manifest.unsyncedFiles(from: files)
        var results: [PulledRecording] = []
        for file in pending {
            if await shouldCancel() { break }
            let transfer = try await wifi.pull(file, maxSeconds: maxSeconds, idle: idle) { bytes, expected, seconds in
                await onFileProgress(file, bytes, expected, seconds)
            }
            try Self.validateTransfer(transfer, allowMissingSeqs: allowMissingSeqs)
            let rec = SyncedFileRecord(
                fileId: file.id,
                syncedAt: Date(),
                source: .wifi,
                durationMs: file.durationMs,
                userMarked: transfer.userMarked
            )
            try manifest.markSynced(rec)
            results.append(PulledRecording(file: file, transfer: transfer, source: .wifi, record: rec))
        }
        return results
    }
}

// MARK: - 3. 音频切片与 VAD 发声检测 (AudioVADslicer)

public struct VoiceSegment: Sendable, Equatable {
    public var startMs: Int
    public var endMs: Int
    public var peakRMS: Float
    public var opusFrames: [UInt8]
    public var userMarked: Bool

    public var durationMs: Int { max(0, endMs - startMs) }

    public init(
        startMs: Int,
        endMs: Int,
        peakRMS: Float,
        opusFrames: [UInt8],
        userMarked: Bool = false
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.peakRMS = peakRMS
        self.opusFrames = opusFrames
        self.userMarked = userMarked
    }

    /// 封装为独立可播放的 Ogg Opus 字节流。
    public func oggOpusData() -> [UInt8] {
        OggOpus.mux(frames: OggOpus.frames(from: opusFrames))
    }
}

/// 基于每帧（20 ms，160 字节）RMS 能量的音频 VAD 切片器。
public struct AudioVADslicer: Sendable, Equatable {
    public static let frameBytes = OggOpus.frameSize // 160
    public static let frameDurationMs = 20

    public var rmsThreshold: Float
    public var minSpeechMs: Int
    public var minSilenceSplitMs: Int
    public var paddingMs: Int

    public init(
        rmsThreshold: Float = 0.004,
        minSpeechMs: Int = 200,
        minSilenceSplitMs: Int = 600,
        paddingMs: Int = 200
    ) {
        self.rmsThreshold = max(0, rmsThreshold)
        self.minSpeechMs = max(Self.frameDurationMs, minSpeechMs)
        self.minSilenceSplitMs = max(Self.frameDurationMs, minSilenceSplitMs)
        self.paddingMs = max(0, paddingMs)
    }

    /// 计算单个解码后 `AVAudioPCMBuffer` 的 RMS 能量。
    public static func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sumSquares: Float = 0
        for i in 0..<count {
            let s = samples[i]
            sumSquares += s * s
        }
        return sqrt(sumSquares / Float(count))
    }

    /// 对解密后的裸 Opus 帧串（每帧 160 字节，20 ms）按能量阈值切分有效语音段。
    /// - Parameters:
    ///   - rawOpus: 裸 Opus 音频字节数组。
    ///   - userMarked: 是否带有设备端轻敲标记。
    ///   - frameRMSEvaluator: 可选的帧能量评估闭包 `(frameIndex, frameBytes) -> Float`，便于无硬件依赖单元测试。
    public func slice(
        rawOpus: [UInt8],
        userMarked: Bool = false,
        frameRMSEvaluator: ((Int, [UInt8]) throws -> Float)? = nil
    ) throws -> [VoiceSegment] {
        let totalFrames = rawOpus.count / Self.frameBytes
        guard totalFrames > 0 else { return [] }

        let evaluator: (Int, [UInt8]) throws -> Float
        if let frameRMSEvaluator {
            evaluator = frameRMSEvaluator
        } else {
            let decoder = try OpusDecoder()
            evaluator = { _, frame in
                let pcm = try decoder.decode(frame)
                return Self.calculateRMS(pcm)
            }
        }

        var rmsValues = [Float](repeating: 0, count: totalFrames)
        for idx in 0..<totalFrames {
            let offset = idx * Self.frameBytes
            let frame = Array(rawOpus[offset..<(offset + Self.frameBytes)])
            rmsValues[idx] = try evaluator(idx, frame)
        }

        let minSpeechFrames = max(1, (minSpeechMs + Self.frameDurationMs - 1) / Self.frameDurationMs)
        let minSilenceFrames = max(1, (minSilenceSplitMs + Self.frameDurationMs - 1) / Self.frameDurationMs)
        let paddingFrames = max(0, paddingMs / Self.frameDurationMs)

        // 第一步：找出连续的有声帧区间并合并短于 minSilenceFrames 的静音间隙
        var rawIntervals: [(start: Int, end: Int)] = [] // 半开区间 [start, end)
        var currentStart: Int?
        var silenceRun = 0

        for idx in 0..<totalFrames {
            let isVoiced = rmsValues[idx] >= rmsThreshold
            if isVoiced {
                if currentStart == nil {
                    currentStart = idx
                }
                silenceRun = 0
            } else if let start = currentStart {
                silenceRun += 1
                if silenceRun >= minSilenceFrames {
                    let speechEnd = idx - silenceRun + 1
                    if speechEnd - start >= minSpeechFrames {
                        rawIntervals.append((start, speechEnd))
                    }
                    currentStart = nil
                    silenceRun = 0
                }
            }
        }

        if let start = currentStart {
            let speechEnd = totalFrames - silenceRun
            if speechEnd - start >= minSpeechFrames {
                rawIntervals.append((start, speechEnd))
            }
        }

        guard !rawIntervals.isEmpty else { return [] }

        // 第二步：加上前后安全边距 paddingFrames，若相邻区间因 padding 重叠则在静音中点切开，不丢失语音边界
        var segments: [VoiceSegment] = []
        for i in 0..<rawIntervals.count {
            let interval = rawIntervals[i]
            var paddedStart = max(0, interval.start - paddingFrames)
            var paddedEnd = min(totalFrames, interval.end + paddingFrames)

            if i > 0 {
                let prev = rawIntervals[i - 1]
                let prevPaddedEnd = min(totalFrames, prev.end + paddingFrames)
                if paddedStart < prevPaddedEnd {
                    let mid = (prev.end + interval.start) / 2
                    paddedStart = max(prev.end, mid)
                }
            }
            if i + 1 < rawIntervals.count {
                let next = rawIntervals[i + 1]
                let nextPaddedStart = max(0, next.start - paddingFrames)
                if paddedEnd > nextPaddedStart {
                    let mid = (interval.end + next.start) / 2
                    paddedEnd = min(next.start, mid)
                }
            }

            guard paddedEnd > paddedStart else { continue }
            var peak: Float = 0
            for f in paddedStart..<paddedEnd {
                if rmsValues[f] > peak { peak = rmsValues[f] }
            }
            let byteStart = paddedStart * Self.frameBytes
            let byteEnd = paddedEnd * Self.frameBytes
            let opusSlice = Array(rawOpus[byteStart..<byteEnd])
            segments.append(
                VoiceSegment(
                    startMs: paddedStart * Self.frameDurationMs,
                    endMs: paddedEnd * Self.frameDurationMs,
                    peakRMS: peak,
                    opusFrames: opusSlice,
                    userMarked: userMarked
                )
            )
        }

        return segments
    }
}

// MARK: - 4. 灵感收集箱与工作回放归档库 (WorkbenchArchive)

public struct ArchivedSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startMs: Int
    public var endMs: Int
    public var transcript: String
    public var audioFileName: String?
    public var peakRMS: Float

    public var durationMs: Int { max(0, endMs - startMs) }

    public init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        transcript: String,
        audioFileName: String? = nil,
        peakRMS: Float = 0
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.transcript = transcript
        self.audioFileName = audioFileName
        self.peakRMS = peakRMS
    }
}

public struct WorkbenchItem: Codable, Sendable, Equatable, Identifiable {
    public enum Category: String, Codable, Sendable, Equatable, CaseIterable {
        case ideaInbox
        case playback
    }

    public var id: UUID
    public var fileId: UInt32
    public var createdAt: Date
    public var durationMs: UInt32
    public var userMarked: Bool
    public var category: Category
    public var title: String
    public var segments: [ArchivedSegment]

    public init(
        id: UUID = UUID(),
        fileId: UInt32,
        createdAt: Date = Date(),
        durationMs: UInt32,
        userMarked: Bool,
        category: Category? = nil,
        title: String,
        segments: [ArchivedSegment]
    ) {
        self.id = id
        self.fileId = fileId
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.userMarked = userMarked
        self.category = category ?? (userMarked ? .ideaInbox : .playback)
        self.title = title
        self.segments = segments
    }
}

public struct WorkbenchSearchHit: Sendable, Equatable {
    public let item: WorkbenchItem
    public let segment: ArchivedSegment
    public let startMs: Int
    public let endMs: Int
    public let matchedKeywords: [String]
    public let excerpt: String

    public init(
        item: WorkbenchItem,
        segment: ArchivedSegment,
        matchedKeywords: [String],
        excerpt: String
    ) {
        self.item = item
        self.segment = segment
        self.startMs = segment.startMs
        self.endMs = segment.endMs
        self.matchedKeywords = matchedKeywords
        self.excerpt = excerpt
    }
}

/// 灵感收集箱与工作回放本地归档库（目录 0o700，文件 0o600，支持分段音频存储与全文检索）。
public final class WorkbenchArchive: @unchecked Sendable {
    public typealias Category = WorkbenchItem.Category

    public let rootDirectoryURL: URL
    public let audioDirectoryURL: URL
    public let indexFileURL: URL

    private let lock = NSLock()
    private var itemsByID: [UUID: WorkbenchItem] = [:]
    private var loaded = false

    public init(rootDirectoryURL: URL) {
        self.rootDirectoryURL = rootDirectoryURL
        self.audioDirectoryURL = rootDirectoryURL.appendingPathComponent("audio", isDirectory: true)
        self.indexFileURL = rootDirectoryURL.appendingPathComponent("archive-index.json")
    }

    /// 保存或更新一条归档记录，并可选将各分段对应的 Ogg Opus 音频数据写入 `audio/` 子目录。
    @discardableResult
    public func save(_ item: WorkbenchItem, segmentAudioData: [UUID: Data] = [:]) throws -> WorkbenchItem {
        lock.lock()
        defer { lock.unlock() }
        try ensureLoadedLocked()
        let fm = FileManager.default
        try ensureSecureDirectory(rootDirectoryURL, fileManager: fm)
        try ensureSecureDirectory(audioDirectoryURL, fileManager: fm)

        var storedItem = item
        for idx in storedItem.segments.indices {
            let seg = storedItem.segments[idx]
            if let audioData = segmentAudioData[seg.id] {
                let fileName = Self.safeAudioFileName(preferred: seg.audioFileName, itemID: storedItem.id, segmentID: seg.id)
                let fileURL = audioDirectoryURL.appendingPathComponent(fileName)
                try writeSecureFile(data: audioData, to: fileURL, fileManager: fm)
                storedItem.segments[idx].audioFileName = fileName
            } else if let existingName = seg.audioFileName {
                storedItem.segments[idx].audioFileName = Self.sanitizeFileName(existingName)
            }
        }

        itemsByID[storedItem.id] = storedItem
        try persistLocked()
        return storedItem
    }

    /// 直接从 `VoiceSegment` 列表与对应转写文本构建并保存归档条目（自动将每段 Opus 封装为 `.ogg` 存储）。
    @discardableResult
    public func archiveRecording(
        fileId: UInt32,
        createdAt: Date = Date(),
        durationMs: UInt32,
        userMarked: Bool,
        category: Category? = nil,
        title: String,
        voiceSegments: [(segment: VoiceSegment, transcript: String)]
    ) throws -> WorkbenchItem {
        let itemID = UUID()
        var archivedSegments: [ArchivedSegment] = []
        var audioMap: [UUID: Data] = [:]
        for entry in voiceSegments {
            let segID = UUID()
            let fileName = "\(itemID.uuidString)-\(segID.uuidString).ogg"
            let oggBytes = entry.segment.oggOpusData()
            audioMap[segID] = Data(oggBytes)
            archivedSegments.append(
                ArchivedSegment(
                    id: segID,
                    startMs: entry.segment.startMs,
                    endMs: entry.segment.endMs,
                    transcript: entry.transcript,
                    audioFileName: fileName,
                    peakRMS: entry.segment.peakRMS
                )
            )
        }
        let newItem = WorkbenchItem(
            id: itemID,
            fileId: fileId,
            createdAt: createdAt,
            durationMs: durationMs,
            userMarked: userMarked,
            category: category,
            title: title,
            segments: archivedSegments
        )
        return try save(newItem, segmentAudioData: audioMap)
    }

    /// 按分类（可选）和时间倒序返回归档条目。
    public func items(category: Category? = nil) throws -> [WorkbenchItem] {
        lock.lock()
        defer { lock.unlock() }
        try ensureLoadedLocked()
        return itemsByID.values
            .filter { category == nil || $0.category == category }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.fileId > $1.fileId
            }
    }

    public func item(id: UUID) throws -> WorkbenchItem? {
        lock.lock()
        defer { lock.unlock() }
        try ensureLoadedLocked()
        return itemsByID[id]
    }

    public func updateCategory(id: UUID, category: Category) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureLoadedLocked()
        guard var target = itemsByID[id] else { return }
        target.category = category
        itemsByID[id] = target
        try persistLocked()
    }

    public func updateSegmentTranscript(itemID: UUID, segmentID: UUID, transcript: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureLoadedLocked()
        guard var target = itemsByID[itemID],
              let idx = target.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        target.segments[idx].transcript = transcript
        itemsByID[itemID] = target
        try persistLocked()
    }

    /// 删除指定条目并清理关联的分段 `.ogg` 音频文件。
    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureLoadedLocked()
        guard let removed = itemsByID.removeValue(forKey: id) else { return }
        let fm = FileManager.default
        for seg in removed.segments {
            if let url = audioURL(for: seg), fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
        try persistLocked()
    }

    /// 获取某分段音频在本地归档目录中的安全文件路径。
    public func audioURL(for segment: ArchivedSegment) -> URL? {
        guard let rawName = segment.audioFileName,
              let cleanName = Self.sanitizeFileName(rawName) else { return nil }
        return audioDirectoryURL.appendingPathComponent(cleanName)
    }

    /// 本地分段全文检索：支持多关键词（空格分隔）、大小写不敏感匹配，返回匹配条目、分段、毫秒时间戳与上下文摘要。
    public func search(query: String, category: Category? = nil) throws -> [WorkbenchSearchHit] {
        let keywords = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return [] }

        let allItems = try items(category: category)
        var hits: [WorkbenchSearchHit] = []

        for item in allItems {
            let titleLower = item.title.lowercased()
            for segment in item.segments {
                let transcriptLower = segment.transcript.lowercased()
                let combinedLower = titleLower + "\n" + transcriptLower
                // 所有关键词均在（标题 + 分段转写）中出现，且分段或标题至少命中一个关键词
                let allMatched = keywords.allSatisfy { combinedLower.contains($0.lowercased()) }
                guard allMatched else { continue }

                let segmentMatches = keywords.filter {
                    transcriptLower.contains($0.lowercased()) || titleLower.contains($0.lowercased())
                }
                let excerpt = Self.makeExcerpt(text: segment.transcript.isEmpty ? item.title : segment.transcript, keywords: keywords)
                hits.append(
                    WorkbenchSearchHit(
                        item: item,
                        segment: segment,
                        matchedKeywords: segmentMatches,
                        excerpt: excerpt
                    )
                )
            }
        }

        return hits
    }

    private static func makeExcerpt(text: String, keywords: [String], radius: Int = 24) -> String {
        guard !text.isEmpty else { return "" }
        let lower = text.lowercased()
        for kw in keywords {
            if let range = lower.range(of: kw.lowercased()) {
                let startIdx = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
                let endIdx = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
                let prefix = startIdx > text.startIndex ? "…" : ""
                let suffix = endIdx < text.endIndex ? "…" : ""
                return prefix + String(text[startIdx..<endIdx]) + suffix
            }
        }
        return String(text.prefix(radius * 2))
    }

    private static func safeAudioFileName(preferred: String?, itemID: UUID, segmentID: UUID) -> String {
        if let preferred, let clean = sanitizeFileName(preferred), clean.hasSuffix(".ogg") {
            return clean
        }
        return "\(itemID.uuidString)-\(segmentID.uuidString).ogg"
    }

    private static func sanitizeFileName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("..") else { return nil }
        let base = URL(fileURLWithPath: trimmed).lastPathComponent
        guard base == trimmed, base != ".", base != ".." else { return nil }
        return base
    }

    private func ensureLoadedLocked() throws {
        guard !loaded else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: indexFileURL.path) {
            let data = try Data(contentsOf: indexFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([WorkbenchItem].self, from: data)
            itemsByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            itemsByID = [:]
        }
        loaded = true
    }

    private func persistLocked() throws {
        let fm = FileManager.default
        try ensureSecureDirectory(rootDirectoryURL, fileManager: fm)
        let sorted = itemsByID.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sorted)
        try writeSecureFile(data: data, to: indexFileURL, fileManager: fm)
    }
}

// MARK: - 安全目录与文件权限辅助 (0o700 / 0o600)

private func ensureSecureDirectory(_ url: URL, fileManager: FileManager) throws {
    if !fileManager.fileExists(atPath: url.path) {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

private func writeSecureFile(data: Data, to url: URL, fileManager: FileManager) throws {
    try data.write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
