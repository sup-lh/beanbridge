import Foundation
import XCTest
@testable import VoiceRouting

private struct MockTargetAdapter: AppTargetAdapter {
    let appID: String
    let displayName: String
    let bundleIdentifiers: [String]
    let linkPlaceholder: String
    var parsedPrefix: String = "mock://chat/"

    @MainActor func needsNewChat() -> Bool { false }
    @MainActor func captureCurrentTarget(copyKeyCode: CGKeyCode) async throws -> String { "captured" }

    func parseLink(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(parsedPrefix) else {
            throw RoutingError("invalid mock link")
        }
        return String(trimmed.dropFirst(parsedPrefix.count))
    }

    func validate(id: String, supportDirectory: URL) throws -> VoiceTarget {
        VoiceTarget(id: id, title: "Mock \(id)", appID: appID)
    }

    func createNewSession(messageID: UUID, supportDirectory: URL) throws -> VoiceTarget {
        VoiceTarget(id: messageID.uuidString, title: "New Mock", appID: appID)
    }

    func submit(text: String, to target: VoiceTarget, supportDirectory: URL) throws -> String {
        "ok-\(target.id)"
    }
}

final class MultiAppRoutingTests: XCTestCase {
    private let sampleUUID = "11111111-1111-4111-8111-111111111111"

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbridge-routing-tests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - ChatLink.parse

    func testChatLinkParseAcceptsValidCodexAndDoubaoLinks() throws {
        let upperUUID = sampleUUID.uppercased()
        let codex = try ChatLink.parse("  codex://threads/\(upperUUID)\n")
        XCTAssertEqual(codex.appID, "codex")
        XCTAssertEqual(codex.id, sampleUUID)

        let validDoubaoCases: [(String, String)] = [
            ("doubao://chat/abc_123-XYZ.0", "abc_123-XYZ.0"),
            ("  doubao://thread/thread-42\n", "thread-42"),
            ("doubaowork://chat/work_99", "work_99"),
            ("doubaowork://thread/work.thread-1", "work.thread-1"),
            ("https://www.doubao.com/chat/9876543210", "9876543210"),
            ("doubao://chat/\(String(repeating: "a", count: 128))", String(repeating: "a", count: 128))
        ]
        for (raw, expectedID) in validDoubaoCases {
            let parsed = try ChatLink.parse(raw)
            XCTAssertEqual(parsed.appID, "doubao", raw)
            XCTAssertEqual(parsed.id, expectedID, raw)
        }
    }

    func testChatLinkParseRejectsMaliciousAndOutOfBoundsInputs() {
        let overlengthID = String(repeating: "a", count: 129)
        let invalidInputs = [
            "",
            "   \n",
            // Codex invalid / ambiguous
            "codex://threads/not-a-uuid",
            "codex://threads/new",
            "codex://threads/\(sampleUUID)/extra",
            "codex://threads/\(sampleUUID)?remote=1",
            "codex://threads/\(sampleUUID)#frag",
            "codex://user@threads/\(sampleUUID)",
            "codex://threads:8080/\(sampleUUID)",
            // Doubao credentials, ports, query, fragments
            "doubao://user@chat/123",
            "doubao://user:pass@chat/123",
            "doubao://chat:8080/123",
            "doubao://chat/123?query=1",
            "doubao://chat/123#section",
            "https://user@www.doubao.com/chat/123",
            "https://www.doubao.com:443/chat/123",
            "https://www.doubao.com/chat/123?from=web",
            "https://www.doubao.com/chat/123#anchor",
            // Doubao path traversal, percent-encoding tricks, empty/reserved IDs
            "doubao://chat",
            "doubao://chat/",
            "doubao://chat/.",
            "doubao://chat/..",
            "doubao://chat/a..b",
            "doubao://chat/a/b",
            "doubao://chat/new",
            "doubao://chat/NEW",
            "doubao://chat/%2e%2e",
            "doubao://chat/abc%2fdef",
            "doubao://chat/abc%20def",
            "doubaowork://chat/new",
            "doubaowork://settings/123",
            "https://www.doubao.com/chat",
            "https://www.doubao.com/chat/",
            "https://www.doubao.com/chat/new",
            "https://www.doubao.com/chat/..",
            "https://www.doubao.com/chat/a/b",
            "https://www.doubao.com/chat/%2e%2e",
            // Wrong schemes/hosts & disallowed characters/length
            "http://www.doubao.com/chat/123",
            "https://doubao.com/chat/123",
            "https://evil.doubao.com/chat/123",
            "https://www.doubao.com/other/123",
            "doubao://other/123",
            "doubao://chat/abc$def",
            "doubao://chat/abc\\def",
            "doubao://chat/会话123",
            "doubao://chat/\(overlengthID)"
        ]
        for raw in invalidInputs {
            XCTAssertThrowsError(try ChatLink.parse(raw), "Expected failure for: \(raw)")
        }

        XCTAssertThrowsError(try DoubaoTargetAdapter().parseLink("codex://threads/\(sampleUUID)"))
        XCTAssertThrowsError(try ChatLink.parse("invalid", defaultAppID: "codex")) { error in
            XCTAssertTrue("\(error)".contains("Codex"))
        }
        XCTAssertThrowsError(try ChatLink.parse("invalid", defaultAppID: "doubao")) { error in
            XCTAssertTrue("\(error)".contains("豆包"))
        }
    }

