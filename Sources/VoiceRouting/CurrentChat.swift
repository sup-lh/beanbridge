import AppKit
import ApplicationServices

/// All UI and pasteboard access stays on the main actor. Does not activate or navigate Codex.
@MainActor public enum CurrentChat {
    private static var capturing = false
    private struct Focus {
        let pid: pid_t
        let window: AXUIElement
        let title: String
    }
    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private static func focus(bundleID: String) throws -> Focus {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID else {
            throw RoutingError("请将目标 Codex 对话置于前台；本次不会使用旧目标。")
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = value(ax, kAXWindowsAttribute) as? [AXUIElement], windows.count == 1,
              let raw = value(ax, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw RoutingError("没有唯一的 Codex 窗口，请关闭额外窗口或在待发箱指定链接。")
        }
        let window = unsafeBitCast(raw, to: AXUIElement.self)
        guard value(window, kAXModalAttribute) as? Bool != true else {
            throw RoutingError("Codex 正在显示对话框，请先关闭它。")
        }
        return Focus(pid: app.processIdentifier, window: window,
                     title: value(window, kAXTitleAttribute) as? String ?? "")
    }
    private static func check(_ original: Focus, bundleID: String) throws {
        let current = try focus(bundleID: bundleID)
        guard current.pid == original.pid, CFEqual(current.window, original.window), current.title == original.title else {
            throw RoutingError("读取目标时窗口发生变化，本次文字将保留到待发箱。")
        }
    }
    /// A background or minimized window is not a closed app. Unknown AX state fails closed.
    public static func needsNewChat(bundleID: String = "com.openai.codex") -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return true }
        guard apps.count == 1, isTrusted else { return false }
        let ax = AXUIElementCreateApplication(apps[0].processIdentifier)
        guard let windows = value(ax, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        return windows.isEmpty
    }
    public static var isTrusted: Bool { AXIsProcessTrusted() }
    public static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    public static func capture(bundleID: String = "com.openai.codex", keyCode: CGKeyCode = 37) async throws -> String {
        guard !capturing else { throw RoutingError("已有目标检测正在进行，请稍后再试。") }
        capturing = true
        defer { capturing = false }
        guard isTrusted else { throw RoutingError("请在系统设置 → 隐私与安全性 → 辅助功能中允许安克豆按键语音。") }
        let initial = try focus(bundleID: bundleID)
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var ownedCount: Int?
        var ownedText: String?
        defer {
            // Do not overwrite anything copied by the user after our last successful capture.
            if let ownedCount, board.changeCount == ownedCount,
               board.string(forType: .string) == ownedText {
                board.clearContents()
                let items = saved.map { entries -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in entries { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        func copy() async throws -> String {
            try check(initial, bundleID: bundleID)
            let before = board.changeCount
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                throw RoutingError("无法生成复制链接快捷键。")
            }
            down.flags = [.maskCommand, .maskAlternate]; up.flags = [.maskCommand, .maskAlternate]
            down.postToPid(initial.pid); up.postToPid(initial.pid)
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 30_000_000)
                try check(initial, bundleID: bundleID)
                if board.changeCount != before {
                    let count = board.changeCount
                    guard let text = board.string(forType: .string) else {
                        throw RoutingError("复制命令没有返回聊天链接。")
                    }
                    let id = try ChatLink.threadID(text)
                    guard board.changeCount == count else { throw RoutingError("剪贴板同时发生变化，请重试。") }
                    ownedCount = count; ownedText = text
                    return id
                }
            }
            throw RoutingError("未取得新的聊天链接，请确认正在显示已有对话，且 ⌘⌥L 未被改键。")
        }
        let first = try await copy()
        try await Task.sleep(nanoseconds: 100_000_000)
        // A second independent copy detects same-window chat switches during capture.
        guard board.changeCount == ownedCount else { throw RoutingError("剪贴板被其他操作修改，请重试。") }
        let second = try await copy()
        guard first == second else { throw RoutingError("读取时切换了对话，本次不会自动发送。") }
        try check(initial, bundleID: bundleID)
        return first
    }
}
