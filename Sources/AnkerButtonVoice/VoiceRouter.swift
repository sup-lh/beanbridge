import AppKit
import Foundation
import VoiceRouting

struct RouteResult: Sendable {
    let appID: String
    let target: VoiceTarget?
    let reason: String?
    var createNew: Bool = false

    init(
        appID: String = VoiceTarget.defaultAppID,
        target: VoiceTarget?,
        reason: String?,
        createNew: Bool = false
    ) {
        let normalized = AppTargetRegistry.normalize(appID)
        self.appID = normalized.isEmpty ? (target?.appID ?? VoiceTarget.defaultAppID) : normalized
        self.target = target
        self.reason = reason
        self.createNew = createNew
    }

    func applyingUserMark(_ marked: Bool) -> RouteResult {
        guard marked else { return self }
        return RouteResult(
            appID: appID,
            target: nil,
            reason: "录音中轻敲已确认，发往独立新会话",
            createNew: true
        )
    }
}

private struct CreationReceipt: Decodable {
    let target: VoiceTarget?
}

private struct PanelRef: @unchecked Sendable {
    let value: VoicePanel?
}

struct ProbeResult: Encodable {
    let appID: String?
    let target: VoiceTarget?
    let error: String?

    init(target: VoiceTarget?, error: String?, appID: String? = nil) {
        self.appID = appID ?? target?.appID
        self.target = target
        self.error = error
    }
}

final class VoiceRouter: @unchecked Sendable {
    let supportDirectory: URL
    let registry: AppTargetRegistry
    let preferences: TargetAppPreferenceStore
    let store: PendingStore
    var onTargetAppChanged: ((any AppTargetAdapter) -> Void)?

    private let work = DispatchQueue(label: "beanbridge.routing.delivery")

    init(
        supportDirectory: URL = support,
        registry: AppTargetRegistry = .shared,
        preferences: TargetAppPreferenceStore? = nil
    ) {
        self.supportDirectory = supportDirectory
        self.registry = registry
        self.preferences = preferences ?? TargetAppPreferenceStore(
            supportDirectory: supportDirectory,
            registry: registry
        )
        self.store = PendingStore(
            directory: supportDirectory.appendingPathComponent("Pending", isDirectory: true)
        )
    }

    // MARK: - Target App Selection (for Menu Bar & Floating Panel UI)

    var availableAdapters: [any AppTargetAdapter] {
        registry.allAdapters
    }

    var isTargetAppLockedByEnvironment: Bool {
        preferences.isOverriddenByEnvironment
    }

    func adapter(for appID: String) -> (any AppTargetAdapter)? {
        registry.adapter(for: appID)
    }

    func defaultAppID() -> String {
        preferences.currentAppID()
    }

    func defaultAdapter() -> any AppTargetAdapter {
        preferences.currentAdapter()
    }

    @discardableResult
    func setDefaultAppID(_ appID: String) throws -> any AppTargetAdapter {
        let selected = try preferences.setCurrentAppID(appID)
        onTargetAppChanged?(selected)
        return selected
    }

    @discardableResult
    func switchTargetApp(to appID: String) throws -> any AppTargetAdapter {
        try setDefaultAppID(appID)
    }

    private func displayName(for appID: String) -> String {
        registry.adapter(for: appID)?.displayName ?? appID
    }

