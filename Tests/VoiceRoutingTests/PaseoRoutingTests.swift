import Foundation
import XCTest
@testable import VoiceRouting

final class PaseoRoutingTests: XCTestCase {
    func testChatLinkParseAndAdapterParseAcceptValidPaseoLinksAndRejectBadInputs() throws {
        let adapter = PaseoTargetAdapter()
        let agentID = "3a45eaca-18bf-43a2-94f1-d6bd227d5225"

        XCTAssertEqual(
            try adapter.parseLink("paseo://h/srv_xJBs6MSuW_8E/agent/\(agentID)"),
            agentID
        )
        XCTAssertEqual(
            try adapter.parseLink("paseo://app/h/srv_xJBs6MSuW_8E/agent/\(agentID)"),
            agentID
        )
        XCTAssertEqual(
            try adapter.parseLink("https://app.paseo.sh/h/srv_xJBs6MSuW_8E/agent/\(agentID)"),
            agentID
        )
        XCTAssertEqual(
            try adapter.parseLink("paseo://agent/\(agentID)"),
            agentID
        )

        let parsedFromDefault = try ChatLink.parse(
            "paseo://h/srv_xJBs6MSuW_8E/agent/\(agentID)",
            defaultAppID: "paseo"
        )
        XCTAssertEqual(parsedFromDefault.appID, "paseo")
        XCTAssertEqual(parsedFromDefault.id, agentID)

        let parsedCrossApp = try ChatLink.parse(
            "https://app.paseo.sh/h/srv_xJBs6MSuW_8E/agent/\(agentID)",
            defaultAppID: "codex"
        )
        XCTAssertEqual(parsedCrossApp.appID, "paseo")
        XCTAssertEqual(parsedCrossApp.id, agentID)

        let invalidLinks = [
            "",
            "paseo://h/../agent/\(agentID)",
            "paseo://h/srv_xJBs6MSuW_8E/w/wks_123",
            "https://evil.example/h/srv_x/agent/\(agentID)",
            "http://app.paseo.sh/h/srv_x/agent/\(agentID)",
            "paseo://agent/abc",
            "paseo://agent/\(agentID)?foo=bar",
            "paseo://agent/\(agentID)#frag",
            "paseo://agent/invalid id",
            "paseo://agent/foo/bar",
        ]
        for bad in invalidLinks {
            XCTAssertThrowsError(try adapter.parseLink(bad), "Expected parseLink failure for: \(bad)")
            XCTAssertThrowsError(try ChatLink.parse(bad, defaultAppID: "paseo"), "Expected ChatLink.parse failure for: \(bad)")
        }
    }