    // MARK: - Backward-Compatible JSON Decoding

    func testVoiceTargetAndPendingMessageDecodeLegacyJSONWithoutAppID() throws {
        let decoder = JSONDecoder()

        let legacyTargetJSON = Data(#"{"id":"\#(sampleUUID)","title":"Legacy Thread"}"#.utf8)
        let decodedTarget = try decoder.decode(VoiceTarget.self, from: legacyTargetJSON)
        XCTAssertEqual(decodedTarget.id, sampleUUID)
        XCTAssertEqual(decodedTarget.title, "Legacy Thread")
        XCTAssertEqual(decodedTarget.appID, "codex")

        let normalizedTargetJSON = Data(#"{"id":"abc","title":"Doubao","appID":"  DouBao \n"}"#.utf8)
        XCTAssertEqual(try decoder.decode(VoiceTarget.self, from: normalizedTargetJSON).appID, "doubao")

        let blankAppIDTargetJSON = Data(#"{"id":"abc","title":"Blank","appID":"   "}"#.utf8)
        XCTAssertEqual(try decoder.decode(VoiceTarget.self, from: blankAppIDTargetJSON).appID, "codex")

        let msgID = UUID()
        let legacyMessageNoTarget = Data("""
        {
          "id": "\(msgID.uuidString)",
          "createdAt": 1000,
          "text": "hello legacy",
          "state": "pending",
          "note": "saved before multi-app"
        }
        """.utf8)
        let decodedNoTarget = try decoder.decode(PendingMessage.self, from: legacyMessageNoTarget)
        XCTAssertEqual(decodedNoTarget.id, msgID)
        XCTAssertEqual(decodedNoTarget.appID, "codex")
        XCTAssertNil(decodedNoTarget.target)

        let legacyMessageWithDoubaoTarget = Data("""
        {
          "id": "\(msgID.uuidString)",
          "createdAt": 1000,
          "text": "inherit target app",
          "target": {"id": "db-1", "title": "豆包对话", "appID": "doubao"},
          "state": "pending",
          "note": ""
        }
        """.utf8)
        let decodedWithDoubao = try decoder.decode(PendingMessage.self, from: legacyMessageWithDoubaoTarget)
        XCTAssertEqual(decodedWithDoubao.appID, "doubao")
        XCTAssertEqual(decodedWithDoubao.target?.appID, "doubao")

        let legacyMessageWithLegacyTarget = Data("""
        {
          "id": "\(msgID.uuidString)",
          "createdAt": 1000,
          "text": "both legacy",
          "target": {"id": "\(sampleUUID)", "title": "Old Codex"},
          "state": "queued",
          "note": "done"
        }
        """.utf8)
        let decodedBothLegacy = try decoder.decode(PendingMessage.self, from: legacyMessageWithLegacyTarget)
        XCTAssertEqual(decodedBothLegacy.appID, "codex")
        XCTAssertEqual(decodedBothLegacy.target?.appID, "codex")
        XCTAssertEqual(decodedBothLegacy.state, .queued)
    }

    func testPendingStoreLoadsLegacyMessageFileFromDisk() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let msgID = UUID()
        let legacyFile = dir.appendingPathComponent("\(msgID.uuidString).json")
        let legacyPayload = Data("""
        {
          "id": "\(msgID.uuidString)",
          "createdAt": 0,
          "text": "from disk",
          "target": {"id": "\(sampleUUID)", "title": "Legacy"},
          "state": "pending",
          "note": "v1"
        }
        """.utf8)
        try legacyPayload.write(to: legacyFile)

        let messages = try PendingStore(directory: dir).messages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].appID, "codex")
        XCTAssertEqual(messages[0].target?.appID, "codex")
        XCTAssertEqual(messages[0].text, "from disk")
    }

