import AppKit
import ApplicationServices

public enum CurrentChatError: Error, CustomStringConvertible, Equatable, Sendable {
    case noChatLink
    public var description: String {
        "未取得聊天链接。新建空白页尚无对话 ID；录音结束后会自动新建独立会话。已有对话请确认 ⌘⌥L 可用。"
    }
}

public struct DoubaoWindowDiag: Codable, Sendable {
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let document: String?
    public let modal: Bool?
    public let minimized: Bool?
    public let width: Double?
    public let height: Double?
}

public struct DoubaoWebAreaDiag: Codable, Sendable {
    public let title: String?
    public let url: String?
    public let document: String?
}

public struct DoubaoInputDiag: Codable, Sendable {
    public let role: String?
    public let subrole: String?
    public let roleDescription: String?
    public let title: String?
    public let placeholder: String?
    public let description: String?
    public let domID: String?
    public let editable: Bool?
    public let focused: Bool?
    public let valueSettable: Bool
    public let valueLength: Int?
    public let urlPreview: String?
}

public struct DoubaoNodeDiag: Codable, Sendable {
    public let role: String?
    public let subrole: String?
    public let roleDescription: String?
    public let title: String?
    public let selected: Bool?
}

public struct DoubaoButtonDiag: Codable, Sendable {
    public let title: String?
    public let description: String?
    public let enabled: Bool?
}

public struct DoubaoAXDiagnostics: Codable, Sendable {
    public let timestamp: String
    public let trusted: Bool
    public let frontmostBundleID: String?
    public let frontmostPID: Int32?
    public let windowCount: Int
    public let windows: [DoubaoWindowDiag]
    public let enhancedUISet: Bool
    public let focusedElementRole: String?
    public let focusedElementSubrole: String?
    public let focusedElementTitle: String?
    public let focusedElementPlaceholder: String?
    public let focusedElementValueSettable: Bool?
    public let webAreas: [DoubaoWebAreaDiag]
    public let inputs: [DoubaoInputDiag]
    public let headingsAndSelected: [DoubaoNodeDiag]
    public let buttons: [DoubaoButtonDiag]
    public let visitedNodeCount: Int
    public let resolvedCandidateURL: String?
    public let resolvedID: String?
    public let error: String?
}

public enum ObservedDoubaoURLMatch: Equatable, Sendable {
    case chatID(String)
    case blankChat
    case unrecognized
}

public struct DoubaoCaptureOutcome: Sendable {
    public let chatID: String?
    public let title: String?
    public let isBlankChat: Bool
    public let hasWebArea: Bool
    public let diagnostics: DoubaoAXDiagnostics
}

/// All UI and pasteboard access stays on the main actor. Does not activate or navigate target apps.
@MainActor public enum CurrentChat {
    private static var capturing = false