    func testPaseoObservedAXSnapshotInterpretation() {
        let aid1 = "3a45eaca-18bf-43a2-94f1-d6bd227d5225"
        let aid2 = "4b56fbdb-29c0-44b3-a5f2-e7ce338e6336"

        XCTAssertEqual(
            CurrentChat.interpretPaseoObservedSnapshot(
                .init(webURL: "paseo://app/h/srv_1/agent/\(aid1)")
            ),
            .agentID(aid1)
        )
        XCTAssertEqual(
            CurrentChat.interpretPaseoObservedSnapshot(
                .init(webURL: "https://app.paseo.sh/h/srv_1/agent/\(aid1)")
            ),
            .agentID(aid1)
        )

        if case .ambiguous = CurrentChat.interpretPaseoObservedSnapshot(
            .init(
                webURL: "paseo://app/h/srv_1/agent/\(aid1)",
                documentURL: "paseo://app/h/srv_1/agent/\(aid2)"
            )
        ) {
        } else {
            XCTFail("Expected ambiguous result for mismatched agent URLs")
        }

        for blankURL in [
            "paseo://app/",
            "paseo://app/welcome",
            "paseo://app/new",
            "paseo://app/sessions",
            "paseo://app/schedules",
            "paseo://app/h/srv_1",
            "paseo://app/h/srv_1/open-project",
            "paseo://app/h/srv_1/sessions",
            "paseo://app/h/srv_1/schedules",
        ] {
            XCTAssertEqual(
                CurrentChat.interpretPaseoObservedSnapshot(.init(webURL: blankURL)),
                .blankChat,
                "Expected blankChat for \(blankURL)"
            )
        }

        // Workspace route: accepts both /workspace/<id> and /w/<id>
        XCTAssertEqual(
            CurrentChat.parsePaseoWorkspaceURL("paseo://app/h/srv_xJBs6MSuW_8E/workspace/wks_735bf72fbd477bdc")?.workspaceID,
            "wks_735bf72fbd477bdc"
        )
        XCTAssertEqual(
            CurrentChat.interpretPaseoObservedSnapshot(
                .init(
                    webURL: "paseo://app/h/srv_xJBs6MSuW_8E/workspace/wks_735bf72fbd477bdc",
                    selectedAgentIDs: [aid1],
                    allAgentTabIDs: [aid1]
                )
            ),
            .agentID(aid1)
        )
        XCTAssertEqual(
            CurrentChat.interpretPaseoObservedSnapshot(
                .init(
                    webURL: "paseo://app/h/srv_xJBs6MSuW_8E/workspace/wks_735bf72fbd477bdc",
                    selectedButtonLabels: ["orchestrator", "当前开发任务"]
                )
            ),
            .workspaceSelectedLabels(
                serverID: "srv_xJBs6MSuW_8E",
                workspaceID: "wks_735bf72fbd477bdc",
                selectedLabels: ["orchestrator", "当前开发任务"]
            )
        )
        XCTAssertEqual(
            CurrentChat.interpretPaseoObservedSnapshot(
                .init(
                    webURL: "paseo://app/h/srv_xJBs6MSuW_8E/workspace/wks_735bf72fbd477bdc",
                    windowTitle: "新建 Agent"
                )
            ),
            .workspaceSelectedLabels(
                serverID: "srv_xJBs6MSuW_8E",
                workspaceID: "wks_735bf72fbd477bdc",
                selectedLabels: ["新建 Agent"]
            )
        )
        if case .unrecognized = CurrentChat.interpretPaseoObservedSnapshot(
            .init(
                webURL: "paseo://app/h/srv_xJBs6MSuW_8E/workspace/wks_735bf72fbd477bdc"
            )
        ) {
        } else {
            XCTFail("Expected unrecognized when workspace has neither tabs nor selected labels nor window title")
        }

        // Workspace route: 1 active agent tab -> .agentID
        XCTAssertEqual(
            CurrentChat.interpretPaseoObservedSnapshot(
                .init(
                    webURL: "paseo://app/h/srv_1/w/wks_735bf72fbd477bdc",
                    selectedAgentIDs: [aid1],
                    allAgentTabIDs: [aid1, aid2],
                    selectedNonAgentTabIDs: ["workspace-tab-terminal_1"]
                )
            ),
            .agentID(aid1)
        )

        // Workspace route: selected draft tab -> .blankChat
        XCTAssertEqual(
            CurrentChat.interpretPaseoObservedSnapshot(
                .init(
                    webURL: "paseo://app/h/srv_1/w/wks_735bf72fbd477bdc",
                    selectedAgentIDs: [],
                    allAgentTabIDs: [aid1],
                    selectedNonAgentTabIDs: ["workspace-tab-draft_01"]
                )
            ),
            .blankChat
        )

        // Workspace route: split pane with 2 selected agents & no matching focus -> .ambiguous
        if case .ambiguous = CurrentChat.interpretPaseoObservedSnapshot(
            .init(
                webURL: "paseo://app/h/srv_1/w/wks_735bf72fbd477bdc",
                selectedAgentIDs: [aid1, aid2],
                allAgentTabIDs: [aid1, aid2]
            )
        ) {
        } else {
            XCTFail("Expected ambiguous result for multi-selected agent tabs")
        }

        // Split pane disambiguated when focus is on one selected agent tab
        XCTAssertEqual(
            CurrentChat.interpretPaseoObservedSnapshot(
                .init(
                    webURL: "paseo://app/h/srv_1/w/wks_735bf72fbd477bdc",
                    selectedAgentIDs: [aid1, aid2],
                    allAgentTabIDs: [aid1, aid2],
                    focusedElementDOMID: "workspace-tab-agent_\(aid2)"
                )
            ),
            .agentID(aid2)
        )

        // Selected agent + selected draft -> .ambiguous (fail closed)
        if case .ambiguous = CurrentChat.interpretPaseoObservedSnapshot(
            .init(
                webURL: "paseo://app/h/srv_1/w/wks_735bf72fbd477bdc",
                selectedAgentIDs: [aid1],
                allAgentTabIDs: [aid1],
                selectedNonAgentTabIDs: ["workspace-tab-draft_1"]
            )
        ) {
        } else {
            XCTFail("Expected ambiguous when both agent and draft tabs are selected")
        }

        // Unrecognized URL -> .unrecognized
        if case .unrecognized = CurrentChat.interpretPaseoObservedSnapshot(
            .init(webURL: "https://example.com/other")
        ) {
        } else {
            XCTFail("Expected unrecognized for non-Paseo URL")
        }
    }

