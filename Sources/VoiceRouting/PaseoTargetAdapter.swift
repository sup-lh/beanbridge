import CoreGraphics
import Foundation

public struct PaseoTargetAdapter: AppTargetAdapter {
    public struct ScriptBridgeResponse: Codable, Sendable {
        public let id: String
        public let title: String
        public let appID: String?
    }

    public struct SubmitBridgeResponse: Codable, Sendable {
        public let receipt: String
        public let status: String?
    }

    public struct WorkspaceTabResolveResponse: Codable, Sendable {
        public let kind: String
        public let id: String?
        public let title: String?
        public let appID: String?
    }

    public static let defaultBundleIdentifiers: [String] = [
        "sh.paseo.desktop",
    ]

    public let appID = "paseo"
    public let displayName = "Paseo"
    public let linkPlaceholder = "粘贴 paseo://h/…/agent/…、https://app.paseo.sh/… 或 paseo://agent/… 链接"
    public var bundleIdentifiers: [String] { targetBundleIdentifiers() }

    private let scriptsDirectory: URL?
    private let environmentProvider: @Sendable () -> [String: String]

    public init(
        scriptsDirectory: URL? = nil,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.scriptsDirectory = scriptsDirectory
        self.environmentProvider = environmentProvider
    }

    private func targetBundleIdentifiers() -> [String] {
        let env = environmentProvider()
        let override = env["BEANBRIDGE_PASEO_BUNDLE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return [override]
        }
        return Self.defaultBundleIdentifiers
    }

    @MainActor
    public func needsNewChat() -> Bool {
        CurrentChat.needsNewChat(bundleIdentifiers: targetBundleIdentifiers())
    }

    @MainActor
    public func captureCurrentTarget(copyKeyCode _: CGKeyCode) async throws -> String {
        let outcome = try await CurrentChat.inspectPaseoTarget(
            bundleIdentifiers: targetBundleIdentifiers(),
            appName: displayName
        )
        switch outcome.interpretation {
        case let .agentID(id):
            return id
        case let .workspaceSelectedLabels(_, workspaceID, selectedLabels):
            do {
                if let resolvedID = try await Task.detached(priority: .userInitiated, operation: {
                    try self.resolveWorkspaceTab(workspaceID: workspaceID, selectedLabels: selectedLabels)
                }).value {
                    CurrentChat.persistPaseoDiagnostic(
                        windowSummary: outcome.windowSummary,
                        snapshot: outcome.snapshot,
                        resolution: "workspaceSelectedLabels->\(resolvedID)",
                        error: nil
                    )
                    return resolvedID
                }
                CurrentChat.persistPaseoDiagnostic(
                    windowSummary: outcome.windowSummary,
                    snapshot: outcome.snapshot,
                    resolution: "workspaceSelectedLabels->blankChat",
                    error: "blankChat"
                )
                throw CurrentChatError.noChatLink
            } catch {
                CurrentChat.persistPaseoDiagnostic(
                    windowSummary: outcome.windowSummary,
                    snapshot: outcome.snapshot,
                    resolution: "workspaceSelectedLabels->error",
                    error: error.localizedDescription
                )
                throw error
            }
        case .blankChat:
            throw CurrentChatError.noChatLink
        case let .ambiguous(reason), let .unrecognized(reason):
            throw RoutingError(reason)
        }
    }

    public func resolveWorkspaceTab(workspaceID: String, selectedLabels: [String]) throws -> String? {
        let cleanWorkspaceID = try ChatLink.validatePaseoID(workspaceID)
        let labelsData = try JSONSerialization.data(withJSONObject: selectedLabels, options: [])
        let labelsJSON = String(decoding: labelsData, as: UTF8.self)
        let stdout = try runBridge(arguments: [
            "--action", "resolve-workspace-tab",
            "--workspace-id", cleanWorkspaceID,
            "--labels-json", labelsJSON,
        ])
        let decoded: WorkspaceTabResolveResponse
        do {
            decoded = try JSONDecoder().decode(WorkspaceTabResolveResponse.self, from: Data(stdout.utf8))
        } catch {
            throw RoutingError("Paseo 返回了无效的工作区标签解析结果。")
        }
        switch decoded.kind {
        case "agent":
            guard let rawID = decoded.id else {
                throw RoutingError("Paseo 未返回有效的对话 ID。")
            }
            return try ChatLink.validatePaseoID(rawID)
        case "blank":
            return nil
        default:
            throw RoutingError("Paseo 返回了未知的工作区标签类型：\(decoded.kind)")
        }
    }

    public func parseLink(_ raw: String) throws -> String {
        if let parsed = CurrentChat.parsePaseoAgentURL(raw) {
            return parsed.agentID
        }
        throw RoutingError("请使用有效的 Paseo 对话链接（paseo://h/<serverId>/agent/<id>、paseo://agent/<id> 或 https://app.paseo.sh/h/<serverId>/agent/<id>）。")
    }