    private struct Focus {
        let pid: pid_t
        let bundleID: String
        let window: AXUIElement
        let title: String
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func uniqueBundleIDs(_ bundleIdentifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in bundleIdentifiers {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    nonisolated public static func isAuxiliaryWindowMetadata(
        subrole: String?,
        size: CGSize?,
        isModal: Bool?
    ) -> Bool {
        if isModal == true {
            return false
        }
        if let size, size.width < 160 || size.height < 120 {
            return true
        }
        if let subrole, !subrole.isEmpty, subrole != (kAXStandardWindowSubrole as String) {
            return true
        }
        return false
    }

    private static func filterConversationWindows(_ rawWindows: [AXUIElement]) -> (hasModal: Bool, primary: [AXUIElement]) {
        var hasModal = false
        var primary: [AXUIElement] = []
        for win in rawWindows {
            let isModal = boolValue(win, kAXModalAttribute)
            if isModal == true {
                hasModal = true
            }
            if !isAuxiliaryWindowMetadata(
                subrole: stringValue(win, kAXSubroleAttribute),
                size: sizeValue(win),
                isModal: isModal
            ) {
                primary.append(win)
            }
        }
        return (hasModal, primary)
    }

    private static func resolveSingleConversationWindow(in axApp: AXUIElement, appName: String) throws -> AXUIElement {
        guard let rawWindows = value(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
            throw RoutingError("没有唯一的 \(appName) 窗口，请关闭额外窗口或在待发箱指定链接。")
        }
        let filtered = filterConversationWindows(rawWindows)
        if filtered.hasModal {
            throw RoutingError("\(appName) 正在显示对话框，请先关闭它。")
        }
        guard filtered.primary.count == 1, let singleWindow = filtered.primary.first else {
            throw RoutingError("没有唯一的 \(appName) 窗口，请关闭额外窗口或在待发箱指定链接。")
        }
        if let focusedRaw = value(axApp, kAXFocusedWindowAttribute),
           CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() {
            let focusedWin = unsafeBitCast(focusedRaw, to: AXUIElement.self)
            if boolValue(focusedWin, kAXModalAttribute) == true {
                throw RoutingError("\(appName) 正在显示对话框，请先关闭它。")
            }
            if !CFEqual(focusedWin, singleWindow) {
                let focusedIsAux = isAuxiliaryWindowMetadata(
                    subrole: stringValue(focusedWin, kAXSubroleAttribute),
                    size: sizeValue(focusedWin),
                    isModal: false
                )
                guard focusedIsAux && boolValue(singleWindow, kAXMainAttribute) == true else {
                    throw RoutingError("没有唯一的 \(appName) 窗口，请关闭额外窗口或在待发箱指定链接。")
                }
            }
        } else {
            guard boolValue(singleWindow, kAXMainAttribute) == true else {
                throw RoutingError("没有唯一的 \(appName) 窗口，请关闭额外窗口或在待发箱指定链接。")
            }
        }
        guard boolValue(singleWindow, kAXModalAttribute) != true else {
            throw RoutingError("\(appName) 正在显示对话框，请先关闭它。")
        }
        return singleWindow
    }

    private static func focus(bundleIdentifiers: [String], appName: String) throws -> Focus {
        let allowed = Set(uniqueBundleIDs(bundleIdentifiers))
        guard !allowed.isEmpty else {
            throw RoutingError("未配置 \(appName) 的应用标识。")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let activeBundleID = app.bundleIdentifier,
              allowed.contains(activeBundleID) else {
            throw RoutingError("请将目标 \(appName) 对话置于前台；本次不会使用旧目标。")
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let window = try resolveSingleConversationWindow(in: ax, appName: appName)
        return Focus(
            pid: app.processIdentifier,
            bundleID: activeBundleID,
            window: window,
            title: value(window, kAXTitleAttribute) as? String ?? ""
        )
    }

    private static func check(_ original: Focus, bundleIdentifiers: [String], appName: String) throws {
        let current = try focus(bundleIdentifiers: bundleIdentifiers, appName: appName)
        guard current.pid == original.pid,
              current.bundleID == original.bundleID,
              CFEqual(current.window, original.window),
              current.title == original.title else {
            throw RoutingError("读取目标时窗口发生变化，本次文字将保留到待发箱。")
        }
    }

    /// A background or minimized window is not a closed app. Unknown AX state fails closed.
    public static func needsNewChat(bundleID: String = "com.openai.codex") -> Bool {
        needsNewChat(bundleIdentifiers: [bundleID])
    }

    private static func runningTargetApps(bundleIdentifiers: [String]) -> [NSRunningApplication] {
        let ids = uniqueBundleIDs(bundleIdentifiers)
        var seenPids = Set<pid_t>()
        var apps: [NSRunningApplication] = []
        for id in ids {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isTerminated {
                if seenPids.insert(app.processIdentifier).inserted {
                    apps.append(app)
                }
            }
        }
        return apps
    }

    /// Multi-bundle variant preserving the exact fail-closed AX check across candidate bundle IDs.
    public static func needsNewChat(bundleIdentifiers: [String]) -> Bool {
        let ids = uniqueBundleIDs(bundleIdentifiers)
        guard !ids.isEmpty else { return false }
        let apps = runningTargetApps(bundleIdentifiers: ids)
        guard !apps.isEmpty else { return true }
        guard apps.count == 1, isTrusted else { return false }
        let ax = AXUIElementCreateApplication(apps[0].processIdentifier)
        guard let windows = value(ax, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        return filterConversationWindows(windows).primary.isEmpty
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    public static func capture(bundleID: String = "com.openai.codex", keyCode: CGKeyCode = 37) async throws -> String {
        let appName = bundleID == "com.openai.codex" ? "Codex" : bundleID
        return try await capture(
            bundleIdentifiers: [bundleID],
            appName: appName,
            keyCode: keyCode,
            parseLink: { raw in
                if bundleID == "com.openai.codex" {
                    return try ChatLink.threadID(raw)
                }
                return try ChatLink.parse(raw).id
            }
        )
    }

    public static func capture(
        bundleIdentifiers: [String],
        appName: String = "目标应用",
        keyCode: CGKeyCode = 37,
        parseLink: ((String) throws -> String)? = nil
    ) async throws -> String {
        guard !capturing else { throw RoutingError("已有目标检测正在进行，请稍后再试。") }
        capturing = true
        defer { capturing = false }
        guard isTrusted else { throw RoutingError("请在系统设置 → 隐私与安全性 → 辅助功能中允许安克豆按键语音。") }
        let ids = uniqueBundleIDs(bundleIdentifiers)
        let initial = try focus(bundleIdentifiers: ids, appName: appName)
        let parser: (String) throws -> String = parseLink ?? { raw in
            if ids == ["com.openai.codex"] {
                return try ChatLink.threadID(raw)
            }
            return try ChatLink.parse(raw).id
        }
        let board = NSPasteboard.general
        let saved = snapshotPasteboard(board)
        var ownedCount: Int?
        var ownedText: String?
        defer {
            restorePasteboard(board, saved: saved, ownedCount: ownedCount, ownedText: ownedText)
        }
        func copy() async throws -> String {
            try check(initial, bundleIdentifiers: ids, appName: appName)
            let before = board.changeCount
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                throw RoutingError("无法生成复制链接快捷键。")
            }
            down.flags = [.maskCommand, .maskAlternate]
            up.flags = [.maskCommand, .maskAlternate]
            down.postToPid(initial.pid)
            up.postToPid(initial.pid)
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 30_000_000)
                try check(initial, bundleIdentifiers: ids, appName: appName)
                if board.changeCount != before {
                    let count = board.changeCount
                    guard let text = board.string(forType: .string) else {
                        throw RoutingError("复制命令没有返回聊天链接。")
                    }
                    do {
                        let id = try parser(text)
                        guard board.changeCount == count else { throw RoutingError("剪贴板同时发生变化，请重试。") }
                        ownedCount = count
                        ownedText = text
                        return id
                    } catch let error as CurrentChatError {
                        if board.changeCount == count {
                            ownedCount = count
                            ownedText = text
                        }
                        throw error
                    }
                }
            }
            throw CurrentChatError.noChatLink
        }
        let first = try await copy()
        try await Task.sleep(nanoseconds: 100_000_000)
        // A second independent copy detects same-window chat switches during capture.
        guard board.changeCount == ownedCount else { throw RoutingError("剪贴板被其他操作修改，请重试。") }
        let second = try await copy()
        guard first == second else { throw RoutingError("读取时切换了对话，本次不会自动发送。") }
        try check(initial, bundleIdentifiers: ids, appName: appName)
        return first
    }

    private static func stringValue(_ element: AXUIElement, _ name: String) -> String? {
        guard let raw = value(element, name) else { return nil }
        if let str = raw as? String { return str }
        if let url = raw as? URL { return url.absoluteString }
        if CFGetTypeID(raw) == CFURLGetTypeID() {
            return (unsafeBitCast(raw, to: CFURL.self) as URL).absoluteString
        }
        return nil
    }

    private static func boolValue(_ element: AXUIElement, _ name: String) -> Bool? {
        value(element, name) as? Bool
    }

    private static func snapshotPasteboard(_ board: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restorePasteboard(
        _ board: NSPasteboard,
        saved: [[(NSPasteboard.PasteboardType, Data)]],
        ownedCount: Int?,
        ownedText: String?
    ) {
        // Do not overwrite anything copied by the user after our last pasteboard write.
        guard let ownedCount, board.changeCount == ownedCount,
              board.string(forType: .string) == ownedText else {
            return
        }
        board.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty {
            board.writeObjects(items)
        }
    }

    private static func pointValue(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let raw = value(element, name),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axVal = unsafeBitCast(raw, to: AXValue.self)
        var point = CGPoint.zero
        return AXValueGetValue(axVal, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ element: AXUIElement) -> CGSize? {
        guard let raw = value(element, kAXSizeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axVal = unsafeBitCast(raw, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(axVal, .cgSize, &size) ? size : nil
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        return status == .success && settable.boolValue
    }

    public struct PaseoObservedTargetSnapshot: Equatable, Sendable {
        public let webURL: String?
        public let documentURL: String?
        public let windowTitle: String?
        public let selectedAgentIDs: [String]
        public let allAgentTabIDs: [String]
        public let selectedNonAgentTabIDs: [String]
        public let selectedButtonLabels: [String]
        public let focusedElementDOMID: String?
        public let visitedNodeCount: Int
        public let webAreaChildCount: Int
        public let diagSamples: [String]

        public init(
            webURL: String?,
            documentURL: String? = nil,
            windowTitle: String? = nil,
            selectedAgentIDs: [String] = [],
            allAgentTabIDs: [String] = [],
            selectedNonAgentTabIDs: [String] = [],
            selectedButtonLabels: [String] = [],
            focusedElementDOMID: String? = nil,
            visitedNodeCount: Int = 0,
            webAreaChildCount: Int = 0,
            diagSamples: [String] = []
        ) {
            self.webURL = webURL
            self.documentURL = documentURL
            self.windowTitle = windowTitle
            self.selectedAgentIDs = selectedAgentIDs
            self.allAgentTabIDs = allAgentTabIDs
            self.selectedNonAgentTabIDs = selectedNonAgentTabIDs
            self.selectedButtonLabels = selectedButtonLabels
            self.focusedElementDOMID = focusedElementDOMID
            self.visitedNodeCount = visitedNodeCount
            self.webAreaChildCount = webAreaChildCount
            self.diagSamples = diagSamples
        }
    }

    public enum PaseoObservedTargetInterpretation: Equatable, Sendable {
        case agentID(String)
        case workspaceSelectedLabels(serverID: String?, workspaceID: String, selectedLabels: [String])
        case blankChat
        case ambiguous(String)
        case unrecognized(String)
    }

    nonisolated private static func paseoURLRouteSegments(_ raw: String) -> (scheme: String, host: String, segments: [String], hasQueryOrFragment: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              comps.user == nil,
              comps.password == nil,
              comps.port == nil else {
            return nil
        }
        let hasQueryOrFragment = comps.query != nil || comps.fragment != nil
        let host = (comps.host ?? "").lowercased()
        let pathParts = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if scheme == "paseo" {
            if host == "app" {
                return (scheme, host, pathParts, hasQueryOrFragment)
            }
            let segments = host.isEmpty ? pathParts : [host] + pathParts
            return (scheme, host, segments, hasQueryOrFragment)
        }
        if scheme == "https", host == "app.paseo.sh" {
            return (scheme, host, pathParts, hasQueryOrFragment)
        }
        return nil
    }

    nonisolated public static func parsePaseoAgentURL(_ raw: String) -> (serverID: String?, agentID: String)? {
        guard let parsed = paseoURLRouteSegments(raw), !parsed.hasQueryOrFragment else { return nil }
        let segs = parsed.segments
        if segs.count == 4, segs[0] == "h", segs[2] == "agent" {
            guard let serverID = try? ChatLink.validatePaseoServerID(segs[1]),
                  let agentID = try? ChatLink.validatePaseoID(segs[3]) else {
                return nil
            }
            return (serverID, agentID)
        }
        if parsed.scheme == "paseo", segs.count == 2, segs[0] == "agent" {
            guard let agentID = try? ChatLink.validatePaseoID(segs[1]) else {
                return nil
            }
            return (nil, agentID)
        }
        return nil
    }

    nonisolated private static func isPaseoBlankRoute(_ raw: String) -> Bool {
        guard let parsed = paseoURLRouteSegments(raw) else { return false }
        let segs = parsed.segments
        if segs.isEmpty { return true }
        if segs.count == 1, ["welcome", "new", "sessions", "schedules", "settings", "open-project"].contains(segs[0]) {
            return true
        }
        if segs.count == 2, segs[0] == "h" {
            return (try? ChatLink.validatePaseoServerID(segs[1])) != nil
        }
        if segs.count == 3, segs[0] == "h", ["open-project", "sessions", "schedules", "new", "welcome"].contains(segs[2]) {
            return (try? ChatLink.validatePaseoServerID(segs[1])) != nil
        }
        return false
    }

    nonisolated public static func parsePaseoWorkspaceURL(_ raw: String) -> (serverID: String?, workspaceID: String)? {
        guard let parsed = paseoURLRouteSegments(raw) else { return nil }
        let segs = parsed.segments
        if segs.count == 4, segs[0] == "h", (segs[2] == "workspace" || segs[2] == "w") {
            guard let serverID = try? ChatLink.validatePaseoServerID(segs[1]) else {
                return nil
            }
            let workspaceID = segs[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workspaceID.isEmpty,
                  workspaceID.count <= 128,
                  !workspaceID.contains(".."),
                  !workspaceID.hasPrefix(".") else {
                return nil
            }
            return (serverID, workspaceID)
        }
        if segs.count == 2, (segs[0] == "workspace" || segs[0] == "w") {
            let workspaceID = segs[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workspaceID.isEmpty,
                  workspaceID.count <= 128,
                  !workspaceID.contains(".."),
                  !workspaceID.hasPrefix(".") else {
                return nil
            }
            return (nil, workspaceID)
        }
        return nil
    }

    nonisolated private static func isPaseoWorkspaceRoute(_ raw: String) -> Bool {
        parsePaseoWorkspaceURL(raw) != nil
    }

    nonisolated private static func isPaseoDraftTabID(_ domID: String) -> Bool {
        domID == "workspace-tab-new"
            || domID.hasPrefix("workspace-tab-draft")
            || domID.hasPrefix("workspace-tab-new_")
    }

    nonisolated public static func normalizePaseoLabel(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated public static func interpretPaseoObservedSnapshot(_ snapshot: PaseoObservedTargetSnapshot) -> PaseoObservedTargetInterpretation {
        let urls = [snapshot.webURL, snapshot.documentURL].compactMap { raw -> String? in
            let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        let parsedAgents = urls.compactMap(parsePaseoAgentURL)
        let uniqueDirectIDs = Array(Set(parsedAgents.map(\.agentID)))
        if uniqueDirectIDs.count == 1 {
            return .agentID(uniqueDirectIDs[0])
        }
        if uniqueDirectIDs.count > 1 {
            return .ambiguous("检测到多个不同的 Paseo 对话 URL，无法自动确认目标，请手动指定链接。")
        }

        guard let primaryURL = urls.first else {
            return .unrecognized("未读取到 Paseo 当前页面 URL。")
        }
        if isPaseoBlankRoute(primaryURL) {
            return .blankChat
        }
        if let workspace = parsePaseoWorkspaceURL(primaryURL) {
            let selectedAgents = snapshot.selectedAgentIDs
            let selectedNonAgents = snapshot.selectedNonAgentTabIDs
            if selectedAgents.count == 1 {
                if selectedNonAgents.contains(where: isPaseoDraftTabID) {
                    return .ambiguous("检测到 Paseo 工作区同时存在已激活对话与新建草稿标签，无法自动判断，请选定唯一对话后再试。")
                }
                if let focused = snapshot.focusedElementDOMID,
                   focused.hasPrefix("workspace-tab-"),
                   let expectedFocused = "workspace-tab-agent_\(selectedAgents[0])" as String?,
                   focused != expectedFocused,
                   isPaseoDraftTabID(focused) {
                    return .blankChat
                }
                return .agentID(selectedAgents[0])
            }
            if selectedAgents.count > 1 {
                if let focused = snapshot.focusedElementDOMID,
                   focused.hasPrefix("workspace-tab-agent_") {
                    let focusedID = String(focused.dropFirst("workspace-tab-agent_".count))
                    if let validID = try? ChatLink.validatePaseoID(focusedID),
                       selectedAgents.contains(validID) {
                        return .agentID(validID)
                    }
                }
                return .ambiguous("当前 Paseo 工作区同时分屏选中了多个对话标签（\(selectedAgents.count) 个），无法自动判断目标，请手动输入链接。")
            }
            if selectedNonAgents.contains(where: isPaseoDraftTabID) {
                return .blankChat
            }
            if !selectedNonAgents.isEmpty {
                return .unrecognized("当前 Paseo 工作区激活的是非对话标签（\(selectedNonAgents.joined(separator: ", "))），请切到对话或草稿标签后再试。")
            }
            if snapshot.allAgentTabIDs.isEmpty, !snapshot.selectedButtonLabels.isEmpty {
                return .workspaceSelectedLabels(
                    serverID: workspace.serverID,
                    workspaceID: workspace.workspaceID,
                    selectedLabels: snapshot.selectedButtonLabels
                )
            }
            if snapshot.allAgentTabIDs.isEmpty,
               let rawTitle = snapshot.windowTitle {
                let normTitle = normalizePaseoLabel(rawTitle)
                if !normTitle.isEmpty {
                    return .workspaceSelectedLabels(
                        serverID: workspace.serverID,
                        workspaceID: workspace.workspaceID,
                        selectedLabels: [normTitle]
                    )
                }
            }
            return .unrecognized("已识别 Paseo 工作区页面（\(workspace.workspaceID)），但未检测到已激活的对话标签（候选 Agent 标签数：\(snapshot.allAgentTabIDs.count)，节点数：\(snapshot.visitedNodeCount)，Web 子节点数：\(snapshot.webAreaChildCount)）。")
        }
        return .unrecognized("无法识别当前 Paseo 页面（\(safeURLPreview(primaryURL) ?? "未知地址")），请打开具体对话或工作区空白页后再试。")
    }

    static func persistPaseoDiagnostic(
        windowSummary: [String],
        snapshot: PaseoObservedTargetSnapshot?,
        resolution: String? = nil,
        error: String?
    ) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport.appendingPathComponent("AnkerVoiceBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "windows": windowSummary,
            "windowTitle": snapshot?.windowTitle as Any,
            "webURL": snapshot?.webURL as Any,
            "documentURL": snapshot?.documentURL as Any,
            "selectedAgentIDs": snapshot?.selectedAgentIDs ?? [],
            "allAgentTabIDs": snapshot?.allAgentTabIDs ?? [],
            "selectedNonAgentTabIDs": snapshot?.selectedNonAgentTabIDs ?? [],
            "selectedButtonLabels": snapshot?.selectedButtonLabels ?? [],
            "focusedElementDOMID": snapshot?.focusedElementDOMID as Any,
            "visitedNodeCount": snapshot?.visitedNodeCount ?? 0,
            "webAreaChildCount": snapshot?.webAreaChildCount ?? 0,
            "tabs": snapshot?.diagSamples ?? [],
            "resolution": resolution as Any,
            "error": error as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let url = dir.appendingPathComponent("paseo-ax-diag.json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func extractShallowAXTextLabel(_ root: AXUIElement, maxNodes: Int = 16, maxDepth: Int = 4) -> String? {
        for attr in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
            if let direct = stringValue(root, attr) {
                let norm = normalizePaseoLabel(direct)
                if !norm.isEmpty {
                    return norm
                }
            }
        }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var idx = 0
        while idx < queue.count, idx < maxNodes {
            let (el, depth) = queue[idx]
            idx += 1
            if idx > 1 {
                let role = stringValue(el, kAXRoleAttribute) ?? ""
                if role == "AXStaticText" || role == "AXHeading" {
                    for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                        if let text = stringValue(el, attr) {
                            let norm = normalizePaseoLabel(text)
                            if !norm.isEmpty {
                                return norm
                            }
                        }
                    }
                }
            }
            guard depth < maxDepth,
                  let children = value(el, kAXChildrenAttribute) as? [AXUIElement],
                  !children.isEmpty else {
                continue
            }
            for child in children {
                if queue.count >= maxNodes { break }
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func scanPaseoWindowAXSnapshot(axApp: AXUIElement, window: AXUIElement, maxNodes: Int = 12000, maxDepth: Int = 45) -> PaseoObservedTargetSnapshot {
        var webURL: String?
        var documentURL: String? = safeURLPreview(stringValue(window, kAXDocumentAttribute))
        let windowTitle = truncated(stringValue(window, kAXTitleAttribute), limit: 512)
        var selectedAgentIDs: [String] = []
        var allAgentTabIDs: [String] = []
        var selectedNonAgentTabIDs: [String] = []
        var selectedButtonLabels: [String] = []
        var diagSamples: [String] = []
        var visitedNodeCount = 0
        var webAreaChildCount = 0

        var seenSelectedAgents: Set<String> = []
        var seenAllAgents: Set<String> = []
        var seenSelectedNonAgents: Set<String> = []
        var seenSelectedButtonLabels: Set<String> = []

        var focusedDOMID: String?
        if let focusedRef = value(axApp, kAXFocusedUIElementAttribute),
           CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            let focusedEl = unsafeBitCast(focusedRef, to: AXUIElement.self)
            focusedDOMID = truncated(
                stringValue(focusedEl, "AXDOMIdentifier") ?? stringValue(focusedEl, kAXIdentifierAttribute),
                limit: 160
            )
        }

        let selectableControlRoles: Set<String> = ["AXButton", "AXTab", "AXRadioButton"]
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, index < maxNodes {
            let (el, depth) = queue[index]
            index += 1
            visitedNodeCount += 1
            let role = stringValue(el, kAXRoleAttribute) ?? ""
            let domID = stringValue(el, "AXDOMIdentifier") ?? stringValue(el, kAXIdentifierAttribute) ?? ""
            let children = depth < maxDepth ? (value(el, kAXChildrenAttribute) as? [AXUIElement] ?? []) : []

            if role == "AXWebArea" {
                if webURL == nil {
                    webURL = safeURLPreview(stringValue(el, kAXURLAttribute))
                }
                if documentURL == nil {
                    documentURL = safeURLPreview(stringValue(el, kAXDocumentAttribute))
                }
                webAreaChildCount = max(webAreaChildCount, children.count)
                if diagSamples.count < 35 {
                    diagSamples.append("AXWebArea children=\(children.count) depth=\(depth)")
                }
            }

            let selectedAttr = boolValue(el, kAXSelectedAttribute)
            let isSelected = selectedAttr == true

            if domID.hasPrefix("workspace-tab-") {
                if domID.hasPrefix("workspace-tab-agent_") {
                    let rawAgentID = String(domID.dropFirst("workspace-tab-agent_".count))
                    if let validID = try? ChatLink.validatePaseoID(rawAgentID) {
                        if seenAllAgents.insert(validID).inserted {
                            allAgentTabIDs.append(validID)
                        }
                        if isSelected, seenSelectedAgents.insert(validID).inserted {
                            selectedAgentIDs.append(validID)
                        }
                    }
                } else if isSelected, seenSelectedNonAgents.insert(domID).inserted {
                    selectedNonAgentTabIDs.append(domID)
                }
                if diagSamples.count < 35 {
                    let selStr = selectedAttr.map { $0 ? "1" : "0" } ?? "nil"
                    let focStr = boolValue(el, kAXFocusedAttribute).map { $0 ? "1" : "0" } ?? "nil"
                    diagSamples.append("\(role)[\(domID)] sel=\(selStr) foc=\(focStr)")
                }
            } else if isSelected,
                      selectableControlRoles.contains(role),
                      !domID.hasPrefix("sidebar-"),
                      !domID.hasPrefix("workspace-sidebar-") {
                let rawLabel = extractShallowAXTextLabel(el) ?? ""
                let cleanLabel = String(rawLabel.prefix(300))
                if !cleanLabel.isEmpty, seenSelectedButtonLabels.insert(cleanLabel).inserted {
                    selectedButtonLabels.append(cleanLabel)
                }
                if diagSamples.count < 35 {
                    let idPart = domID.isEmpty ? "" : "[\(domID)]"
                    let labelPart = cleanLabel.isEmpty ? "<empty>" : String(cleanLabel.prefix(60))
                    diagSamples.append("\(role)\(idPart) sel=1 label=\(labelPart)")
                }
            } else if isSelected, diagSamples.count < 35 {
                let labelPreview = extractShallowAXTextLabel(el).map { String($0.prefix(40)) } ?? "<empty>"
                let idPart = domID.isEmpty ? "" : "[\(domID)]"
                diagSamples.append("\(role)\(idPart) sel=1 label=\(labelPreview)")
            } else if !domID.isEmpty, domID.hasPrefix("agent-chat-scroll"), diagSamples.count < 35 {
                diagSamples.append("\(role)[\(domID)] depth=\(depth)")
            } else if selectedButtonLabels.isEmpty,
                      selectableControlRoles.contains(role),
                      diagSamples.count < 20 {
                let selStr = selectedAttr.map { $0 ? "1" : "0" } ?? "nil"
                let labelPreview = extractShallowAXTextLabel(el).map { String($0.prefix(40)) } ?? "<empty>"
                let idPart = domID.isEmpty ? "" : "[\(domID)]"
                diagSamples.append("\(role)\(idPart) sel=\(selStr) label=\(labelPreview)")
            }

            if !children.isEmpty {
                for child in children {
                    if queue.count >= maxNodes { break }
                    queue.append((child, depth + 1))
                }
            }
        }

        return PaseoObservedTargetSnapshot(
            webURL: webURL,
            documentURL: documentURL,
            windowTitle: windowTitle,
            selectedAgentIDs: selectedAgentIDs,
            allAgentTabIDs: allAgentTabIDs,
            selectedNonAgentTabIDs: selectedNonAgentTabIDs,
            selectedButtonLabels: selectedButtonLabels,
            focusedElementDOMID: focusedDOMID,
            visitedNodeCount: visitedNodeCount,
            webAreaChildCount: webAreaChildCount,
            diagSamples: diagSamples
        )
    }

    private static func paseoNeedsDOMTreeHydration(_ snap: PaseoObservedTargetSnapshot) -> Bool {
        let urls = [snap.webURL, snap.documentURL].compactMap { $0 }
        if urls.contains(where: { parsePaseoAgentURL($0) != nil || isPaseoBlankRoute($0) }) {
            return false
        }
        if urls.contains(where: { isPaseoWorkspaceRoute($0) }),
           let title = snap.windowTitle.map(normalizePaseoLabel),
           !title.isEmpty {
            return false
        }
        if !snap.selectedAgentIDs.isEmpty
            || !snap.selectedNonAgentTabIDs.isEmpty
            || !snap.selectedButtonLabels.isEmpty {
            return false
        }
        return true
    }

    public static func inspectPaseoTarget(
        bundleIdentifiers: [String] = ["sh.paseo.desktop"],
        appName: String = "Paseo"
    ) async throws -> (interpretation: PaseoObservedTargetInterpretation, windowSummary: [String], snapshot: PaseoObservedTargetSnapshot) {
        guard isTrusted else {
            throw RoutingError("请在系统设置 → 隐私与安全性 → 辅助功能中允许安克豆按键语音。")
        }
        let initial: Focus
        do {
            initial = try focus(bundleIdentifiers: bundleIdentifiers, appName: appName)
        } catch {
            if let front = NSWorkspace.shared.frontmostApplication,
               let bid = front.bundleIdentifier,
               Set(uniqueBundleIDs(bundleIdentifiers)).contains(bid) {
                let rawWins = (value(AXUIElementCreateApplication(front.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []
                let winDesc = rawWins.map { w in
                    let sub = stringValue(w, kAXSubroleAttribute) ?? "nil"
                    let sz = sizeValue(w).map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
                    let main = boolValue(w, kAXMainAttribute) == true ? "main" : "-"
                    let modal = boolValue(w, kAXModalAttribute) == true ? "modal" : "-"
                    return "sub=\(sub) size=\(sz) \(main) \(modal)"
                }
                persistPaseoDiagnostic(windowSummary: winDesc, snapshot: nil, error: error.localizedDescription)
            }
            throw error
        }

        let axApp = AXUIElementCreateApplication(initial.pid)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let originalEnhancedUI = boolValue(axApp, "AXEnhancedUserInterface") ?? false
        var enabledEnhancedUI = false
        defer {
            if enabledEnhancedUI {
                AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }

        let rawWins = (value(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let winSummary = rawWins.map { w in
            let sub = stringValue(w, kAXSubroleAttribute) ?? "nil"
            let sz = sizeValue(w).map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
            return "sub=\(sub) size=\(sz)"
        }

        func captureOnce(allowEnhancedActivation: Bool) async throws -> PaseoObservedTargetSnapshot {
            try check(initial, bundleIdentifiers: bundleIdentifiers, appName: appName)
            var snap = scanPaseoWindowAXSnapshot(axApp: axApp, window: initial.window)
            if allowEnhancedActivation && paseoNeedsDOMTreeHydration(snap) {
                AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                if !originalEnhancedUI && !enabledEnhancedUI {
                    if AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
                        enabledEnhancedUI = true
                    }
                }
                for _ in 0..<8 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try check(initial, bundleIdentifiers: bundleIdentifiers, appName: appName)
                    snap = scanPaseoWindowAXSnapshot(axApp: axApp, window: initial.window)
                    if !paseoNeedsDOMTreeHydration(snap) {
                        break
                    }
                }
            }
            return snap
        }

        let firstSnap = try await captureOnce(allowEnhancedActivation: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(initial, bundleIdentifiers: bundleIdentifiers, appName: appName)
        let secondSnap = try await captureOnce(allowEnhancedActivation: false)

        if ProcessInfo.processInfo.environment["BEANBRIDGE_PASEO_DIAG"] == "1" {
            let diag = "PaseoAX windows=\(winSummary) webURL=\(firstSnap.webURL ?? "nil") doc=\(firstSnap.documentURL ?? "nil") selected=\(firstSnap.selectedAgentIDs) allAgents=\(firstSnap.allAgentTabIDs) nonAgents=\(firstSnap.selectedNonAgentTabIDs) selButtons=\(firstSnap.selectedButtonLabels) nodes=\(firstSnap.visitedNodeCount) webChildren=\(firstSnap.webAreaChildCount) focused=\(firstSnap.focusedElementDOMID ?? "nil") tabs=\(firstSnap.diagSamples)"
            FileHandle.standardError.write(Data((diag + "\n").utf8))
        }

        let firstResult = interpretPaseoObservedSnapshot(firstSnap)
        let secondResult = interpretPaseoObservedSnapshot(secondSnap)
        guard firstResult == secondResult else {
            let msg = "读取 Paseo 对话时窗口或标签发生切换，本次不会自动发送，请重试。"
            persistPaseoDiagnostic(windowSummary: winSummary, snapshot: firstSnap, error: msg)
            throw RoutingError(msg)
        }

        switch firstResult {
        case .agentID:
            persistPaseoDiagnostic(windowSummary: winSummary, snapshot: firstSnap, resolution: "directAgentID", error: nil)
            return (firstResult, winSummary, firstSnap)
        case .workspaceSelectedLabels:
            return (firstResult, winSummary, firstSnap)
        case .blankChat:
            persistPaseoDiagnostic(windowSummary: winSummary, snapshot: firstSnap, resolution: "blankChat", error: "blankChat")
            throw CurrentChatError.noChatLink
        case let .ambiguous(reason), let .unrecognized(reason):
            persistPaseoDiagnostic(windowSummary: winSummary, snapshot: firstSnap, error: reason)
            throw RoutingError(reason)
        }
    }

    public static func inspectAndCapturePaseoTarget(
        bundleIdentifiers: [String] = ["sh.paseo.desktop"],
        appName: String = "Paseo"
    ) async throws -> String {
        let outcome = try await inspectPaseoTarget(bundleIdentifiers: bundleIdentifiers, appName: appName)
        switch outcome.interpretation {
        case let .agentID(id):
            return id
        case let .workspaceSelectedLabels(_, workspaceID, _):
            let msg = "当前 Paseo 工作区（\(workspaceID)）需通过 Paseo 守护进程解析激活标签，请通过 Paseo 适配器探测。"
            persistPaseoDiagnostic(windowSummary: outcome.windowSummary, snapshot: outcome.snapshot, error: msg)
            throw RoutingError(msg)
        case .blankChat:
            throw CurrentChatError.noChatLink
        case let .ambiguous(reason), let .unrecognized(reason):
            throw RoutingError(reason)
        }
    }

    nonisolated private static func safeURLPreview(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://")
            || lower.hasPrefix("doubao://") || lower.hasPrefix("doubaowork://")
            || lower.hasPrefix("paseo://") {
            return String(trimmed.prefix(240))
        }
        return nil
    }

    private static func truncated(_ raw: String?, limit: Int = 40) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.count <= limit ? trimmed : (String(trimmed.prefix(limit)) + "…")
    }

    private struct AXTreeScanResult {
        var webAreas: [DoubaoWebAreaDiag] = []
        var inputs: [DoubaoInputDiag] = []
        var headingsAndSelected: [DoubaoNodeDiag] = []
        var buttons: [DoubaoButtonDiag] = []
        var visitedNodeCount: Int = 0
    }

    private static func scanWindowAXTree(_ window: AXUIElement, maxNodes: Int = 2500, maxDepth: Int = 30) -> AXTreeScanResult {
        var result = AXTreeScanResult()
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var head = 0
        var seen = Set<UInt>()

        while head < queue.count, result.visitedNodeCount < maxNodes {
            let (element, depth) = queue[head]
            head += 1
            let hashKey = CFHash(element)
            if !seen.insert(hashKey).inserted { continue }
            result.visitedNodeCount += 1

            let role = stringValue(element, kAXRoleAttribute)
            let subrole = stringValue(element, kAXSubroleAttribute)
            let roleDesc = stringValue(element, kAXRoleDescriptionAttribute)
            let title = stringValue(element, kAXTitleAttribute)
            let editable = boolValue(element, "AXEditable")
            let selected = boolValue(element, kAXSelectedAttribute)
            let settable = isSettable(element, kAXValueAttribute)

            if role == "AXWebArea" {
                let webURL = stringValue(element, kAXURLAttribute)
                let webDoc = stringValue(element, kAXDocumentAttribute)
                result.webAreas.append(DoubaoWebAreaDiag(title: truncated(title, limit: 80), url: webURL, document: webDoc))
            } else if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
                        || role == "AXSearchField" || editable == true || settable {
                let placeholder = stringValue(element, kAXPlaceholderValueAttribute)
                let desc = stringValue(element, kAXDescriptionAttribute)
                let domID = stringValue(element, "AXDOMIdentifier") ?? stringValue(element, kAXIdentifierAttribute)
                let focused = boolValue(element, kAXFocusedAttribute)
                let rawVal = stringValue(element, kAXValueAttribute)
                result.inputs.append(
                    DoubaoInputDiag(
                        role: role,
                        subrole: subrole,
                        roleDescription: roleDesc,
                        title: truncated(title),
                        placeholder: truncated(placeholder, limit: 60),
                        description: truncated(desc),
                        domID: domID,
                        editable: editable,
                        focused: focused,
                        valueSettable: settable,
                        valueLength: rawVal?.count,
                        urlPreview: safeURLPreview(rawVal)
                    )
                )
            } else if role == kAXButtonRole, result.buttons.count < 40 {
                let desc = stringValue(element, kAXDescriptionAttribute)
                let enabled = boolValue(element, kAXEnabledAttribute)
                let combined = ((title ?? "") + " " + (desc ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
                if !combined.isEmpty {
                    result.buttons.append(
                        DoubaoButtonDiag(
                            title: truncated(title),
                            description: truncated(desc),
                            enabled: enabled
                        )
                    )
                }
            }

            if (role == "AXHeading" || selected == true), result.headingsAndSelected.count < 30 {
                let headingVal = title ?? stringValue(element, kAXValueAttribute) ?? stringValue(element, kAXDescriptionAttribute)
                result.headingsAndSelected.append(
                    DoubaoNodeDiag(
                        role: role,
                        subrole: subrole,
                        roleDescription: roleDesc,
                        title: truncated(headingVal),
                        selected: selected
                    )
                )
            }

            if depth < maxDepth, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children {
                    queue.append((child, depth + 1))
                }
            }
        }
        return result
    }

    private static func resolveCandidate(
        windowDoc: String?,
        windowTitle: String?,
        scan: AXTreeScanResult,
        interpretURL: (String) -> ObservedDoubaoURLMatch
    ) -> (chatID: String?, title: String?, candidateURL: String?, isBlank: Bool) {
        var candidates: [(url: String, title: String?)] = []
        for area in scan.webAreas {
            if let u = area.url, !u.isEmpty {
                candidates.append((u, area.title ?? windowTitle))
            }
            if let d = area.document, !d.isEmpty {
                candidates.append((d, area.title ?? windowTitle))
            }
        }
        if let windowDoc, !windowDoc.isEmpty {
            candidates.append((windowDoc, windowTitle))
        }
        for input in scan.inputs {
            if let u = input.urlPreview, !u.isEmpty {
                candidates.append((u, windowTitle))
            }
        }

        var sawBlank = false
        var firstURL: String? = candidates.first?.url
        for entry in candidates {
            switch interpretURL(entry.url) {
            case let .chatID(id):
                let cleanTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (id, (cleanTitle?.isEmpty == false ? cleanTitle : nil), entry.url, false)
            case .blankChat:
                sawBlank = true
                firstURL = firstURL ?? entry.url
            case .unrecognized:
                break
            }
        }
        return (nil, windowTitle, firstURL, sawBlank)
    }

    /// Inspects the frontmost Doubao Chromium/native window via Accessibility (AXWebArea AXURL / AXDocument)
    /// and returns structural diagnostics without reading message content.
    public static func inspectAndCaptureDoubaoTarget(
        bundleIdentifiers: [String],
        appName: String = "豆包",
        interpretURL: (String) -> ObservedDoubaoURLMatch
    ) async throws -> DoubaoCaptureOutcome {
        let nowText = ISO8601DateFormatter().string(from: Date())
        let allowed = Set(uniqueBundleIDs(bundleIdentifiers))
        let front = NSWorkspace.shared.frontmostApplication
        let frontBundle = front?.bundleIdentifier
        let frontPID = front?.processIdentifier

        func makeDiag(
            windows: [DoubaoWindowDiag] = [],
            windowCount: Int = 0,
            enhancedUISet: Bool = false,
            focusedRole: String? = nil,
            focusedSubrole: String? = nil,
            focusedTitle: String? = nil,
            focusedPlaceholder: String? = nil,
            focusedSettable: Bool? = nil,
            scan: AXTreeScanResult = AXTreeScanResult(),
            candidateURL: String? = nil,
            resolvedID: String? = nil,
            error: String? = nil
        ) -> DoubaoAXDiagnostics {
            DoubaoAXDiagnostics(
                timestamp: nowText,
                trusted: isTrusted,
                frontmostBundleID: frontBundle,
                frontmostPID: frontPID,
                windowCount: windowCount,
                windows: windows,
                enhancedUISet: enhancedUISet,
                focusedElementRole: focusedRole,
                focusedElementSubrole: focusedSubrole,
                focusedElementTitle: focusedTitle,
                focusedElementPlaceholder: focusedPlaceholder,
                focusedElementValueSettable: focusedSettable,
                webAreas: scan.webAreas,
                inputs: scan.inputs,
                headingsAndSelected: scan.headingsAndSelected,
                buttons: scan.buttons,
                visitedNodeCount: scan.visitedNodeCount,
                resolvedCandidateURL: candidateURL,
                resolvedID: resolvedID,
                error: error
            )
        }

        guard isTrusted else {
            return DoubaoCaptureOutcome(
                chatID: nil,
                title: nil,
                isBlankChat: false,
                hasWebArea: false,
                diagnostics: makeDiag(error: "请在系统设置 → 隐私与安全性 → 辅助功能中允许安克豆按键语音。")
            )
        }

        guard !allowed.isEmpty, let app = front, let activeBundle = frontBundle, allowed.contains(activeBundle) else {
            return DoubaoCaptureOutcome(
                chatID: nil,
                title: nil,
                isBlankChat: false,
                hasWebArea: false,
                diagnostics: makeDiag(error: "请将目标 \(appName) 对话置于前台；本次不会使用旧目标。")
            )
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let rawWindows = (value(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let filteredWindows = filterConversationWindows(rawWindows)
        let windowDiags: [DoubaoWindowDiag] = rawWindows.map { win in
            let sz = sizeValue(win)
            return DoubaoWindowDiag(
                role: stringValue(win, kAXRoleAttribute),
                subrole: stringValue(win, kAXSubroleAttribute),
                title: stringValue(win, kAXTitleAttribute),
                document: stringValue(win, kAXDocumentAttribute),
                modal: boolValue(win, kAXModalAttribute),
                minimized: boolValue(win, kAXMinimizedAttribute),
                width: sz.map { Double($0.width) },
                height: sz.map { Double($0.height) }
            )
        }

        let resolvedWindow: AXUIElement
        do {
            resolvedWindow = try resolveSingleConversationWindow(in: axApp, appName: appName)
        } catch let routingErr as RoutingError {
            return DoubaoCaptureOutcome(
                chatID: nil,
                title: nil,
                isBlankChat: false,
                hasWebArea: false,
                diagnostics: makeDiag(
                    windows: windowDiags,
                    windowCount: filteredWindows.primary.count,
                    error: routingErr.description
                )
            )
        } catch {
            return DoubaoCaptureOutcome(
                chatID: nil,
                title: nil,
                isBlankChat: false,
                hasWebArea: false,
                diagnostics: makeDiag(
                    windows: windowDiags,
                    windowCount: filteredWindows.primary.count,
                    error: "没有唯一的 \(appName) 窗口，请关闭额外窗口或在待发箱指定链接。"
                )
            )
        }

        let window = resolvedWindow

        let initialTitle = stringValue(window, kAXTitleAttribute) ?? ""
        let windowDoc = stringValue(window, kAXDocumentAttribute)

        var scan = scanWindowAXTree(window)
        var enabledEnhancedUI = false
        let originalEnhancedUI = boolValue(axApp, "AXEnhancedUserInterface") ?? false

        if (scan.webAreas.isEmpty || !scan.inputs.contains(where: { $0.role == kAXTextAreaRole })) && !originalEnhancedUI {
            if AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
                enabledEnhancedUI = true
                for _ in 0..<4 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    scan = scanWindowAXTree(window)
                    if !scan.webAreas.isEmpty && scan.inputs.contains(where: { $0.role == kAXTextAreaRole }) {
                        break
                    }
                }
            }
        }
        defer {
            if enabledEnhancedUI {
                AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }

        var focusedRole: String?
        var focusedSubrole: String?
        var focusedTitle: String?
        var focusedPlaceholder: String?
        var focusedSettable: Bool?
        if let focusedElemRaw = value(axApp, kAXFocusedUIElementAttribute),
           CFGetTypeID(focusedElemRaw) == AXUIElementGetTypeID() {
            let focusedElem = unsafeBitCast(focusedElemRaw, to: AXUIElement.self)
            focusedRole = stringValue(focusedElem, kAXRoleAttribute)
            focusedSubrole = stringValue(focusedElem, kAXSubroleAttribute)
            focusedTitle = truncated(stringValue(focusedElem, kAXTitleAttribute))
            focusedPlaceholder = truncated(stringValue(focusedElem, kAXPlaceholderValueAttribute), limit: 60)
            focusedSettable = isSettable(focusedElem, kAXValueAttribute)
        }

        let firstMatch = resolveCandidate(
            windowDoc: windowDoc,
            windowTitle: initialTitle,
            scan: scan,
            interpretURL: interpretURL
        )

        if let firstID = firstMatch.chatID {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard let nowFront = NSWorkspace.shared.frontmostApplication,
                  nowFront.processIdentifier == app.processIdentifier,
                  let nowWin = try? resolveSingleConversationWindow(in: axApp, appName: appName),
                  CFEqual(nowWin, window),
                  (stringValue(window, kAXTitleAttribute) ?? "") == initialTitle else {
                return DoubaoCaptureOutcome(
                    chatID: nil,
                    title: firstMatch.title,
                    isBlankChat: false,
                    hasWebArea: !scan.webAreas.isEmpty,
                    diagnostics: makeDiag(
                        windows: windowDiags,
                        windowCount: rawWindows.count,
                        enhancedUISet: enabledEnhancedUI,
                        focusedRole: focusedRole,
                        focusedSubrole: focusedSubrole,
                        focusedTitle: focusedTitle,
                        focusedPlaceholder: focusedPlaceholder,
                        focusedSettable: focusedSettable,
                        scan: scan,
                        candidateURL: firstMatch.candidateURL,
                        error: "读取目标时窗口发生变化，本次文字将保留到待发箱。"
                    )
                )
            }
            let secondScan = scanWindowAXTree(window)
            let secondMatch = resolveCandidate(
                windowDoc: stringValue(window, kAXDocumentAttribute),
                windowTitle: initialTitle,
                scan: secondScan,
                interpretURL: interpretURL
            )
            guard secondMatch.chatID == firstID else {
                return DoubaoCaptureOutcome(
                    chatID: nil,
                    title: firstMatch.title,
                    isBlankChat: false,
                    hasWebArea: !scan.webAreas.isEmpty,
                    diagnostics: makeDiag(
                        windows: windowDiags,
                        windowCount: rawWindows.count,
                        enhancedUISet: enabledEnhancedUI,
                        focusedRole: focusedRole,
                        focusedSubrole: focusedSubrole,
                        focusedTitle: focusedTitle,
                        focusedPlaceholder: focusedPlaceholder,
                        focusedSettable: focusedSettable,
                        scan: secondScan,
                        candidateURL: secondMatch.candidateURL ?? firstMatch.candidateURL,
                        error: "读取时切换了对话，本次不会自动发送。"
                    )
                )
            }
            return DoubaoCaptureOutcome(
                chatID: firstID,
                title: firstMatch.title,
                isBlankChat: false,
                hasWebArea: !scan.webAreas.isEmpty,
                diagnostics: makeDiag(
                    windows: windowDiags,
                    windowCount: rawWindows.count,
                    enhancedUISet: enabledEnhancedUI,
                    focusedRole: focusedRole,
                    focusedSubrole: focusedSubrole,
                    focusedTitle: focusedTitle,
                    focusedPlaceholder: focusedPlaceholder,
                    focusedSettable: focusedSettable,
                    scan: scan,
                    candidateURL: firstMatch.candidateURL,
                    resolvedID: firstID
                )
            )
        }

        return DoubaoCaptureOutcome(
            chatID: nil,
            title: firstMatch.title,
            isBlankChat: firstMatch.isBlank,
            hasWebArea: !scan.webAreas.isEmpty,
            diagnostics: makeDiag(
                windows: windowDiags,
                windowCount: rawWindows.count,
                enhancedUISet: enabledEnhancedUI,
                focusedRole: focusedRole,
                focusedSubrole: focusedSubrole,
                focusedTitle: focusedTitle,
                focusedPlaceholder: focusedPlaceholder,
                focusedSettable: focusedSettable,
                scan: scan,
                candidateURL: firstMatch.candidateURL,
                error: firstMatch.isBlank ? "当前为豆包空白新对话页" : nil
            )
        )
    }

    // MARK: - DoubaoWork Live AX Automation Helpers

    private static func singleFocusedWindow(for app: NSRunningApplication, appName: String) throws -> (axApp: AXUIElement, window: AXUIElement) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let window = try resolveSingleConversationWindow(in: axApp, appName: appName)
        guard boolValue(window, kAXMinimizedAttribute) != true else {
            throw RoutingError("\(appName) 窗口已最小化，请先展开窗口。")
        }
        return (axApp, window)
    }

    private static func activateAndWaitForSingleWindow(
        bundleIdentifiers: [String],
        appName: String,
        launchIfNeeded: Bool
    ) async throws -> (app: NSRunningApplication, axApp: AXUIElement, window: AXUIElement) {
        let ids = uniqueBundleIDs(bundleIdentifiers)
        guard !ids.isEmpty else {
            throw RoutingError("未配置 \(appName) 的应用标识。")
        }

        var candidates = runningTargetApps(bundleIdentifiers: ids)
        if candidates.isEmpty, launchIfNeeded {
            for id in ids {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                    break
                }
            }
            let launchDeadline = Date().addingTimeInterval(4.0)
            while Date() < launchDeadline {
                candidates = runningTargetApps(bundleIdentifiers: ids)
                if !candidates.isEmpty { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        guard candidates.count == 1, let app = candidates.first else {
            if candidates.isEmpty {
                throw RoutingError("\(appName) 未运行，请先打开 \(appName) 客户端。")
            }
            throw RoutingError("检测到多个 \(appName) 进程，请保留单个窗口实例。")
        }

        let bringToFront: (NSRunningApplication) -> Void = { targetApp in
            if #available(macOS 14.0, *) {
                NSApplication.shared.yieldActivation(to: targetApp)
                _ = targetApp.activate()
            } else {
                _ = targetApp.activate(options: [.activateIgnoringOtherApps])
            }
            let targetAXApp = AXUIElementCreateApplication(targetApp.processIdentifier)
            _ = AXUIElementSetAttributeValue(targetAXApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            bringToFront(app)
        }

        var lastError: Error?
        let readyDeadline = Date().addingTimeInterval(5.5)
        while Date() < readyDeadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                bringToFront(app)
            } else {
                do {
                    let (axApp, window) = try singleFocusedWindow(for: app, appName: appName)
                    return (app, axApp, window)
                } catch {
                    lastError = error
                }
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        throw lastError ?? RoutingError("无法将 \(appName) 置前并获取唯一窗口。")
    }

    private static func collectAXElements(
        _ root: AXUIElement,
        maxNodes: Int = 2500,
        maxDepth: Int = 30,
        where predicate: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        var matched: [AXUIElement] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var head = 0
        var seen = Set<UInt>()
        var visited = 0

        while head < queue.count, visited < maxNodes {
            let (element, depth) = queue[head]
            head += 1
            let hashKey = CFHash(element)
            if !seen.insert(hashKey).inserted { continue }
            visited += 1

            if predicate(element) {
                matched.append(element)
            }
            if depth < maxDepth, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children {
                    queue.append((child, depth + 1))
                }
            }
        }
        return matched
    }

    private static func findDoubaoComposerTextArea(in window: AXUIElement) -> AXUIElement? {
        let candidates = collectAXElements(window) { element in
            stringValue(element, kAXRoleAttribute) == kAXTextAreaRole && isSettable(element, kAXValueAttribute)
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            let lhsScore = composerScore(lhs)
            let rhsScore = composerScore(rhs)
            return lhsScore < rhsScore
        }
    }

    private static func composerScore(_ element: AXUIElement) -> Double {
        var score = 0.0
        if stringValue(element, kAXRoleDescriptionAttribute) == "文本输入区" { score += 100_000 }
        if boolValue(element, "AXEditable") == true { score += 10_000 }
        if boolValue(element, kAXFocusedAttribute) == true { score += 1_000 }
        if let size = sizeValue(element) {
            score += Double(max(0, size.width) * max(0, size.height)) / 100.0
        }
        return score
    }

    private static func findNewTaskButton(in window: AXUIElement) -> AXUIElement? {
        collectAXElements(window) { element in
            guard stringValue(element, kAXRoleAttribute) == kAXButtonRole,
                  boolValue(element, kAXEnabledAttribute) != false else {
                return false
            }
            let title = stringValue(element, kAXTitleAttribute) ?? ""
            let desc = stringValue(element, kAXDescriptionAttribute) ?? ""
            let combined = title + " " + desc
            return combined.contains("新工作任务") || combined.contains("新对话") || combined.contains("新建对话")
        }.first
    }

    private static func focusTextArea(_ textArea: AXUIElement, in window: AXUIElement, app: NSRunningApplication) async {
        _ = AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(textArea, kAXPressAction as CFString)
        try? await Task.sleep(nanoseconds: 80_000_000)

        if boolValue(textArea, kAXFocusedAttribute) == true {
            return
        }

        // Chromium SPAs often require an actual click inside the text area bounds to focus DOM activeElement.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let elemOrigin = pointValue(textArea, kAXPositionAttribute),
              let elemSize = sizeValue(textArea),
              elemSize.width > 4, elemSize.height > 4 else {
            return
        }
        let center = CGPoint(x: elemOrigin.x + elemSize.width / 2.0, y: elemOrigin.y + elemSize.height / 2.0)
        if let winOrigin = pointValue(window, kAXPositionAttribute), let winSize = sizeValue(window) {
            let winRect = CGRect(origin: winOrigin, size: winSize)
            guard winRect.contains(center) else { return }
        }
        if let source = CGEventSource(stateID: .combinedSessionState),
           let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
           let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) {
            mouseDown.post(tap: .cghidEventTap)
            mouseUp.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    nonisolated private static func normalizedComposerRaw(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated public static func isDoubaoPlaceholderOrEmpty(_ raw: String?, placeholder: String? = nil) -> Bool {
        guard let raw else { return true }
        let trimmed = normalizedComposerRaw(raw)
        if trimmed.isEmpty { return true }
        if let placeholder {
            let cleanPlaceholder = normalizedComposerRaw(placeholder)
            if !cleanPlaceholder.isEmpty, trimmed == cleanPlaceholder {
                return true
            }
        }
        // DoubaoWork's web editor renders CSS ::before placeholder text inside AXValue with AXPlaceholderValue unset.
        let collapsed = trimmed
            .replacingOccurrences(of: "…", with: "...")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let knownPlaceholders: Set<String> = [
            "发消息或创建任务... / 使用技能 @ 添加资料",
            "发消息或创建任务...",
            "发消息或创建任务",
            "有什么可以帮你的",
            "发送消息"
        ]
        if knownPlaceholders.contains(collapsed) {
            return true
        }
        if collapsed.count <= 32, collapsed.hasPrefix("发消息或创建任务"), collapsed.contains("使用技能"), collapsed.contains("添加资料") {
            return true
        }
        return false
    }

    private static func composerContent(_ textArea: AXUIElement, placeholder: String?) -> String {
        guard let raw = stringValue(textArea, kAXValueAttribute) else { return "" }
        if isDoubaoPlaceholderOrEmpty(raw, placeholder: placeholder) {
            return ""
        }
        return raw
    }

    private static func composerMatchesExpected(_ observed: String, expected: String) -> Bool {
        normalizedComposerRaw(observed) == normalizedComposerRaw(expected)
    }

    private static func postKey(pid: pid_t, keyCode: CGKeyCode, flags: CGEventFlags = [], tapHID: Bool = false) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw RoutingError("无法生成键盘辅助控制事件。")
        }
        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }
        if tapHID {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        } else {
            down.postToPid(pid)
            up.postToPid(pid)
        }
    }

    private static func matchesDoubaoWorkTarget(
        targetID: String,
        windowDoc: String?,
        scan: AXTreeScanResult,
        interpretURL: (String) -> ObservedDoubaoURLMatch
    ) -> Bool {
        var urls = scan.webAreas.compactMap(\.url).filter { !$0.isEmpty }
        urls += scan.webAreas.compactMap(\.document).filter { !$0.isEmpty }
        if let windowDoc, !windowDoc.isEmpty {
            urls.append(windowDoc)
        }
        if targetID == "doubaowork-active" || targetID.hasPrefix("doubao-") {
            return urls.contains { url in
                switch interpretURL(url) {
                case .chatID("doubaowork-active"), .blankChat:
                    return true
                case let .chatID(id):
                    return id == targetID
                case .unrecognized:
                    return false
                }
            }
        }
        return urls.contains { interpretURL($0) == .chatID(targetID) }
    }

    /// Bring DoubaoWork to front and trigger a new task ("新工作任务" / ⌘N) before submitting.
    public static func prepareDoubaoWorkNewTask(
        bundleIdentifiers: [String],
        appName: String = "豆包"
    ) async throws {
        guard isTrusted else {
            throw RoutingError("请在系统设置 → 隐私与安全性 → 辅助功能中允许安克豆按键语音。")
        }

        let (app, axApp, window) = try await activateAndWaitForSingleWindow(
            bundleIdentifiers: bundleIdentifiers,
            appName: appName,
            launchIfNeeded: true
        )

        let originalEnhanced = boolValue(axApp, "AXEnhancedUserInterface") ?? false
        var enabledEnhanced = false
        if !originalEnhanced {
            enabledEnhanced = AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success
        }
        defer {
            if enabledEnhanced {
                AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }

        // Allow WebArea / sidebar controls to hydrate right after cold launch or activation.
        let hydrateStart = Date()
        let hydrateDeadline = hydrateStart.addingTimeInterval(4.5)
        while Date() < hydrateDeadline {
            if findNewTaskButton(in: window) != nil {
                break
            }
            if Date().timeIntervalSince(hydrateStart) > 1.5, findDoubaoComposerTextArea(in: window) != nil {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        var triggered = false
        if let button = findNewTaskButton(in: window),
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            triggered = true
        }
        if !triggered {
            try postKey(pid: app.processIdentifier, keyCode: 45, flags: [.maskCommand]) // ⌘N
        }

        try await Task.sleep(nanoseconds: 350_000_000)
        let composerDeadline = Date().addingTimeInterval(3.5)
        while Date() < composerDeadline {
            if let composer = findDoubaoComposerTextArea(in: window) {
                let raw = stringValue(composer, kAXValueAttribute)
                let ph = stringValue(composer, kAXPlaceholderValueAttribute)
                if isDoubaoPlaceholderOrEmpty(raw, placeholder: ph) {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if findDoubaoComposerTextArea(in: window) != nil {
            return
        }
        throw RoutingError("已打开\(appName)，但未就绪新任务输入框，请切换至对话页面后重试。")
    }

    /// Submit verified text into the frontmost single DoubaoWork composer via macOS Accessibility + paste/enter.
    public static func submitDoubaoWorkViaAX(
        targetID: String,
        text: String,
        bundleIdentifiers: [String],
        appName: String = "豆包",
        interpretURL: (String) -> ObservedDoubaoURLMatch
    ) async throws -> String {
        guard isTrusted else {
            throw RoutingError("请在系统设置 → 隐私与安全性 → 辅助功能中允许安克豆按键语音。")
        }
        guard !normalizedComposerRaw(text).isEmpty else {
            throw RoutingError("投递文字不能为空。")
        }

        let (app, axApp, window) = try await activateAndWaitForSingleWindow(
            bundleIdentifiers: bundleIdentifiers,
            appName: appName,
            launchIfNeeded: false
        )

        let originalEnhanced = boolValue(axApp, "AXEnhancedUserInterface") ?? false
        var enabledEnhanced = false
        if !originalEnhanced {
            enabledEnhanced = AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success
            if enabledEnhanced {
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer {
            if enabledEnhanced {
                AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }

        let scan = scanWindowAXTree(window)
        let windowDoc = stringValue(window, kAXDocumentAttribute)
        guard matchesDoubaoWorkTarget(
            targetID: targetID,
            windowDoc: windowDoc,
            scan: scan,
            interpretURL: interpretURL
        ) else {
            throw RoutingError("当前\(appName)窗口页面与目标会话不一致，已取消自动发送。")
        }

        guard let textArea = findDoubaoComposerTextArea(in: window) else {
            throw RoutingError("未在\(appName)窗口找到可写入的输入框，请确认当前处于对话界面。")
        }

        let placeholder = stringValue(textArea, kAXPlaceholderValueAttribute)
        let existing = composerContent(textArea, placeholder: placeholder)
        let existingTrimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingTrimmed.isEmpty {
            throw RoutingError("检测到\(appName)输入框已有内容（\(existingTrimmed.count) 字），为避免覆盖草稿，本次未发送（文字已保留在待发箱）。")
        }

        await focusTextArea(textArea, in: window, app: app)

        // Paste text into the composer so Chromium/React triggers synthetic input events cleanly.
        let board = NSPasteboard.general
        let savedBoard = snapshotPasteboard(board)
        var ownedCount: Int?
        var ownedText: String?
        defer {
            restorePasteboard(board, saved: savedBoard, ownedCount: ownedCount, ownedText: ownedText)
        }

        board.clearContents()
        guard board.setString(text, forType: .string) else {
            throw RoutingError("无法写入系统剪贴板以粘贴至\(appName)。")
        }
        ownedCount = board.changeCount
        ownedText = text

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw RoutingError("\(appName)在写入前失去前台焦点，已取消自动发送。")
        }
        try postKey(pid: app.processIdentifier, keyCode: 9, flags: [.maskCommand]) // ⌘V

        var verifiedWritten = false
        let pasteDeadline = Date().addingTimeInterval(0.35)
        while Date() < pasteDeadline {
            let observed = composerContent(textArea, placeholder: placeholder)
            if composerMatchesExpected(observed, expected: text) {
                verifiedWritten = true
                break
            }
            try await Task.sleep(nanoseconds: 45_000_000)
        }

        if !verifiedWritten {
            let current = normalizedComposerRaw(composerContent(textArea, placeholder: placeholder))
            if current.isEmpty, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                // Retry once via HID tap in case Chromium's main-menu shortcut routing ignored postToPid.
                try postKey(pid: app.processIdentifier, keyCode: 9, flags: [.maskCommand], tapHID: true) // ⌘V
                let retryDeadline = Date().addingTimeInterval(0.45)
                while Date() < retryDeadline {
                    let observed = composerContent(textArea, placeholder: placeholder)
                    if composerMatchesExpected(observed, expected: text) {
                        verifiedWritten = true
                        break
                    }
                    try await Task.sleep(nanoseconds: 45_000_000)
                }
            }
        }

        if !verifiedWritten {
            let current = normalizedComposerRaw(composerContent(textArea, placeholder: placeholder))
            if current.isEmpty {
                _ = AXUIElementSetAttributeValue(textArea, kAXValueAttribute as CFString, text as CFTypeRef)
                try await Task.sleep(nanoseconds: 120_000_000)
                let fallbackObserved = composerContent(textArea, placeholder: placeholder)
                verifiedWritten = composerMatchesExpected(fallbackObserved, expected: text)
            }
        }

        guard verifiedWritten else {
            throw RoutingError("\(appName)输入框内容校验未通过，已中止发送（文字已保留在待发箱）。")
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw RoutingError("\(appName)在发送前失去前台焦点，请到\(appName)窗口核对内容。")
        }

        try postKey(pid: app.processIdentifier, keyCode: 36, tapHID: true) // Return

        let clearDeadline = Date().addingTimeInterval(1.5)
        while Date() < clearDeadline {
            try await Task.sleep(nanoseconds: 60_000_000)
            let remaining = normalizedComposerRaw(composerContent(textArea, placeholder: placeholder))
            if remaining.isEmpty {
                return "已发送至豆包工作窗口"
            }
        }

        let remainingCount = normalizedComposerRaw(composerContent(textArea, placeholder: placeholder)).count
        throw RoutingError("按回车后\(appName)输入框仍未清空（约 \(remainingCount) 字），请到\(appName)窗口核对是否已发送。")
    }
}