    func testRegistryIncludesPaseoPreferenceSwitchingAndCanonicalLink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paseo-pref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let registry = AppTargetRegistry.shared
        XCTAssertNotNil(registry.adapter(for: "paseo"))
        XCTAssertEqual(registry.adapter(for: "paseo")?.displayName, "Paseo")
        XCTAssertTrue(registry.allAdapters.map(\.appID).contains("paseo"))

        let store = TargetAppPreferenceStore(supportDirectory: dir, registry: registry, environmentProvider: { [:] })
        let selected = try store.setCurrentAppID("paseo")
        XCTAssertEqual(selected.appID, "paseo")
        XCTAssertEqual(try store.persistedAppID(), "paseo")

        let paseoHome = dir.appendingPathComponent("paseo-home", isDirectory: true)
        try FileManager.default.createDirectory(at: paseoHome, withIntermediateDirectories: true)
        let adapterWithoutServerID = PaseoTargetAdapter(environmentProvider: { ["BEANBRIDGE_PASEO_HOME": paseoHome.path] })
        XCTAssertEqual(
            adapterWithoutServerID.canonicalLink(for: "agent_abc123"),
            "paseo://agent/agent_abc123"
        )

        try "srv_xJBs6MSuW_8E\n".write(
            to: paseoHome.appendingPathComponent("server-id"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            adapterWithoutServerID.canonicalLink(for: "agent_abc123"),
            "paseo://h/srv_xJBs6MSuW_8E/agent/agent_abc123"
        )
    }

