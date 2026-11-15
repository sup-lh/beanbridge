import CryptoKit
import Foundation
import XCTest
@testable import OpenBeanKit

private final class StubModelURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior {
        case data(statusCode: Int, payload: Data, chunkDelaySeconds: TimeInterval = 0)
        case hangUntilCancelled
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Behavior)?

    private let cancelLock = NSLock()
    private var cancelled = false

    static func setHandler(_ newHandler: (@Sendable (URLRequest) -> Behavior)?) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    private static func currentHandler() -> (@Sendable (URLRequest) -> Behavior)? {
        lock.lock()
        let fn = handler
        lock.unlock()
        return fn
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let fn = Self.currentHandler(),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch fn(request) {
        case .hangUntilCancelled:
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "1048576"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 0xAA, count: 16))
        case let .data(statusCode, payload, chunkDelaySeconds):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(payload.count)"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if chunkDelaySeconds > 0 {
                Thread.sleep(forTimeInterval: chunkDelaySeconds)
            }
            cancelLock.lock()
            let isCancelled = cancelled
            cancelLock.unlock()
            if !isCancelled {
                client?.urlProtocol(self, didLoad: payload)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }
}

private final class SyncBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    func get() -> T {
        withLock { $0 }
    }
}

final class ASRModelCatalogTests: XCTestCase {
    private func makeTempSupportDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asr-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func makeStubConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubModelURLProtocol.self]
        return cfg
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func testTierParsingMetadataAndDownloadURLs() {
        XCTAssertEqual(ASRModelTier.parse("base"), .base)
        XCTAssertEqual(ASRModelTier.parse("ggml-small.bin"), .small)
        XCTAssertEqual(ASRModelTier.parse("small_q5_1"), .smallQ5_1)
        XCTAssertEqual(ASRModelTier.parse("MEDIUM"), .medium)
        XCTAssertNil(ASRModelTier.parse("unknown-tier"))

        XCTAssertEqual(ASRModelTier.infer(fromPath: "/tmp/models/ggml-small-q5_1.bin"), .smallQ5_1)
        XCTAssertTrue(ASRModelTier.small.isRecommended)
        XCTAssertFalse(ASRModelTier.base.isRecommended)

        for tier in ASRModelTier.allCases {
            XCTAssertEqual(tier.expectedSHA256.count, 64)
            let defaultURL = ASRDownloadSource.huggingFace.url(for: tier, environment: [:])
            XCTAssertEqual(
                defaultURL?.absoluteString,
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(tier.fileName)"
            )
            let mirrorURL = ASRDownloadSource.hfMirror.url(for: tier, environment: [:])
            XCTAssertEqual(
                mirrorURL?.absoluteString,
                "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/\(tier.fileName)"
            )
            let overrideURL = ASRDownloadSource.huggingFace.url(
                for: tier,
                environment: ["BEANBRIDGE_MODEL_BASE_URL": "https://mirror.internal.example/whisper/"]
            )
            XCTAssertEqual(
                overrideURL?.absoluteString,
                "https://mirror.internal.example/whisper/\(tier.fileName)"
            )
        }
    }

    func testModelResolutionPriorityVerificationAndDeletion() throws {
        let supportDir = try makeTempSupportDir()
        let manager = ASRModelManager(supportDirectory: supportDir, environmentProvider: { [:] })

        // 1. No local files -> fallback to ggml-base.bin (exists == false)
        let fallback = manager.resolveModel()
        XCTAssertEqual(fallback.source, .fallback)
        XCTAssertEqual(fallback.tier, .base)
        XCTAssertFalse(fallback.exists)

        // 2. Auto-discovery prefers small over base, and medium over small
        let modelsDir = try manager.ensureModelsDirectory()
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: modelsDir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let basePayload = Data("fake-base-model".utf8)
        let smallPayload = Data("fake-small-model".utf8)
        try basePayload.write(to: modelsDir.appendingPathComponent(ASRModelTier.base.fileName))
        XCTAssertEqual(manager.resolveModel().tier, .base)
        XCTAssertEqual(manager.resolveModel().source, .autoDiscovered)

        try smallPayload.write(to: modelsDir.appendingPathComponent(ASRModelTier.small.fileName))
        XCTAssertEqual(manager.resolveModel().tier, .small)
        XCTAssertEqual(manager.resolveModel().source, .autoDiscovered)

        // 3. Explicit user preference overrides auto-discovery
        try manager.setPreferredTier(.base)
        let preferredResolved = manager.resolveModel()
        XCTAssertEqual(preferredResolved.tier, .base)
        XCTAssertEqual(preferredResolved.source, .preference)

        // 4. Environment variable overrides user preference
        let envManager = ASRModelManager(
            supportDirectory: supportDir,
            environmentProvider: { ["BEANBRIDGE_MODEL": "small"] }
        )
        let envResolved = envManager.resolveModel()
        XCTAssertEqual(envResolved.tier, .small)
        XCTAssertEqual(envResolved.source, .environment)
        XCTAssertTrue(envResolved.exists)

        // 5. Verify installed SHA-256 (matching and non-matching)
        XCTAssertTrue(try manager.verifyInstalledModel(.small, expectedSHA256: Self.sha256Hex(smallPayload)))
        XCTAssertFalse(try manager.verifyInstalledModel(.small, expectedSHA256: String(repeating: "0", count: 64)))

        // 6. Deleting the preferred model clears preference and falls back to remaining small
        try manager.deleteInstalledModel(tier: .base)
        XCTAssertFalse(manager.isTierInstalled(.base))
        XCTAssertNil(manager.preferredTier())
        XCTAssertEqual(manager.resolveModel().tier, .small)
        XCTAssertEqual(manager.resolveModel().source, .autoDiscovered)
    }

    func testDownloadManagerSuccessVerifiesSHA256SetsPermissionsAndPreference() throws {
        let supportDir = try makeTempSupportDir()
        let modelManager = ASRModelManager(supportDirectory: supportDir, environmentProvider: { [:] })
        let payload = Data(repeating: 0x5A, count: 128 * 1024)
        let expectedSHA = Self.sha256Hex(payload)

        StubModelURLProtocol.setHandler { _ in
            .data(statusCode: 200, payload: payload)
        }
        addTeardownBlock { StubModelURLProtocol.setHandler(nil) }

        let downloader = ASRModelDownloadManager(
            modelManager: modelManager,
            sessionConfiguration: makeStubConfiguration(),
            environmentProvider: { [:] },
            expectedSHAResolver: { _ in expectedSHA }
        )

        let completed = expectation(description: "download completes")
        let observedPhases = SyncBox<[ASRModelDownloadPhase]>([])
        downloader.onSnapshotsChanged = { snapshots in
            guard let snap = snapshots[.small] else { return }
            let shouldFulfill = observedPhases.withLock { phases -> Bool in
                phases.append(snap.phase)
                switch snap.phase {
                case .completed, .failed, .cancelled:
                    return true
                case .idle, .downloading, .verifying:
                    return false
                }
            }
            if shouldFulfill {
                completed.fulfill()
            }
        }

        downloader.startDownload(tier: .small, source: .hfMirror, setAsDefaultOnSuccess: true)
        wait(for: [completed], timeout: 5.0)

        let phases = observedPhases.get()
        XCTAssertTrue(phases.contains { if case .verifying = $0 { return true }; return false }, "Phases: \(phases)")
        XCTAssertEqual(downloader.snapshot(for: .small)?.phase, .completed(modelURL: modelManager.modelsDirectory.appendingPathComponent(ASRModelTier.small.fileName), sizeBytes: Int64(payload.count)))
        XCTAssertFalse(downloader.isDownloadingAny())
        XCTAssertNil(downloader.activeProgressSummary())

        let finalURL = modelManager.modelsDirectory.appendingPathComponent(ASRModelTier.small.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(try Data(contentsOf: finalURL), payload)

        let fileAttrs = try FileManager.default.attributesOfItem(atPath: finalURL.path)
        XCTAssertEqual((fileAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        XCTAssertEqual(modelManager.preferredTier(), .small)
        XCTAssertEqual(modelManager.resolveModel().tier, .small)
        XCTAssertEqual(modelManager.resolveModel().source, .preference)
    }

    func testDownloadManagerRejectsChecksumMismatchAndCleansUpTempFiles() throws {
        let supportDir = try makeTempSupportDir()
        let modelManager = ASRModelManager(supportDirectory: supportDir, environmentProvider: { [:] })
        let payload = Data("corrupted-model-bytes".utf8)

        StubModelURLProtocol.setHandler { _ in
            .data(statusCode: 200, payload: payload)
        }
        addTeardownBlock { StubModelURLProtocol.setHandler(nil) }

        let downloader = ASRModelDownloadManager(
            modelManager: modelManager,
            sessionConfiguration: makeStubConfiguration(),
            environmentProvider: { [:] },
            expectedSHAResolver: { _ in String(repeating: "f", count: 64) }
        )

        let failed = expectation(description: "checksum failure")
        let failureMessage = SyncBox<String?>(nil)
        downloader.onSnapshotsChanged = { snapshots in
            if case let .failed(msg) = snapshots[.smallQ5_1]?.phase {
                failureMessage.withLock { $0 = msg }
                failed.fulfill()
            }
        }

        downloader.startDownload(tier: .smallQ5_1, source: .huggingFace, setAsDefaultOnSuccess: true)
        wait(for: [failed], timeout: 5.0)

        XCTAssertTrue(failureMessage.get()?.contains("SHA-256") == true)
        XCTAssertFalse(modelManager.isTierInstalled(.smallQ5_1))
        XCTAssertNil(modelManager.preferredTier())

        let contents = try FileManager.default.contentsOfDirectory(atPath: modelManager.modelsDirectory.path)
        XCTAssertTrue(contents.isEmpty, "Unexpected leftover files: \(contents)")
    }

    func testDownloadManagerRejectsHTTPErrorAndSupportsClearSnapshot() throws {
        let supportDir = try makeTempSupportDir()
        let modelManager = ASRModelManager(supportDirectory: supportDir, environmentProvider: { [:] })

        StubModelURLProtocol.setHandler { _ in
            .data(statusCode: 404, payload: Data("Not Found".utf8))
        }
        addTeardownBlock { StubModelURLProtocol.setHandler(nil) }

        let downloader = ASRModelDownloadManager(
            modelManager: modelManager,
            sessionConfiguration: makeStubConfiguration(),
            environmentProvider: { [:] }
        )

        let failed = expectation(description: "HTTP 404 failed")
        downloader.onSnapshotsChanged = { snapshots in
            if case .failed = snapshots[.medium]?.phase {
                failed.fulfill()
            }
        }

        downloader.startDownload(tier: .medium, source: .huggingFace, setAsDefaultOnSuccess: true)
        wait(for: [failed], timeout: 5.0)

        if case let .failed(msg)? = downloader.snapshot(for: .medium)?.phase {
            XCTAssertTrue(msg.contains("404"))
        } else {
            XCTFail("Expected .failed phase for HTTP 404")
        }
        XCTAssertFalse(modelManager.isTierInstalled(.medium))

        downloader.clearSnapshot(for: .medium)
        XCTAssertNil(downloader.snapshot(for: .medium))
    }

    func testDownloadManagerCancellationTransitionsCleanly() throws {
        let supportDir = try makeTempSupportDir()
        let modelManager = ASRModelManager(supportDirectory: supportDir, environmentProvider: { [:] })

        StubModelURLProtocol.setHandler { _ in
            .hangUntilCancelled
        }
        addTeardownBlock { StubModelURLProtocol.setHandler(nil) }

        let downloader = ASRModelDownloadManager(
            modelManager: modelManager,
            sessionConfiguration: makeStubConfiguration(),
            environmentProvider: { [:] }
        )

        let started = expectation(description: "download started")
        let cancelled = expectation(description: "download cancelled")
        let state = SyncBox((fulfilledStart: false, fulfilledCancel: false))

        downloader.onSnapshotsChanged = { snapshots in
            guard let snap = snapshots[.base] else { return }
            switch snap.phase {
            case .downloading:
                let shouldFulfill = state.withLock { s -> Bool in
                    guard !s.fulfilledStart else { return false }
                    s.fulfilledStart = true
                    return true
                }
                if shouldFulfill { started.fulfill() }
            case .cancelled:
                let shouldFulfill = state.withLock { s -> Bool in
                    guard !s.fulfilledCancel else { return false }
                    s.fulfilledCancel = true
                    return true
                }
                if shouldFulfill { cancelled.fulfill() }
            default:
                break
            }
        }

        downloader.startDownload(tier: .base, source: .huggingFace, setAsDefaultOnSuccess: true)
        wait(for: [started], timeout: 5.0)
        downloader.cancelDownload(tier: .base)
        wait(for: [cancelled], timeout: 5.0)

        XCTAssertFalse(downloader.isDownloadingAny())
        XCTAssertFalse(modelManager.isTierInstalled(.base))
    }
}
