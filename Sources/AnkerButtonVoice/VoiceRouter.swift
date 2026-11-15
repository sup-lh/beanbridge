import AppKit
import Foundation
import VoiceRouting

struct RouteResult: Sendable {
    let target: VoiceTarget?
    let reason: String?
    var createNew: Bool = false

    func applyingUserMark(_ marked: Bool) -> RouteResult {
        guard marked else { return self }
        return RouteResult(target: nil, reason: "录音中轻敲已确认，发往独立新会话", createNew: true)
    }
}
private struct CreationReceipt: Decodable {
    let target: VoiceTarget?
}

struct ProbeResult: Encodable {
    let target: VoiceTarget?
    let error: String?
}

final class VoiceRouter: @unchecked Sendable {
    let store = PendingStore(directory: support.appendingPathComponent("Pending", isDirectory: true))
    private let work = DispatchQueue(label: "beanbridge.routing.delivery")

    private func helper(_ name: String) -> URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent(name)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/" + name)
        return bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? source
    }

    private func validate(_ id: String) throws -> VoiceTarget {
        let helper = helper("set-target.py")
        let result = try runTool("/usr/bin/python3", [helper.path, "--thread-id", id, "--json"], timeout: 50)
        let target = try JSONDecoder().decode(VoiceTarget.self, from: Data(result.utf8))
        guard target.id == id else { throw RoutingError("会话校验返回了不同的 ID。") }
        return target
    }

    func resolve(forceCurrent: Bool = false) async -> RouteResult {
        do {
            let env = ProcessInfo.processInfo.environment
            let mode = env["BEANBRIDGE_ROUTING"] ?? ((try? String(contentsOf: support.appendingPathComponent("routing-mode"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "current")
            let id: String
            if !forceCurrent && mode == "fixed" {
                let raw = try String(contentsOf: support.appendingPathComponent("target-thread"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let uuid = UUID(uuidString: raw) else { throw RoutingError("固定目标配置无效。") }
                id = uuid.uuidString.lowercased()
            } else {
                guard forceCurrent || mode == "current" else { throw RoutingError("routing-mode 只支持 current 或 fixed。") }
                let needsNew = await CurrentChat.needsNewChat()
                if !forceCurrent && needsNew {
                    return RouteResult(target: nil, reason: "录音结束后创建独立新会话", createNew: true)
                }
                let keyText = env["BEANBRIDGE_COPY_KEYCODE"] ?? "37"
                guard let key = UInt16(keyText), key <= 127 else { throw RoutingError("复制链接的键码配置无效。") }
                id = try await CurrentChat.capture(keyCode: key)
            }
            let target = try await Task.detached { try self.validate(id) }.value
            return RouteResult(target: target, reason: nil)
        } catch CurrentChatError.noChatLink {
            return RouteResult(target: nil, reason: "未取得聊天链接，录音结束后新建独立会话", createNew: !forceCurrent)
        } catch {
            return RouteResult(target: nil, reason: String(describing: error))
        }
    }

    func deliver(text: String, destination: RouteResult, panel: VoicePanel) throws {
        let message = PendingMessage(text: text, target: destination.target, note: destination.reason ?? "等待投递")
        // A failed save prevents submission: recovery must exist before any external side effect.
        try store.save(message)
        if destination.createNew {
            try createAndSubmit(message, panel: panel)
            return
        }
        guard let target = destination.target else {
            panel.setTarget("待选择")
            panel.show("文字已保存到待发箱", destination.reason ?? "点击待发箱，为这条文字指定聊天链接。")
            return
        }
        try submit(message, target: target, panel: panel)
    }

    private func createAndSubmit(_ original: PendingMessage, panel: VoicePanel) throws {
        var message = original
        message = try store.beginCreation(message.id)
        panel.setTarget("独立新会话")
        panel.show("正在创建新会话…", "最终文字已保存，创建成功后打开 Codex 并发送。")
        let receipt = support.appendingPathComponent("Creation/" + message.id.uuidString + ".json")
        let directory = support.appendingPathComponent("Chats/" + message.id.uuidString, isDirectory: true)
        do {
            let output = try runTool("/usr/bin/python3", [helper("create-chat.py").path,
                "--codex", codex, "--directory", directory.path, "--receipt", receipt.path], timeout: 70)
            let target = try JSONDecoder().decode(VoiceTarget.self, from: Data(output.utf8))
            guard UUID(uuidString: target.id) != nil else { throw RoutingError("创建回执没有有效的会话 ID。") }
            message.target = target; message.state = .pending; message.note = "新会话已创建，等待打开与投递"
            try store.save(message)
            // A deep link launches the app if absent and loads this exact persisted thread.
            _ = try runTool("/usr/bin/open", ["codex://threads/" + target.id], timeout: 10)
            try submit(message, target: target, panel: panel)
        } catch {
            // Acknowledged creations are recoverable even if the helper dies before stdout.
            if message.target == nil,
               let data = try? Data(contentsOf: receipt),
               let record = try? JSONDecoder().decode(CreationReceipt.self, from: data),
               let target = record.target {
                message.target = target; message.state = .pending
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

    private func submit(_ message: PendingMessage, target: VoiceTarget, panel: VoicePanel) throws {
        // Check accessibility of the pinned ID again, never re-resolve the current UI here.
        let checked = try validate(target.id)
        var claimed = try store.beginSubmission(message.id, target: checked)
        panel.setTarget(checked.title)
        panel.show("正在放入会话队列…", message.text)
        do {
            let receipt = try runTool(codex, ["queue", "--thread", checked.id, "--message", message.text], timeout: 30)
            claimed.state = .queued
            claimed.note = receipt.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.save(claimed)
            panel.show("已放入 Codex 队列", message.text)
        } catch {
            claimed.state = .uncertain
            claimed.note = "投递结果未确认：\(error)。请到目标对话核对，不要直接重发。"
            try? store.save(claimed)
            throw error
        }
    }

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
            let list = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 30))
            let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
            for message in messages {
                let state = message.state == .pending ? "待发" : "需核对"
                list.addItem(withTitle: "\(formatter.string(from: message.createdAt)) [\(state)] \(message.text.prefix(36))")
            }
            chooser.accessoryView = list
            chooser.addButton(withTitle: "查看")
            chooser.addButton(withTitle: "取消")
            guard chooser.runModal() == .alertFirstButtonReturn else { return }
            let message = messages[list.indexOfSelectedItem]
            let alert = NSAlert()
            alert.messageText = message.state == .pending ? "指定本条消息的目标" : "请先核对投递结果"
            alert.informativeText = message.text + "\n\n" + message.note
            if message.state == .pending {
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
                input.placeholderString = "粘贴 codex://threads/… 聊天链接"
                if let target = message.target { input.stringValue = "codex://threads/" + target.id }
                alert.accessoryView = input
                alert.addButton(withTitle: "发送到此链接")
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "复制文字")
                if message.target == nil { alert.addButton(withTitle: "新建独立会话并发送") }
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
                let id = try ChatLink.threadID(input.stringValue)
                work.async {
                    do {
                        let target = try self.validate(id)
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