    func testStubbedPaseoCreateValidateOpenSubmitAndPendingStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paseo-stub-\(UUID().uuidString)", isDirectory: true)
        let scriptsDir = root.appendingPathComponent("scripts", isDirectory: true)
        let supportDir = root.appendingPathComponent("support", isDirectory: true)
        let paseoHome = root.appendingPathComponent("paseo-home", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paseoHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "srv_test1234".write(to: paseoHome.appendingPathComponent("server-id"), atomically: true, encoding: .utf8)

        let openLog = root.appendingPathComponent("open.log")
        let openCmd = root.appendingPathComponent("fake-open.sh")
        try """
        #!/bin/sh
        echo "$1" >> "\(openLog.path)"
        """.write(to: openCmd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openCmd.path)

        let bridgeLog = root.appendingPathComponent("bridge.log")
        let bridgeScript = scriptsDir.appendingPathComponent("paseo-chat.py")
        try """
        #!/usr/bin/env python3
        import json, os, sys
        args = sys.argv[1:]
        with open("\(bridgeLog.path)", "a", encoding="utf-8") as f:
            f.write(" ".join(args) + "\\n")
        action = args[args.index("--action") + 1]
        if action == "create":
            receipt = args[args.index("--receipt") + 1]
            os.makedirs(os.path.dirname(receipt), exist_ok=True)
            with open(receipt, "w", encoding="utf-8") as f:
                f.write(json.dumps({"state": "created", "target": {"id": "agent_new_9999", "title": "新 Paseo 对话", "appID": "paseo"}}))
            print(json.dumps({"id": "agent_new_9999", "title": "新 Paseo 对话", "appID": "paseo"}))
        elif action == "validate":
            aid = args[args.index("--id") + 1]
            print(json.dumps({"id": aid, "title": "已有 Paseo 对话", "appID": "paseo"}))
        elif action == "resolve-workspace-tab":
            labels = json.loads(args[args.index("--labels-json") + 1])
            if "New tab" in labels:
                print(json.dumps({"kind": "blank"}))
            else:
                print(json.dumps({"kind": "agent", "id": "agent_ws_101", "title": labels[-1], "appID": "paseo"}))
        elif action == "submit":
            receipt = args[args.index("--receipt") + 1]
            os.makedirs(os.path.dirname(receipt), exist_ok=True)
            with open(receipt, "w", encoding="utf-8") as f:
                f.write(json.dumps({"state": "submitted"}))
            print(json.dumps({"receipt": receipt, "status": "sent"}))
        """.write(to: bridgeScript, atomically: true, encoding: .utf8)

        let adapter = PaseoTargetAdapter(
            scriptsDirectory: scriptsDir,
            environmentProvider: {
                [
                    "BEANBRIDGE_PASEO_HOME": paseoHome.path,
                    "BEANBRIDGE_PASEO_OPEN_CMD": openCmd.path,
                    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                ]
            }
        )

        let resolvedWorkspaceAgent = try adapter.resolveWorkspaceTab(
            workspaceID: "wks_735bf72fbd477bdc",
            selectedLabels: ["orchestrator", "当前任务"]
        )
        XCTAssertEqual(resolvedWorkspaceAgent, "agent_ws_101")
        let resolvedWorkspaceBlank = try adapter.resolveWorkspaceTab(
            workspaceID: "wks_735bf72fbd477bdc",
            selectedLabels: ["New tab"]
        )
        XCTAssertNil(resolvedWorkspaceBlank)

        let store = PendingStore(directory: supportDir)
        let msg = PendingMessage(text: "测试 Paseo 语音输入", appID: "paseo", target: nil, note: "test")
        try store.save(msg)
        let creatingMsg = try store.beginCreation(msg.id)
        XCTAssertEqual(creatingMsg.state, .creating)
        XCTAssertThrowsError(try store.beginCreation(msg.id))

        let createdTarget = try adapter.createNewSession(messageID: msg.id, supportDirectory: supportDir)
        XCTAssertEqual(createdTarget, VoiceTarget(id: "agent_new_9999", title: "新 Paseo 对话", appID: "paseo"))

        try adapter.openSession(createdTarget)
        XCTAssertEqual(
            try String(contentsOf: openLog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "paseo://h/srv_test1234/agent/agent_new_9999"
        )

        let validated = try adapter.validate(id: "agent_existing_88", supportDirectory: supportDir)
        XCTAssertEqual(validated, VoiceTarget(id: "agent_existing_88", title: "已有 Paseo 对话", appID: "paseo"))

        var readyMsg = creatingMsg
        readyMsg.state = .pending
        readyMsg.target = createdTarget
        try store.save(readyMsg)

        let claimed = try store.beginSubmission(msg.id, target: createdTarget)
        XCTAssertEqual(claimed.target?.appID, "paseo")
        XCTAssertEqual(claimed.state, .submitting)
        let receiptPath = try adapter.submit(text: msg.text, to: createdTarget, supportDirectory: supportDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptPath))
        XCTAssertThrowsError(try store.beginSubmission(msg.id, target: createdTarget))
    }

    func testFullscreenAndTinyOverlayWindowMetadataFiltering() {
        // Real maximized/fullscreen standard window stays eligible
        XCTAssertFalse(
            CurrentChat.isAuxiliaryWindowMetadata(
                subrole: "AXStandardWindow",
                size: CGSize(width: 1512, height: 949),
                isModal: false
            )
        )
        // Fullscreen menubar/toolbar reveal overlay (height 33) or status/popover strip is filtered
        XCTAssertTrue(
            CurrentChat.isAuxiliaryWindowMetadata(
                subrole: "AXStandardWindow",
                size: CGSize(width: 1512, height: 33),
                isModal: false
            )
        )
        XCTAssertTrue(
            CurrentChat.isAuxiliaryWindowMetadata(
                subrole: "AXUnknown",
                size: CGSize(width: 1512, height: 949),
                isModal: false
            )
        )
        XCTAssertTrue(
            CurrentChat.isAuxiliaryWindowMetadata(
                subrole: nil,
                size: CGSize(width: 84, height: 77),
                isModal: false
            )
        )
        // Modals are never treated as harmless overlays
        XCTAssertFalse(
            CurrentChat.isAuxiliaryWindowMetadata(
                subrole: "AXDialog",
                size: CGSize(width: 400, height: 200),
                isModal: true
            )
        )
    }
}
