import AppKit
import ApplicationServices
import Foundation

public protocol AppTargetAdapter: Sendable {
    var appID: String { get }
    var displayName: String { get }
    var bundleIdentifiers: [String] { get }
    var linkPlaceholder: String { get }
    @MainActor func needsNewChat() -> Bool
    @MainActor func captureCurrentTarget(copyKeyCode: CGKeyCode) async throws -> String
    func parseLink(_ raw: String) throws -> String
    func validate(id: String, supportDirectory: URL) throws -> VoiceTarget
    func createNewSession(messageID: UUID, supportDirectory: URL) throws -> VoiceTarget
    func submit(text: String, to target: VoiceTarget, supportDirectory: URL) throws -> String
    func openSession(_ target: VoiceTarget) throws
    func canonicalLink(for id: String) -> String?
}

public extension AppTargetAdapter {
    func openSession(_ target: VoiceTarget) throws {}
    func canonicalLink(for id: String) -> String? { nil }
}

enum AdapterTools {
    static func resolveExecutable(
        name: String,
        override: String?,
        preferred: [String] = [],
        searchPath: String? = nil
    ) -> String? {
        let files = FileManager.default
        if let override, !override.isEmpty {
            return files.isExecutableFile(atPath: override) ? override : nil
        }
        let dirs = (searchPath ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return (preferred + dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path })
            .first { files.isExecutableFile(atPath: $0) }
    }

    static func resolvePython(environment: [String: String]) throws -> String {
        if let path = resolveExecutable(
            name: "python3",
            override: environment["BEANBRIDGE_PYTHON"],
            preferred: ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"],
            searchPath: environment["PATH"]
        ) {
            return path
        }
        throw RoutingError("找不到可执行程序：python3。")
    }

    static func resolveHelperScript(
        _ name: String,
        scriptsDirectory: URL?,
        environment: [String: String]
    ) -> URL {
        if let scriptsDirectory {
            return scriptsDirectory.appendingPathComponent(name)
        }
        if let envDir = environment["BEANBRIDGE_SCRIPTS_DIR"], !envDir.isEmpty {
            let candidate = URL(fileURLWithPath: envDir).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts")
            .appendingPathComponent(name)
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        final class OutputBox: @unchecked Sendable {
            var stdout = Data()
            var stderr = Data()
        }
        let box = OutputBox()
        let group = DispatchGroup()

        try process.run()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw RoutingError("处理超时；本次没有自动重试")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(decoding: box.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !errText.isEmpty {
                throw RoutingError(errText)
            }
            throw RoutingError("工具退出，状态码 \(process.terminationStatus)")
        }
        return String(decoding: box.stdout, as: UTF8.self)
    }

    private final class MainActorResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    static func runOnMainActor<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) throws -> T {
        guard !Thread.isMainThread else {
            throw RoutingError("内部调度错误：不能在主线程同步等待界面操作。")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = MainActorResultBox<T>()
        Task { @MainActor in
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    static func claimExclusiveJSONReceipt(at url: URL, payload: [String: String]) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else {
            throw RoutingError("无法创建唯一投递回执（错误码 \(errno)）：\(url.lastPathComponent)")
        }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written < 0 {
                    throw RoutingError("写入投递回执失败（错误码 \(errno)）。")
                }
                offset += written
                remaining -= written
            }
        }
    }