    public func validate(id: String, supportDirectory _: URL) throws -> VoiceTarget {
        let cleanID = try ChatLink.validatePaseoID(id)
        let stdout = try runBridge(arguments: ["--action", "validate", "--id", cleanID])
        let decoded: ScriptBridgeResponse
        do {
            decoded = try JSONDecoder().decode(ScriptBridgeResponse.self, from: Data(stdout.utf8))
        } catch {
            throw RoutingError("Paseo 返回了无效的校验结果。")
        }
        let validID = try ChatLink.validatePaseoID(decoded.id)
        let cleanTitle = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return VoiceTarget(id: validID, title: cleanTitle.isEmpty ? "Paseo 对话" : cleanTitle, appID: appID)
    }

    public func createNewSession(messageID: UUID, supportDirectory: URL) throws -> VoiceTarget {
        let creationDir = supportDirectory.appendingPathComponent("Creation", isDirectory: true)
        try FileManager.default.createDirectory(at: creationDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: creationDir.path)
        let receiptURL = creationDir.appendingPathComponent("paseo-\(messageID.uuidString).json")

        let stdout = try runBridge(arguments: [
            "--action", "create",
            "--receipt", receiptURL.path,
            "--idempotency-key", messageID.uuidString,
        ])
        let decoded: ScriptBridgeResponse
        do {
            decoded = try JSONDecoder().decode(ScriptBridgeResponse.self, from: Data(stdout.utf8))
        } catch {
            throw RoutingError("Paseo 返回了无效的新建会话结果。")
        }
        let validID = try ChatLink.validatePaseoID(decoded.id)
        let cleanTitle = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return VoiceTarget(id: validID, title: cleanTitle.isEmpty ? "新 Paseo 对话" : cleanTitle, appID: appID)
    }

    public func canonicalLink(for id: String) -> String? {
        guard let cleanID = try? ChatLink.validatePaseoID(id) else {
            return nil
        }
        if let serverID = readLocalServerID() {
            return "paseo://h/\(serverID)/agent/\(cleanID)"
        }
        return "paseo://agent/\(cleanID)"
    }

    public func openSession(_ target: VoiceTarget) throws {
        guard target.appID == appID,
              let link = canonicalLink(for: target.id),
              let url = URL(string: link) else {
            throw RoutingError("无效的 Paseo 对话目标，无法打开。")
        }
        let env = environmentProvider()
        if let openCmd = env["BEANBRIDGE_PASEO_OPEN_CMD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !openCmd.isEmpty {
            _ = try AdapterTools.run(openCmd, [url.absoluteString], environment: env, timeout: 10)
            return
        }
        _ = try AdapterTools.run("/usr/bin/open", [url.absoluteString], environment: env, timeout: 10)
    }

    public func submit(text: String, to target: VoiceTarget, supportDirectory: URL) throws -> String {
        let cleanID = try ChatLink.validatePaseoID(target.id)
        let submissionsDir = supportDirectory.appendingPathComponent("Submissions", isDirectory: true)
        try FileManager.default.createDirectory(at: submissionsDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: submissionsDir.path)
        let receiptURL = submissionsDir.appendingPathComponent("paseo-\(UUID().uuidString).json")

        let stdout = try runBridge(arguments: [
            "--action", "submit",
            "--id", cleanID,
            "--text", text,
            "--receipt", receiptURL.path,
        ])
        if let decoded = try? JSONDecoder().decode(SubmitBridgeResponse.self, from: Data(stdout.utf8)) {
            let trimmed = decoded.receipt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return receiptURL.path
    }

    private func readLocalServerID() -> String? {
        let env = environmentProvider()
        let paseoHomeRaw = (env["BEANBRIDGE_PASEO_HOME"] ?? env["PASEO_HOME"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let paseoHome: URL
        if let paseoHomeRaw, !paseoHomeRaw.isEmpty {
            paseoHome = URL(fileURLWithPath: paseoHomeRaw, isDirectory: true)
        } else {
            paseoHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".paseo", isDirectory: true)
        }
        let serverIDURL = paseoHome.appendingPathComponent("server-id")
        guard let raw = try? String(contentsOf: serverIDURL, encoding: .utf8) else {
            return nil
        }
        return try? ChatLink.validatePaseoServerID(raw)
    }

    private func runBridge(arguments: [String]) throws -> String {
        let env = environmentProvider()
        let python = try AdapterTools.resolvePython(environment: env)
        let scriptURL: URL
        if scriptsDirectory == nil,
           let explicit = env["BEANBRIDGE_PASEO_SCRIPT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            scriptURL = URL(fileURLWithPath: explicit)
        } else {
            scriptURL = AdapterTools.resolveHelperScript(
                "paseo-chat.py",
                scriptsDirectory: scriptsDirectory,
                environment: env
            )
        }
        return try AdapterTools.run(
            python,
            [scriptURL.path] + arguments,
            environment: env,
            timeout: 30
        )
    }
}