    private func fixedTargetID(for adapter: any AppTargetAdapter) throws -> String {
        if adapter.appID == "codex" {
            let raw = try String(
                contentsOf: supportDirectory.appendingPathComponent("target-thread"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let uuid = UUID(uuidString: raw) else {
                throw RoutingError("固定目标配置无效。")
            }
            return uuid.uuidString.lowercased()
        }
        let appTargetPath = supportDirectory.appendingPathComponent("target-" + adapter.appID)
        let raw = try String(contentsOf: appTargetPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw RoutingError("固定目标配置无效。")
        }
        if raw.contains("://") {
            return try adapter.parseLink(raw)
        }
        return raw
    }

    // MARK: - Context Resolution

    func resolve(forceCurrent: Bool = false, appID: String? = nil) async -> RouteResult {
        var lockedAppID = appID.map(AppTargetRegistry.normalize).flatMap { $0.isEmpty ? nil : $0 }
            ?? preferences.currentAppID()
        var lockedDisplayName = displayName(for: lockedAppID)
        do {
            let resolvedAppID: String
            if let explicit = appID?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
                resolvedAppID = AppTargetRegistry.normalize(explicit)
            } else {
                resolvedAppID = try preferences.resolveAppID()
            }
            lockedAppID = resolvedAppID
            let adapter = try registry.requireAdapter(for: resolvedAppID)
            lockedDisplayName = adapter.displayName

            let env = ProcessInfo.processInfo.environment
            let mode = env["BEANBRIDGE_ROUTING"] ?? (
                (try? String(contentsOf: supportDirectory.appendingPathComponent("routing-mode"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "current"
            )
            let id: String
            if !forceCurrent && mode == "fixed" {
                id = try fixedTargetID(for: adapter)
            } else {
                guard forceCurrent || mode == "current" else {
                    throw RoutingError("routing-mode 只支持 current 或 fixed。")
                }
                let needsNew = await adapter.needsNewChat()
                if !forceCurrent && needsNew {
                    return RouteResult(
                        appID: adapter.appID,
                        target: nil,
                        reason: "录音结束后创建独立\(adapter.displayName)新会话",
                        createNew: true
                    )
                }
                let keyText = env["BEANBRIDGE_COPY_KEYCODE"] ?? "37"
                guard let key = UInt16(keyText), key <= 127 else {
                    throw RoutingError("复制链接的键码配置无效。")
                }
                id = try await adapter.captureCurrentTarget(copyKeyCode: key)
            }
            let supportDir = supportDirectory
            let target = try await Task.detached {
                try adapter.validate(id: id, supportDirectory: supportDir)
            }.value
            return RouteResult(appID: adapter.appID, target: target, reason: nil, createNew: false)
        } catch CurrentChatError.noChatLink {
            return RouteResult(
                appID: lockedAppID,
                target: nil,
                reason: "未取得聊天链接，录音结束后新建独立\(lockedDisplayName)会话",
                createNew: !forceCurrent
            )
        } catch {
            return RouteResult(appID: lockedAppID, target: nil, reason: String(describing: error), createNew: false)
        }
    }

    // MARK: - Unified Delivery & External Text Forwarding (for Inspiration Inbox & Voice)

    @discardableResult
    func routeAndDeliver(
        text: String,
        appID: String? = nil,
        createNewSession: Bool = false,
        panel: VoicePanel? = nil
    ) async throws -> PendingMessage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RoutingError("待发送文字为空。")
        }
        let destination: RouteResult
        if createNewSession {
            let resolvedAppID: String
            if let explicit = appID?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
                resolvedAppID = AppTargetRegistry.normalize(explicit)
                _ = try registry.requireAdapter(for: resolvedAppID)
            } else {
                resolvedAppID = try preferences.resolveAppID()
            }
            destination = RouteResult(
                appID: resolvedAppID,
                target: nil,
                reason: "转发至独立新会话",
                createNew: true
            )
        } else {
            destination = await resolve(forceCurrent: false, appID: appID)
        }
        let panelRef = PanelRef(value: panel)
        return try await withCheckedThrowingContinuation { continuation in
            work.async {
                do {
                    let result = try self.deliver(text: text, destination: destination, panel: panelRef.value)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func forwardExternalText(
        _ text: String,
        appID: String? = nil,
        createNewSession: Bool = false,
        panel: VoicePanel? = nil,
        completion: (@Sendable (Result<PendingMessage, Error>) -> Void)? = nil
    ) {
        let panelRef = PanelRef(value: panel)
        Task {
            do {
                let message = try await self.routeAndDeliver(
                    text: text,
                    appID: appID,
                    createNewSession: createNewSession,
                    panel: panelRef.value
                )
                completion?(.success(message))
            } catch {
                completion?(.failure(error))
            }
        }
    }

    @discardableResult
    func deliver(
        text: String,
        toLink rawLink: String,
        panel: VoicePanel? = nil
    ) throws -> PendingMessage {
        let parsed = try ChatLink.parse(rawLink, defaultAppID: defaultAppID())
        let adapter = try registry.requireAdapter(for: parsed.appID)
        let message = PendingMessage(
            text: text,
            target: nil,
            note: "指定链接投递",
            appID: adapter.appID
        )
        try store.save(message)
        let validated = try adapter.validate(id: parsed.id, supportDirectory: supportDirectory)
        return try submit(message, target: validated, panel: panel)
    }

    @discardableResult
    func deliver(
        text: String,
        destination: RouteResult,
        panel: VoicePanel? = nil
    ) throws -> PendingMessage {
        let effectiveAppID = destination.target?.appID ?? destination.appID
        let message = PendingMessage(
            text: text,
            target: destination.target,
            note: destination.reason ?? "等待投递",
            appID: effectiveAppID
        )
        // A failed save prevents submission: recovery must exist before any external side effect.
        try store.save(message)
        if destination.createNew {
            return try createAndSubmit(message, panel: panel)
        }
        guard let target = destination.target else {
            panel?.setTarget("待选择（\(displayName(for: effectiveAppID))）")
            panel?.show("文字已保存到待发箱", destination.reason ?? "点击待发箱，为这条文字指定聊天链接。")
            return message
        }
        return try submit(message, target: target, panel: panel)
    }

    @discardableResult
    private func createAndSubmit(
        _ original: PendingMessage,
        panel: VoicePanel? = nil
    ) throws -> PendingMessage {
        let adapter = try registry.requireAdapter(for: original.appID)
        var message = try store.beginCreation(original.id)
        panel?.setTarget("\(adapter.displayName) · 独立新会话")
        panel?.show("正在创建新会话…", "最终文字已保存，创建成功后打开\(adapter.displayName)并发送。")
        let receipt = supportDirectory.appendingPathComponent("Creation/" + message.id.uuidString + ".json")
        do {
            let created = try adapter.createNewSession(
                messageID: message.id,
                supportDirectory: supportDirectory
            )
            let target = VoiceTarget(id: created.id, title: created.title, appID: adapter.appID)
            message.target = target
            message.appID = adapter.appID
            message.state = .pending
            message.note = "新会话已创建，等待打开与投递"
            try store.save(message)
            try adapter.openSession(target)
            return try submit(message, target: target, panel: panel)
        } catch {
            // Acknowledged creations are recoverable even if the helper dies before stdout.
            if message.target == nil,
               let data = try? Data(contentsOf: receipt),
               let record = try? JSONDecoder().decode(CreationReceipt.self, from: data),
               let recovered = record.target {
                let target = VoiceTarget(id: recovered.id, title: recovered.title, appID: adapter.appID)
                message.target = target
                message.appID = adapter.appID
                message.state = .pending
            }
            if message.state == .creating || message.state == .pending {
                // Do not overwrite submit()'s uncertain/queued state with this older snapshot.
                if let saved = try? store.messages().first(where: { $0.id == message.id }),
                   saved.state == .creating || saved.state == .pending {
                    message.note = "新会话流程未完成：\(error)。请在待发箱核对。"
                    try? store.save(message)
                }
            }
            throw error
        }
    }

    @discardableResult
    private func submit(
        _ message: PendingMessage,
        target: VoiceTarget,
        panel: VoicePanel? = nil
    ) throws -> PendingMessage {
        // Check accessibility of the pinned ID again, never re-resolve the current UI here.
        let adapter = try registry.requireAdapter(for: target.appID)
        let checked = try adapter.validate(id: target.id, supportDirectory: supportDirectory)
        var claimed = try store.beginSubmission(message.id, target: checked)
        panel?.setTarget("\(adapter.displayName) · \(checked.title)")
        panel?.show("正在放入\(adapter.displayName)会话队列…", message.text)
        do {
            let receipt = try adapter.submit(
                text: message.text,
                to: checked,
                supportDirectory: supportDirectory
            )
            claimed.state = .queued
            let trimmed = receipt.trimmingCharacters(in: .whitespacesAndNewlines)
            claimed.note = trimmed.isEmpty ? "已发送到\(adapter.displayName)" : trimmed
            try store.save(claimed)
            panel?.show("已发送到 \(adapter.displayName)", message.text)
            return claimed
        } catch {
            claimed.state = .uncertain
            claimed.note = "投递结果未确认：\(error)。请到目标\(adapter.displayName)对话核对，不要直接重发。"
            try? store.save(claimed)
            throw error
        }
    }

    // MARK: - Pending Inbox UI

    func showPending(panel: VoicePanel) {
        DispatchQueue.main.async { self.presentPending(panel: panel) }
    }

    private func presentPending(panel: VoicePanel) {
        do {
            let messages = try store.messages().filter { $0.state != .queued }
            guard !messages.isEmpty else {
                panel.show("待发箱为空", "没有需要处理的文字。")
                return
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            let chooser = NSAlert()
            chooser.messageText = "选择待处理文字"
            chooser.informativeText = "未确认结果的消息只允许复制核对，不会再次自动投递。"
            let list = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 30))
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm:ss"
            for message in messages {
                let state = message.state == .pending ? "待发" : "需核对"
                let appLabel = displayName(for: message.appID)
                list.addItem(
                    withTitle: "\(formatter.string(from: message.createdAt)) [\(appLabel)·\(state)] \(message.text.prefix(34))"
                )
            }
            chooser.accessoryView = list
            chooser.addButton(withTitle: "查看")
            chooser.addButton(withTitle: "取消")
            guard chooser.runModal() == .alertFirstButtonReturn else { return }
            let message = messages[list.indexOfSelectedItem]
            let messageAdapter = registry.adapter(for: message.appID)
            let appLabel = messageAdapter?.displayName ?? message.appID

            let alert = NSAlert()
            alert.messageText = message.state == .pending ? "指定本条消息的目标（当前：\(appLabel)）" : "请先核对投递结果（\(appLabel)）"
            alert.informativeText = message.text + "\n\n" + message.note
            if message.state == .pending {
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
                input.placeholderString = messageAdapter?.linkPlaceholder
                    ?? "粘贴 codex://threads/…、doubao://chat/… 或 paseo://h/…/agent/… 对话链接"
                if let target = message.target,
                   let targetAdapter = registry.adapter(for: target.appID),
                   let link = targetAdapter.canonicalLink(for: target.id) {
                    input.stringValue = link
                } else if let target = message.target {
                    switch target.appID {
                    case "doubao":
                        input.stringValue = "doubao://chat/" + target.id
                    case "paseo":
                        input.stringValue = "paseo://agent/" + target.id
                    default:
                        input.stringValue = "codex://threads/" + target.id
                    }
                }
                alert.accessoryView = input
                alert.addButton(withTitle: "发送到此链接")
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "复制文字")
                if message.target == nil {
                    alert.addButton(withTitle: "新建\(appLabel)独立会话并发送")
                }
                let response = alert.runModal()
                if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
                    self.work.async {
                        do { try self.createAndSubmit(message, panel: panel) }
                        catch { panel.show("文字仍在待发箱", String(describing: error)) }
                    }
                    return
                }
                if response == .alertThirdButtonReturn { self.copy(message.text); return }
                guard response == .alertFirstButtonReturn else { return }
                let parsed = try ChatLink.parse(input.stringValue, defaultAppID: message.appID)
                let selectedAdapter = try registry.requireAdapter(for: parsed.appID)
                let supportDir = supportDirectory
                work.async {
                    do {
                        let target = try selectedAdapter.validate(id: parsed.id, supportDirectory: supportDir)
                        try self.submit(message, target: target, panel: panel)
                    } catch { panel.show("文字仍在待发箱", String(describing: error)) }
                }
            } else {
                alert.addButton(withTitle: "复制文字")
                alert.addButton(withTitle: "关闭")
                if alert.runModal() == .alertFirstButtonReturn { self.copy(message.text) }
            }
        } catch { panel.show("无法处理待发文字", String(describing: error)) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