    // MARK: - AppTargetRegistry & TargetAppPreferenceStore

    func testAppTargetRegistryRegisterLookupAndExtensionAdapter() throws {
        let registry = AppTargetRegistry()
        XCTAssertEqual(registry.allAdapters.map(\.appID), ["codex", "doubao", "paseo"])
        XCTAssertTrue(registry.contains("  DOUBAO \n"))
        XCTAssertTrue(registry.contains("  PASEO \n"))
        XCTAssertFalse(registry.contains("unknown"))
        XCTAssertThrowsError(try registry.requireAdapter(for: "unknown"))

        let custom = MockTargetAdapter(
            appID: "  Claude ",
            displayName: "Claude",
            bundleIdentifiers: ["com.anthropic.claudefordesktop"],
            linkPlaceholder: "mock://chat/..."
        )
        registry.register(custom)
        XCTAssertTrue(registry.contains("claude"))
        XCTAssertEqual(try registry.requireAdapter(for: "CLAUDE").displayName, "Claude")
        XCTAssertEqual(registry.allAdapters.map(\.appID), ["codex", "doubao", "paseo", "  Claude "])

        // Re-registering same normalized ID replaces adapter without duplicating order entry
        let updatedCustom = MockTargetAdapter(
            appID: "claude",
            displayName: "Claude Updated",
            bundleIdentifiers: ["com.anthropic.claudefordesktop"],
            linkPlaceholder: "mock://chat/..."
        )
        registry.register(updatedCustom)
        XCTAssertEqual(registry.allAdapters.count, 4)
        XCTAssertEqual(registry.adapter(for: "claude")?.displayName, "Claude Updated")

        // Empty appID is ignored
        let emptyAdapter = MockTargetAdapter(
            appID: "   ",
            displayName: "Empty",
            bundleIdentifiers: [],
            linkPlaceholder: ""
        )
        registry.register(emptyAdapter)
        XCTAssertEqual(registry.allAdapters.count, 4)

        // Default extension methods
        let target = VoiceTarget(id: "id-1", title: "T", appID: "claude")
        XCTAssertNoThrow(try updatedCustom.openSession(target))
        XCTAssertNil(updatedCustom.canonicalLink(for: "id-1"))
        XCTAssertEqual(CodexTargetAdapter().canonicalLink(for: sampleUUID), "codex://threads/\(sampleUUID)")
        XCTAssertEqual(DoubaoTargetAdapter().canonicalLink(for: "c-1"), "doubao://chat/c-1")
    }

    func testTargetAppPreferenceStorePersistencePermissionsAndEnvOverride() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let registry = AppTargetRegistry()
        let custom = MockTargetAdapter(
            appID: "claude",
            displayName: "Claude",
            bundleIdentifiers: ["com.anthropic.claude"],
            linkPlaceholder: "mock://chat/..."
        )
        registry.register(custom)