    static func writeAtomicJSONReceipt(at url: URL, payload: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct CodexTargetAdapter: AppTargetAdapter {
    public static let defaultBundleID = "com.openai.codex"

    public let appID = "codex"
    public let displayName = "Codex"
    public let linkPlaceholder = "粘贴 codex://threads/… 聊天链接"

    private let codexExecutableOverride: String?
    private let scriptsDirectory: URL?
    private let environmentProvider: @Sendable () -> [String: String]

    public init(
        codexExecutable: String? = nil,
        scriptsDirectory: URL? = nil,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.codexExecutableOverride = codexExecutable
        self.scriptsDirectory = scriptsDirectory
        self.environmentProvider = environmentProvider
    }

    public var bundleIdentifiers: [String] {
        let env = environmentProvider()
        if let custom = env["BEANBRIDGE_CODEX_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty, custom != Self.defaultBundleID {
            return [custom, Self.defaultBundleID]
        }
        return [Self.defaultBundleID]
    }

    private func resolveCodex(environment: [String: String]) throws -> String {
        let override = codexExecutableOverride ?? environment["BEANBRIDGE_CODEX"]
        guard let executable = AdapterTools.resolveExecutable(
            name: "codex",
            override: override,
            preferred: ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"],
            searchPath: environment["PATH"]
        ) else {
            throw RoutingError("找不到可执行程序：codex。可通过 BEANBRIDGE_CODEX 指定路径。")
        }
        return executable
    }

    @MainActor
    public func needsNewChat() -> Bool {
        CurrentChat.needsNewChat(bundleIdentifiers: bundleIdentifiers)
    }

    @MainActor
    public func captureCurrentTarget(copyKeyCode: CGKeyCode) async throws -> String {
        try await CurrentChat.capture(
            bundleIdentifiers: bundleIdentifiers,
            appName: displayName,
            keyCode: copyKeyCode,
            parseLink: { raw in try ChatLink.threadID(raw) }
        )
    }

    public func parseLink(_ raw: String) throws -> String {
        try ChatLink.threadID(raw)
    }

    public func validate(id: String, supportDirectory: URL) throws -> VoiceTarget {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else {
            throw RoutingError("Codex 会话 ID 不是有效的 UUID。")
        }
        let normalizedID = uuid.uuidString.lowercased()
        var env = environmentProvider()
        if let codexExecutableOverride, !codexExecutableOverride.isEmpty {
            env["BEANBRIDGE_CODEX"] = codexExecutableOverride
        }
        let python = try AdapterTools.resolvePython(environment: env)
        let helper = AdapterTools.resolveHelperScript(
            "set-target.py",
            scriptsDirectory: scriptsDirectory,
            environment: env
        )
        let output = try AdapterTools.run(
            python,
            [helper.path, "--thread-id", normalizedID, "--json"],
            environment: env,
            timeout: 50
        )
        let decoded = try JSONDecoder().decode(VoiceTarget.self, from: Data(output.utf8))
        guard decoded.id == normalizedID else {
            throw RoutingError("会话校验返回了不同的 ID。")
        }
        return VoiceTarget(id: decoded.id, title: decoded.title, appID: appID)
    }

    public func createNewSession(messageID: UUID, supportDirectory: URL) throws -> VoiceTarget {
        let env = environmentProvider()
        let python = try AdapterTools.resolvePython(environment: env)
        let codex = try resolveCodex(environment: env)
        let helper = AdapterTools.resolveHelperScript(
            "create-chat.py",
            scriptsDirectory: scriptsDirectory,
            environment: env
        )
        let receipt = supportDirectory.appendingPathComponent("Creation/" + messageID.uuidString + ".json")
        let directory = supportDirectory.appendingPathComponent("Chats/" + messageID.uuidString, isDirectory: true)
        let output = try AdapterTools.run(
            python,
            [helper.path, "--codex", codex, "--directory", directory.path, "--receipt", receipt.path],
            environment: env,
            timeout: 70
        )
        let decoded = try JSONDecoder().decode(VoiceTarget.self, from: Data(output.utf8))
        guard UUID(uuidString: decoded.id) != nil else {
            throw RoutingError("创建回执没有有效的会话 ID。")
        }
        return VoiceTarget(id: decoded.id.lowercased(), title: decoded.title, appID: appID)
    }

    public func openSession(_ target: VoiceTarget) throws {
        _ = try AdapterTools.run("/usr/bin/open", ["codex://threads/" + target.id], timeout: 10)
    }

    public func canonicalLink(for id: String) -> String? {
        "codex://threads/" + id
    }

    public func submit(text: String, to target: VoiceTarget, supportDirectory: URL) throws -> String {
        let env = environmentProvider()
        let codex = try resolveCodex(environment: env)
        let receipt = try AdapterTools.run(
            codex,
            ["queue", "--thread", target.id, "--message", text],
            environment: env,
            timeout: 30
        )
        return receipt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct DoubaoTargetAdapter: AppTargetAdapter {
    public static let builtinBundleIdentifiers = [
        "com.bot.pc.doubao",
        "com.work.pc.doubao",
        "com.bytedance.doubao"
    ]

    private static let blankChatRootURLs: Set<String> = [
        "https://www.doubao.com/chat",
        "https://www.doubao.com/chat/",
        "https://www.doubao.com/chat/new",
        "doubao://chat",
        "doubao://chat/",
        "doubao://chat/new",
        "doubaowork://chat",
        "doubaowork://chat/",
        "doubaowork://chat/new"
    ]

    private struct SubmissionResponse: Decodable {
        let receipt: String?
    }

    public let appID = "doubao"
    public let displayName = "豆包"
    public let linkPlaceholder = "粘贴 doubao://chat/… 或 https://www.doubao.com/chat/… 链接"

    private let scriptsDirectory: URL?
    private let environmentProvider: @Sendable () -> [String: String]

    public init(
        scriptsDirectory: URL? = nil,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.scriptsDirectory = scriptsDirectory
        self.environmentProvider = environmentProvider
    }

    public var bundleIdentifiers: [String] {
        let env = environmentProvider()
        var ordered: [String] = []
        var seen = Set<String>()
        if let rawOverride = env["BEANBRIDGE_DOUBAO_BUNDLE_ID"] {
            for candidate in rawOverride.split(separator: ",") {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                    ordered.append(trimmed)
                }
            }
        }
        for builtin in Self.builtinBundleIdentifiers where seen.insert(builtin).inserted {
            ordered.append(builtin)
        }
        return ordered
    }

    private func preferredBundleIdentifier(environment: [String: String]) -> String? {
        if let override = environment["BEANBRIDGE_DOUBAO_BUNDLE_ID"]?
            .split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return override
        }
        let candidates = bundleIdentifiers
        for candidate in candidates {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: candidate)
                .filter({ !$0.isTerminated }).isEmpty {
                return candidate
            }
        }
        for candidate in candidates {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    @MainActor
    public func needsNewChat() -> Bool {
        CurrentChat.needsNewChat(bundleIdentifiers: bundleIdentifiers)
    }

    private static let observedWebHosts: Set<String> = [
        "www.doubao.com",
        "doubao.com",
        "beta.doubao.com",
        "inhouse.doubao.com"
    ]

    public static func interpretObservedURL(_ rawURL: String) -> ObservedDoubaoURLMatch {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return .unrecognized
        }
        let segments = components.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        if scheme == "doubao" || scheme == "doubaowork" || scheme == "chrome" {
            let host = (components.host ?? "").lowercased()
            if host == "doubaowork-chat" {
                if segments.isEmpty || segments == ["chat"] {
                    return .chatID("doubaowork-active")
                }
                if segments.count == 2, (segments[0] == "chat" || segments[0] == "thread"),
                   let valid = try? ChatLink.validateDoubaoID(segments[1]) {
                    return .chatID(valid)
                }
                return .unrecognized
            }
            if host == "doubaowork-launcher" {
                if segments.isEmpty || segments == ["chat"] {
                    return .blankChat
                }
                if segments.count == 2, (segments[0] == "chat" || segments[0] == "thread"),
                   let valid = try? ChatLink.validateDoubaoID(segments[1]) {
                    return .chatID(valid)
                }
                return .unrecognized
            }
            if (scheme == "doubao" || scheme == "doubaowork") && (host == "chat" || host == "thread") {
                if segments.isEmpty || (segments.count == 1 && segments[0].lowercased() == "new") {
                    return .blankChat
                }
                if segments.count == 1, let valid = try? ChatLink.validateDoubaoID(segments[0]) {
                    return .chatID(valid)
                }
                return .unrecognized
            }
            return .unrecognized
        }

        if scheme == "https", let host = components.host?.lowercased(), Self.observedWebHosts.contains(host) {
            if segments.isEmpty {
                return .blankChat
            }
            if segments.count == 1, segments[0] == "chat" || segments[0] == "thread" {
                return .blankChat
            }
            if segments.count == 2, segments[0] == "chat" || segments[0] == "thread" {
                let candidate = segments[1]
                let lower = candidate.lowercased()
                if lower == "new" || lower == "local" {
                    return .blankChat
                }
                if let valid = try? ChatLink.validateDoubaoID(candidate) {
                    return .chatID(valid)
                }
            }
            return .unrecognized
        }

        return .unrecognized
    }

    private func defaultSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnkerVoiceBridge", isDirectory: true)
    }

    private func persistDiagnostics(_ diagnostics: DoubaoAXDiagnostics) {
        let supportDir = defaultSupportDirectory()
        let diagURL = supportDir.appendingPathComponent("doubao-ax-diag.json")
        do {
            try FileManager.default.createDirectory(
                at: supportDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(diagnostics)
            try data.write(to: diagURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagURL.path)
        } catch {
            // Diagnostics persistence is best-effort only.
        }
    }

    private func cacheCapturedChatMetadata(id: String, title: String) {
        let supportDir = defaultSupportDirectory()
        let chatsDir = supportDir.appendingPathComponent("Chats", isDirectory: true)
        let metaURL = chatsDir.appendingPathComponent("doubao-\(id).json")
        do {
            try FileManager.default.createDirectory(
                at: supportDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: chatsDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(VoiceTarget(id: id, title: title, appID: appID))
            try data.write(to: metaURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL.path)
        } catch {
            // Metadata caching is best-effort only.
        }
    }

    @MainActor
    public func captureCurrentTarget(copyKeyCode: CGKeyCode) async throws -> String {
        let outcome = try await CurrentChat.inspectAndCaptureDoubaoTarget(
            bundleIdentifiers: bundleIdentifiers,
            appName: displayName,
            interpretURL: Self.interpretObservedURL
        )
        if environmentProvider()["BEANBRIDGE_DOUBAO_DIAG"] == "1" {
            persistDiagnostics(outcome.diagnostics)
        }

        if let chatID = outcome.chatID {
            let cleanTitle = outcome.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let titleToCache: String
            if chatID == "doubaowork-active",
               cleanTitle.isEmpty || cleanTitle == "豆包工作" || cleanTitle == "为你推荐" {
                titleToCache = "豆包工作 · 当前窗口"
            } else {
                titleToCache = cleanTitle
            }
            if !titleToCache.isEmpty {
                cacheCapturedChatMetadata(id: chatID, title: titleToCache)
            }
            return chatID
        }

        if outcome.isBlankChat {
            throw CurrentChatError.noChatLink
        }

        if let errorText = outcome.diagnostics.error, !errorText.isEmpty {
            throw RoutingError(errorText)
        }

        if outcome.hasWebArea {
            if let observedURL = outcome.diagnostics.webAreas.compactMap(\.url).first(where: { !$0.isEmpty }) {
                throw RoutingError("已读取豆包窗口，但当前页面地址未匹配会话格式：\(observedURL)")
            }
            throw CurrentChatError.noChatLink
        }

        return try await CurrentChat.capture(
            bundleIdentifiers: bundleIdentifiers,
            appName: displayName,
            keyCode: copyKeyCode,
            parseLink: { [self] raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.blankChatRootURLs.contains(trimmed.lowercased()) {
                    throw CurrentChatError.noChatLink
                }
                return try self.parseLink(trimmed)
            }
        )
    }

    public func parseLink(_ raw: String) throws -> String {
        let parsed = try ChatLink.parse(raw, defaultAppID: appID)
        guard parsed.appID == appID else {
            throw RoutingError("请使用有效的豆包聊天链接（doubao://chat/… 或 https://www.doubao.com/chat/…）。")
        }
        return parsed.id
    }

    public func validate(id: String, supportDirectory: URL) throws -> VoiceTarget {
        let cleanID = try ChatLink.validateDoubaoID(id.trimmingCharacters(in: .whitespacesAndNewlines))
        let env = environmentProvider()
        let python = try AdapterTools.resolvePython(environment: env)
        let helper = AdapterTools.resolveHelperScript(
            "doubao-chat.py",
            scriptsDirectory: scriptsDirectory,
            environment: env
        )
        var args = [helper.path, "--action", "validate", "--id", cleanID]
        if let bundleID = preferredBundleIdentifier(environment: env) {
            args += ["--bundle-id", bundleID]
        }
        let output = try AdapterTools.run(python, args, environment: env, timeout: 30)
        let decoded = try JSONDecoder().decode(VoiceTarget.self, from: Data(output.utf8))
        guard decoded.id == cleanID, decoded.appID == appID else {
            throw RoutingError("豆包会话校验返回了不一致的目标信息。")
        }
        return decoded
    }

    public func createNewSession(messageID: UUID, supportDirectory: URL) throws -> VoiceTarget {
        let env = environmentProvider()
        let python = try AdapterTools.resolvePython(environment: env)
        let helper = AdapterTools.resolveHelperScript(
            "doubao-chat.py",
            scriptsDirectory: scriptsDirectory,
            environment: env
        )
        let receipt = supportDirectory.appendingPathComponent("Creation/" + messageID.uuidString + ".json")
        var args = [helper.path, "--action", "create", "--receipt", receipt.path]
        if let bundleID = preferredBundleIdentifier(environment: env) {
            args += ["--bundle-id", bundleID]
        }
        let output = try AdapterTools.run(python, args, environment: env, timeout: 45)
        let decoded = try JSONDecoder().decode(VoiceTarget.self, from: Data(output.utf8))
        let cleanID = try ChatLink.validateDoubaoID(decoded.id)
        return VoiceTarget(id: cleanID, title: decoded.title, appID: appID)
    }

    public func canonicalLink(for id: String) -> String? {
        "doubao://chat/" + id
    }

    public func openSession(_ target: VoiceTarget) throws {
        let env = environmentProvider()
        let bridgeCmd = (env["BEANBRIDGE_DOUBAO_BRIDGE_CMD"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard scriptsDirectory == nil, bridgeCmd.isEmpty, env["BEANBRIDGE_DOUBAO_AX_SUBMIT"] != "0" else {
            return
        }
        guard target.id.hasPrefix("doubao-") else { return }

        let ids = bundleIdentifiers
        let name = displayName
        try AdapterTools.runOnMainActor {
            try await CurrentChat.prepareDoubaoWorkNewTask(bundleIdentifiers: ids, appName: name)
        }
    }

    public func submit(text: String, to target: VoiceTarget, supportDirectory: URL) throws -> String {
        let cleanID = try ChatLink.validateDoubaoID(target.id)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw RoutingError("投递文字不能为空。")
        }
        let env = environmentProvider()
        let bridgeCmd = (env["BEANBRIDGE_DOUBAO_BRIDGE_CMD"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if scriptsDirectory == nil, bridgeCmd.isEmpty, env["BEANBRIDGE_DOUBAO_AX_SUBMIT"] != "0" {
            let receiptURL = supportDirectory.appendingPathComponent(
                "Submissions/doubao-" + UUID().uuidString + ".json"
            )
            try AdapterTools.claimExclusiveJSONReceipt(
                at: receiptURL,
                payload: ["state": "submitting", "appID": appID, "id": cleanID]
            )
            let ids = bundleIdentifiers
            let name = displayName
            do {
                let receiptText = try AdapterTools.runOnMainActor {
                    try await CurrentChat.submitDoubaoWorkViaAX(
                        targetID: cleanID,
                        text: text,
                        bundleIdentifiers: ids,
                        appName: name,
                        interpretURL: Self.interpretObservedURL
                    )
                }
                try? AdapterTools.writeAtomicJSONReceipt(
                    at: receiptURL,
                    payload: [
                        "state": "submitted",
                        "appID": appID,
                        "id": cleanID,
                        "receipt": receiptText
                    ]
                )
                return receiptText
            } catch {
                try? AdapterTools.writeAtomicJSONReceipt(
                    at: receiptURL,
                    payload: [
                        "state": "uncertain",
                        "appID": appID,
                        "id": cleanID,
                        "error": String(describing: error)
                    ]
                )
                throw error
            }
        }

        let python = try AdapterTools.resolvePython(environment: env)
        let helper = AdapterTools.resolveHelperScript(
            "doubao-chat.py",
            scriptsDirectory: scriptsDirectory,
            environment: env
        )
        let receipt = supportDirectory.appendingPathComponent(
            "Submissions/doubao-" + UUID().uuidString + ".json"
        )
        var args = [
            helper.path,
            "--action", "submit",
            "--id", cleanID,
            "--text", text,
            "--receipt", receipt.path
        ]
        if let bundleID = preferredBundleIdentifier(environment: env) {
            args += ["--bundle-id", bundleID]
        }
        let output = try AdapterTools.run(python, args, environment: env, timeout: 40)
        if let parsed = try? JSONDecoder().decode(SubmissionResponse.self, from: Data(output.utf8)),
           let receiptText = parsed.receipt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !receiptText.isEmpty {
            return receiptText
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class AppTargetRegistry: @unchecked Sendable {
    public static let shared = AppTargetRegistry()

    private let lock = NSLock()
    private var adaptersByID: [String: any AppTargetAdapter] = [:]
    private var order: [String] = []

    public init(adapters: [any AppTargetAdapter] = [CodexTargetAdapter(), DoubaoTargetAdapter(), PaseoTargetAdapter()]) {
        for adapter in adapters {
            let key = Self.normalize(adapter.appID)
            guard !key.isEmpty else { continue }
            if adaptersByID[key] == nil {
                order.append(key)
            }
            adaptersByID[key] = adapter
        }
    }

    public static func normalize(_ appID: String) -> String {
        appID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func register(_ adapter: any AppTargetAdapter) {
        let key = Self.normalize(adapter.appID)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if adaptersByID[key] == nil {
            order.append(key)
        }
        adaptersByID[key] = adapter
    }

    public func adapter(for appID: String) -> (any AppTargetAdapter)? {
        let key = Self.normalize(appID)
        lock.lock()
        defer { lock.unlock() }
        return adaptersByID[key]
    }

    public func requireAdapter(for appID: String) throws -> any AppTargetAdapter {
        guard let found = adapter(for: appID) else {
            throw RoutingError("未注册的目标应用：\(appID)")
        }
        return found
    }

    public func contains(_ appID: String) -> Bool {
        adapter(for: appID) != nil
    }

    public var allAdapters: [any AppTargetAdapter] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { adaptersByID[$0] }
    }
}

public final class TargetAppPreferenceStore: @unchecked Sendable {
    public static let defaultAppID = VoiceTarget.defaultAppID
    public static let environmentKey = "BEANBRIDGE_TARGET_APP"
    public static let fileName = "target-app"

    public let supportDirectory: URL
    public let registry: AppTargetRegistry
    private let environmentProvider: @Sendable () -> [String: String]
    private let lock = NSLock()

    public init(
        supportDirectory: URL,
        registry: AppTargetRegistry = .shared,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.supportDirectory = supportDirectory
        self.registry = registry
        self.environmentProvider = environmentProvider
    }

    public var preferenceFileURL: URL {
        supportDirectory.appendingPathComponent(Self.fileName)
    }

    public var isOverriddenByEnvironment: Bool {
        if let raw = environmentProvider()[Self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return true
        }
        return false
    }

    /// Resolve effective target app ID (`BEANBRIDGE_TARGET_APP` > `support/target-app` > `"codex"`), throwing on unknown appID.
    public func resolveAppID() throws -> String {
        if let envRaw = environmentProvider()[Self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envRaw.isEmpty {
            let normalized = AppTargetRegistry.normalize(envRaw)
            guard registry.contains(normalized) else {
                throw RoutingError("不支持的目标应用配置：\(envRaw)")
            }
            return normalized
        }
        return try persistedAppID()
    }

    /// Read persisted `support/target-app` (ignoring environment override), defaulting to `"codex"`.
    public func persistedAppID() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let path = preferenceFileURL
        guard FileManager.default.fileExists(atPath: path.path) else {
            return Self.defaultAppID
        }
        let raw = try String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return Self.defaultAppID
        }
        let normalized = AppTargetRegistry.normalize(raw)
        guard registry.contains(normalized) else {
            throw RoutingError("不支持的目标应用配置：\(raw)")
        }
        return normalized
    }

    /// Non-throwing current appID accessor for UI state; falls back to `"codex"` if misconfigured.
    public func currentAppID() -> String {
        (try? resolveAppID()) ?? Self.defaultAppID
    }

    /// Non-throwing current adapter accessor for UI state.
    public func currentAdapter() -> any AppTargetAdapter {
        let id = currentAppID()
        return registry.adapter(for: id) ?? CodexTargetAdapter()
    }

    /// Persist `appID` to `support/target-app` with 0o700/0o600 atomic write after validating against `registry`.
    @discardableResult
    public func setCurrentAppID(_ appID: String) throws -> any AppTargetAdapter {
        let normalized = AppTargetRegistry.normalize(appID)
        let adapter = try registry.requireAdapter(for: normalized)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
        let path = preferenceFileURL
        try Data((normalized + "\n").utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return adapter
    }
}
