import Foundation

public struct RoutingError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct VoiceTarget: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public enum ChatLink {
    /// Accept only the local chat route. Remote/chatgpt/query routes have different semantics.
    public static func threadID(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: text), url.scheme == "codex", url.host == "threads",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.path.count == 37, url.path.first == "/",
              let uuid = UUID(uuidString: String(url.path.dropFirst())) else {
            throw RoutingError("请使用 ⌘⌥L 复制的本地 Codex 聊天链接。")
        }
        return uuid.uuidString.lowercased()
    }
}

public struct PendingMessage: Codable, Sendable {
    public enum State: String, Codable, Sendable { case pending, creating, submitting, queued, uncertain }
    public let id: UUID
    public let createdAt: Date
    public let text: String
    public var target: VoiceTarget?
    public var state: State
    public var note: String
    public init(text: String, target: VoiceTarget?, note: String) {
        id = UUID(); createdAt = Date(); self.text = text; self.target = target
        state = .pending; self.note = note
    }
}

/// Persist before submitting. An interrupted submission is never silently retried.
public final class PendingStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }
    private func saveUnlocked(_ message: PendingMessage) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent(message.id.uuidString + ".json")
        // Atomic replacement inherits a private directory; file protection remains explicit.
        try JSONEncoder().encode(message).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public func save(_ message: PendingMessage) throws {
        lock.lock(); defer { lock.unlock() }; try saveUnlocked(message)
    }
    public func messages() throws -> [PendingMessage] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(PendingMessage.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }
    public func beginCreation(_ id: UUID) throws -> PendingMessage {
        lock.lock(); defer { lock.unlock() }
        let path = directory.appendingPathComponent(id.uuidString + ".json")
        var message = try JSONDecoder().decode(PendingMessage.self, from: Data(contentsOf: path))
        guard message.state == .pending, message.target == nil else {
            throw RoutingError("此消息已经指定目标或尝试创建，不会重复建聊。")
        }
        message.state = .creating
        message.note = "正在创建独立会话；若中断，请核对 Creation 目录的创建回执。"
        try saveUnlocked(message)
        return message
    }
    public func beginSubmission(_ id: UUID, target: VoiceTarget) throws -> PendingMessage {
        lock.lock(); defer { lock.unlock() }
        let path = directory.appendingPathComponent(id.uuidString + ".json")
        var message = try JSONDecoder().decode(PendingMessage.self, from: Data(contentsOf: path))
        guard message.state == .pending else {
            throw RoutingError("这条消息已尝试投递，请先到目标对话核对；不会自动重发。")
        }
        message.target = target; message.state = .submitting; message.note = "正在投递；中断时需人工核对"
        try saveUnlocked(message)
        return message
    }
}