        final class EnvBox: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String: String] = [:]
            func get() -> [String: String] { lock.lock(); defer { lock.unlock() }; return values }
            func set(_ key: String, _ value: String?) {
                lock.lock(); defer { lock.unlock() }
                values[key] = value
            }
        }
        let env = EnvBox()
        let store = TargetAppPreferenceStore(
            supportDirectory: dir,
            registry: registry,
            environmentProvider: { env.get() }
        )

        // Default state
        XCTAssertFalse(store.isOverriddenByEnvironment)
        XCTAssertEqual(try store.resolveAppID(), "codex")
        XCTAssertEqual(try store.persistedAppID(), "codex")
        XCTAssertEqual(store.currentAppID(), "codex")
        XCTAssertEqual(store.currentAdapter().appID, "codex")

        // Unknown appID rejected before writing
        XCTAssertThrowsError(try store.setCurrentAppID("nonexistent"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.preferenceFileURL.path))

        // Persist doubao and verify 0o700 / 0o600 permissions + reload
        let selected = try store.setCurrentAppID("  DouBao \n")
        XCTAssertEqual(selected.appID, "doubao")

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: store.preferenceFileURL.path)
        XCTAssertEqual((fileAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reloaded = TargetAppPreferenceStore(
            supportDirectory: dir,
            registry: registry,
            environmentProvider: { env.get() }
        )
        XCTAssertEqual(try reloaded.persistedAppID(), "doubao")
        XCTAssertEqual(try reloaded.resolveAppID(), "doubao")
        XCTAssertEqual(reloaded.currentAdapter().appID, "doubao")

        // Whitespace-only env var does not override
        env.set(TargetAppPreferenceStore.environmentKey, "   \n")
        XCTAssertFalse(reloaded.isOverriddenByEnvironment)
        XCTAssertEqual(try reloaded.resolveAppID(), "doubao")

        // BEANBRIDGE_TARGET_APP overrides persisted preference without altering disk
        env.set(TargetAppPreferenceStore.environmentKey, "  CLAUDE ")
        XCTAssertTrue(reloaded.isOverriddenByEnvironment)
        XCTAssertEqual(try reloaded.resolveAppID(), "claude")
        XCTAssertEqual(reloaded.currentAppID(), "claude")
        XCTAssertEqual(reloaded.currentAdapter().appID, "claude")
        XCTAssertEqual(try reloaded.persistedAppID(), "doubao")

        // Unknown BEANBRIDGE_TARGET_APP throws on resolveAppID, safely falls back in currentAppID
        env.set(TargetAppPreferenceStore.environmentKey, "bogus-app")
        XCTAssertTrue(reloaded.isOverriddenByEnvironment)
        XCTAssertThrowsError(try reloaded.resolveAppID())
        XCTAssertEqual(reloaded.currentAppID(), "codex")
        XCTAssertEqual(reloaded.currentAdapter().appID, "codex")

        // Empty preference file falls back to default
        env.set(TargetAppPreferenceStore.environmentKey, nil)
        try Data("   \n".utf8).write(to: store.preferenceFileURL, options: .atomic)
        XCTAssertEqual(try reloaded.persistedAppID(), "codex")
    }

    // MARK: - Cross-App PendingStore State Machine

    func testDoubaoPendingStoreCrashRecoveryAndIdempotentStateMachine() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PendingStore(directory: dir)
        let message = PendingMessage(text: "给豆包发消息", appID: "doubao", target: nil, note: "等待新建")
        try store.save(message)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let filePath = dir.appendingPathComponent(message.id.uuidString + ".json").path
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: filePath)
        XCTAssertEqual((fileAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Claim creation once -> .creating, preserves appID = "doubao"
        let creating = try store.beginCreation(message.id)
        XCTAssertEqual(creating.state, .creating)
        XCTAssertEqual(creating.appID, "doubao")
        XCTAssertNil(creating.target)

        // Simulated restart while .creating: neither creation nor submission can proceed
        let restarted = PendingStore(directory: dir)
        let doubaoTarget = VoiceTarget(id: "db_conv_001", title: "豆包新会话", appID: "doubao")
        XCTAssertThrowsError(try restarted.beginCreation(message.id))
        XCTAssertThrowsError(try restarted.beginSubmission(message.id, target: doubaoTarget))

        // Creation receipt arrives -> restore .pending with target, then claim submission once
        var created = creating
        created.target = doubaoTarget
        created.state = .pending
        try restarted.save(created)

        // beginCreation now fails because target != nil
        XCTAssertThrowsError(try restarted.beginCreation(message.id))

        let submitting = try restarted.beginSubmission(message.id, target: doubaoTarget)
        XCTAssertEqual(submitting.state, .submitting)
        XCTAssertEqual(submitting.appID, "doubao")
        XCTAssertEqual(submitting.target, doubaoTarget)

        // Re-claiming submission after restart with another target or appID is rejected
        let secondStore = PendingStore(directory: dir)
        let alternateCodexTarget = VoiceTarget(id: sampleUUID, title: "Codex", appID: "codex")
        XCTAssertThrowsError(try secondStore.beginSubmission(message.id, target: doubaoTarget))
        XCTAssertThrowsError(try secondStore.beginSubmission(message.id, target: alternateCodexTarget))

        let persisted = try XCTUnwrap(secondStore.messages().first)
        XCTAssertEqual(persisted.appID, "doubao")
        XCTAssertEqual(persisted.target, doubaoTarget)
        XCTAssertEqual(persisted.state, .submitting)
    }

    func testPendingStoreCrossAppExplicitAssignmentUpdatesAppID() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PendingStore(directory: dir)
        let first = PendingMessage(text: "first", target: nil, note: "default codex")
        try store.save(first)
        XCTAssertEqual(first.appID, "codex")

        // Explicit assignment to a doubao target updates message.appID to "doubao"
        let doubaoTarget = VoiceTarget(id: "conv_99", title: "Doubao Target", appID: "doubao")
        let claimed = try store.beginSubmission(first.id, target: doubaoTarget)
        XCTAssertEqual(claimed.appID, "doubao")
        XCTAssertEqual(claimed.target, doubaoTarget)
        XCTAssertEqual(claimed.state, .submitting)

        let second = PendingMessage(text: "second", appID: "doubao", target: doubaoTarget, note: "pinned")
        try store.save(second)

        let loaded = try PendingStore(directory: dir).messages()
        XCTAssertEqual(loaded.map(\.id), [first.id, second.id])
        XCTAssertEqual(loaded.map(\.appID), ["doubao", "doubao"])
    }

    func testMultiAppSwitchPersistenceAndDoubaoSessionCreationAndValidation() throws {
        let supportDir = makeTempDirectory()
        let scriptsDir = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDir)
            try? FileManager.default.removeItem(at: scriptsDir)
        }
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

        let stubScript = scriptsDir.appendingPathComponent("doubao-chat.py")
        try """
        import json, sys
        args = sys.argv[1:]
        action = args[args.index('--action') + 1]
        if action == 'create':
            print(json.dumps({'id': 'doubao_created_42', 'title': '豆包新会话', 'appID': 'doubao'}))
        elif action == 'validate':
            cid = args[args.index('--id') + 1]
            print(json.dumps({'id': cid, 'title': f'豆包 {cid}', 'appID': 'doubao'}))
        elif action == 'submit':
            print(json.dumps({'receipt': 'doubao-stub-receipt'}))
        """.write(to: stubScript, atomically: true, encoding: .utf8)

        let prefStore = TargetAppPreferenceStore(
            supportDirectory: supportDir,
            environmentProvider: { [:] }
        )
        _ = try prefStore.setCurrentAppID("doubao")
        XCTAssertEqual(try TargetAppPreferenceStore(supportDirectory: supportDir, environmentProvider: { [:] }).persistedAppID(), "doubao")
        _ = try prefStore.setCurrentAppID("codex")
        XCTAssertEqual(try TargetAppPreferenceStore(supportDirectory: supportDir, environmentProvider: { [:] }).persistedAppID(), "codex")
        _ = try prefStore.setCurrentAppID("doubao")
        XCTAssertEqual(prefStore.currentAdapter().appID, "doubao")

        let adapter = DoubaoTargetAdapter(scriptsDirectory: scriptsDir, environmentProvider: { [:] })
        let created = try adapter.createNewSession(messageID: UUID(), supportDirectory: supportDir)
        XCTAssertEqual(created.appID, "doubao")
        XCTAssertEqual(created.id, "doubao_created_42")

        let canonical = try XCTUnwrap(adapter.canonicalLink(for: created.id))
        XCTAssertEqual(canonical, "doubao://chat/doubao_created_42")
        XCTAssertEqual(try adapter.parseLink(canonical), created.id)

        let validated = try adapter.validate(id: created.id, supportDirectory: supportDir)
        XCTAssertEqual(validated.id, created.id)
        XCTAssertEqual(validated.appID, "doubao")

        let receipt = try adapter.submit(text: "你好 $(literal)", to: validated, supportDirectory: supportDir)
        XCTAssertEqual(receipt, "doubao-stub-receipt")

        // Reject invalid session ID returned from helper script (traversal guard)
        try """
        import json
        print(json.dumps({'id': '../evil', 'title': 'Bad', 'appID': 'doubao'}))
        """.write(to: stubScript, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try adapter.createNewSession(messageID: UUID(), supportDirectory: supportDir))
    }

    func testConcurrentBeginCreationAndTerminalStatesPreventDuplicateDoubaoSend() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PendingStore(directory: dir)
        let message = PendingMessage(text: "并发创建\n$(safe)", appID: "doubao", target: nil, note: "")
        try store.save(message)

        let lock = NSLock()
        var creationWinners = 0
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if (try? store.beginCreation(message.id)) != nil {
                lock.lock(); creationWinners += 1; lock.unlock()
            }
        }
        XCTAssertEqual(creationWinners, 1)

        // Terminal states (.queued / .uncertain) must never allow re-creation or re-submission
        let target = VoiceTarget(id: "db_term_1", title: "豆包", appID: "doubao")
        for state in [PendingMessage.State.queued, .uncertain] {
            var terminal = message
            terminal.target = target
            terminal.state = state
            try store.save(terminal)
            XCTAssertThrowsError(try store.beginCreation(message.id))
            XCTAssertThrowsError(try store.beginSubmission(message.id, target: target))
        }
        XCTAssertEqual(try PendingStore(directory: dir).messages().first?.text, "并发创建\n$(safe)")
    }

    func testDoubaoObservedAXURLInterpretation() {
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("https://www.doubao.com/chat/1234567890?from=desktop"),
            .chatID("1234567890")
        )
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("https://inhouse.doubao.com/chat/conv_abc-1/"),
            .chatID("conv_abc-1")
        )
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("doubaowork://chat/work_chat_99"),
            .chatID("work_chat_99")
        )
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("https://www.doubao.com/chat/"),
            .blankChat
        )
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("https://www.doubao.com/chat/local"),
            .blankChat
        )
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("doubaowork://doubaowork-chat"),
            .chatID("doubaowork-active")
        )
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("chrome://doubaowork-chat/chat"),
            .chatID("doubaowork-active")
        )
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("doubaowork://doubaowork-launcher"),
            .blankChat
        )
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("https://evil.example.com/chat/123"),
            .unrecognized
        )
        XCTAssertEqual(
            DoubaoTargetAdapter.interpretObservedURL("https://www.doubao.com/chat/.."),
            .unrecognized
        )
    }

    func testDoubaoPlaceholderFilterRecognizesEmptyPromptAndPreservesRealDrafts() {
        XCTAssertTrue(CurrentChat.isDoubaoPlaceholderOrEmpty(nil))
        XCTAssertTrue(CurrentChat.isDoubaoPlaceholderOrEmpty("   \n\u{200B}"))
        XCTAssertTrue(CurrentChat.isDoubaoPlaceholderOrEmpty("发消息或创建任务... / 使用技能 @ 添加资料"))
        XCTAssertTrue(CurrentChat.isDoubaoPlaceholderOrEmpty("发消息或创建任务… / 使用技能 @ 添加资料\n"))
        XCTAssertFalse(CurrentChat.isDoubaoPlaceholderOrEmpty("收到请回复收到"))
        XCTAssertFalse(CurrentChat.isDoubaoPlaceholderOrEmpty("发消息或创建任务测试草稿"))
    }
}
