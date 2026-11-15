import AppKit
import AVFoundation
import Foundation
import OpenBeanKit
import VoiceRouting

@MainActor
final class WorkbenchPanel: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window: NSPanel
    let archive: WorkbenchArchive
    let syncCoordinator: OfflineSyncCoordinator
    let slicer: AudioVADslicer
    let asrService: ASRService
    let router: VoiceRouter
    weak var voicePanel: VoicePanel?

    /// 提供当前活跃 BLE 会话以执行离机增量同步。
    var sessionProvider: (() -> D3200Session?)?
    /// 当模型或热词配置变更时通知外部刷新显示。
    var onASRConfigurationChanged: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let modelInfoLabel = NSTextField(labelWithString: "")
    private let categoryFilter = NSSegmentedControl(labels: ["全部", "灵感收集箱", "工作回放"], trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField(frame: .zero)
    private let syncButton = NSButton(title: "增量同步离机录音", target: nil, action: nil)
    private let pendingButton = NSButton(title: "待发箱", target: nil, action: nil)
    private let hotwordButton = NSButton(title: "热词管理", target: nil, action: nil)
    private let modelButton = NSButton(title: "ASR 模型与下载", target: nil, action: nil)

    private let tableView = NSTableView(frame: .zero)
    private let transcriptView = NSTextView(frame: .zero)
    private let targetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let newSessionCheckbox = NSButton(checkboxWithTitle: "新建独立会话", target: nil, action: nil)
    private let playButton = NSButton(title: "播放片段", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制文本", target: nil, action: nil)
    private let sendButton = NSButton(title: "一键发往目标", target: nil, action: nil)
    private let toggleCategoryButton = NSButton(title: "移至灵感箱/回放", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除记录", target: nil, action: nil)

    private struct DisplayRow {
        let item: WorkbenchItem
        let segment: ArchivedSegment
        let matchedKeywords: [String]
        let excerpt: String
    }

    private var rows: [DisplayRow] = []
    private var isSyncing = false
    private var audioPlayer: AVAudioPlayer?
    private var tempPlaybackURL: URL?
    private var modelManagerWindow: ASRModelManagerWindow?
    private var completedDownloadURLByTier: [ASRModelTier: URL] = [:]

    init(
        supportDirectory: URL = support,
        archive: WorkbenchArchive? = nil,
        syncCoordinator: OfflineSyncCoordinator? = nil,
        slicer: AudioVADslicer = AudioVADslicer(),
        asrService: ASRService,
        router: VoiceRouter,
        voicePanel: VoicePanel? = nil
    ) {
        let workbenchDir = supportDirectory.appendingPathComponent("Workbench", isDirectory: true)
        self.archive = archive ?? WorkbenchArchive(rootDirectoryURL: workbenchDir)
        let manifestStore = SyncManifestStore(directoryURL: workbenchDir)
        self.syncCoordinator = syncCoordinator ?? OfflineSyncCoordinator(manifest: manifestStore)
        self.slicer = slicer
        self.asrService = asrService
        self.router = router
        self.voicePanel = voicePanel

        self.window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        setupUI()
        bindModelDownloader()
        refreshTargetAdapters()
        refreshASRInfo()
        reloadData()
    }

    private func bindModelDownloader() {
        asrService.downloadManager.onSnapshotsChanged = { [weak self] snapshots in
            Task { @MainActor [weak self] in
                self?.handleDownloadSnapshots(snapshots)
            }
        }
    }

    private func handleDownloadSnapshots(_ snapshots: [ASRModelTier: ASRModelDownloadSnapshot]) {
        modelManagerWindow?.applyDownloadSnapshots(snapshots)

        var newCompletion = false
        for (tier, snap) in snapshots {
            switch snap.phase {
            case let .completed(url, _):
                if completedDownloadURLByTier[tier] != url {
                    completedDownloadURLByTier[tier] = url
                    newCompletion = true
                    statusLabel.stringValue = "ASR 模型 \(tier.shortName) 下载并校验通过。"
                }
            case let .failed(msg):
                statusLabel.stringValue = "ASR 模型 \(tier.shortName) 下载失败：\(msg)"
            case .cancelled:
                statusLabel.stringValue = "已取消 \(tier.shortName) 模型下载。"
            default:
                break
            }
        }

        refreshASRInfo()
        if newCompletion {
            onASRConfigurationChanged?()
        }
    }

    private func setupUI() {
        window.title = "安克豆工作台 · 灵感收集箱与分段回放"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self

        guard let contentView = window.contentView else { return }

        // 顶部工具栏第一行：分类切换 + 搜索框 + 增量同步
        categoryFilter.selectedSegment = 0
        categoryFilter.target = self
        categoryFilter.action = #selector(filterChanged)
        categoryFilter.frame = NSRect(x: 16, y: 476, width: 230, height: 28)
        categoryFilter.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(categoryFilter)

        searchField.placeholderString = "搜索分段转写关键词（空格分隔多词）…"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.frame = NSRect(x: 256, y: 476, width: 340, height: 28)
        searchField.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(searchField)

        syncButton.bezelStyle = .rounded
        syncButton.target = self
        syncButton.action = #selector(triggerIncrementalSync)
        syncButton.frame = NSRect(x: 606, y: 474, width: 158, height: 32)
        syncButton.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(syncButton)

        // 顶部第二行：ASR模型/热词/待发箱快捷入口 + 状态栏
        modelInfoLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modelInfoLabel.textColor = .secondaryLabelColor
        modelInfoLabel.lineBreakMode = .byTruncatingMiddle
        modelInfoLabel.frame = NSRect(x: 16, y: 442, width: 420, height: 20)
        modelInfoLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(modelInfoLabel)

        pendingButton.bezelStyle = .rounded
        pendingButton.target = self
        pendingButton.action = #selector(openPendingInbox)
        pendingButton.frame = NSRect(x: 446, y: 436, width: 96, height: 28)
        pendingButton.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(pendingButton)

        hotwordButton.bezelStyle = .rounded
        hotwordButton.target = self
        hotwordButton.action = #selector(openHotwordEditor)
        hotwordButton.frame = NSRect(x: 548, y: 436, width: 96, height: 28)
        hotwordButton.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(hotwordButton)

        modelButton.bezelStyle = .rounded
        modelButton.target = self
        modelButton.action = #selector(openModelSelector)
        modelButton.frame = NSRect(x: 650, y: 436, width: 114, height: 28)
        modelButton.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(modelButton)

        // 中部列表：分段表格
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 190, width: 748, height: 238))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]

        let colCategory = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        colCategory.title = "分类"
        colCategory.width = 76

        let colTime = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        colTime.title = "录音时间 / 标题"
        colTime.width = 165

        let colRange = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("range"))
        colRange.title = "片段区间"
        colRange.width = 105

        let colExcerpt = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("excerpt"))
        colExcerpt.title = "分段转写内容"
        colExcerpt.width = 370

        tableView.addTableColumn(colCategory)
        tableView.addTableColumn(colTime)
        tableView.addTableColumn(colRange)
        tableView.addTableColumn(colExcerpt)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.target = self
        tableView.doubleAction = #selector(playSelectedSegment)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // 下部详情：可编辑/复制的分段全文预览
        let textScroll = NSScrollView(frame: NSRect(x: 16, y: 92, width: 748, height: 88))
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.autoresizingMask = [.width, .maxYMargin]

        transcriptView.isEditable = true
        transcriptView.isSelectable = true
        transcriptView.font = .systemFont(ofSize: 13)
        transcriptView.textContainerInset = NSSize(width: 6, height: 6)
        transcriptView.autoresizingMask = [.width, .height]
        textScroll.documentView = transcriptView
        contentView.addSubview(textScroll)

        // 底部操作栏：播放、复制、修改分类、删除、目标选择与一键投递
        playButton.bezelStyle = .rounded
        playButton.target = self
        playButton.action = #selector(playSelectedSegment)
        playButton.frame = NSRect(x: 16, y: 50, width: 92, height: 30)
        playButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(playButton)

        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copySelectedText)
        copyButton.frame = NSRect(x: 114, y: 50, width: 92, height: 30)
        copyButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(copyButton)

        toggleCategoryButton.bezelStyle = .rounded
        toggleCategoryButton.target = self
        toggleCategoryButton.action = #selector(toggleSelectedCategory)
        toggleCategoryButton.frame = NSRect(x: 212, y: 50, width: 126, height: 30)
        toggleCategoryButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(toggleCategoryButton)

        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedItem)
        deleteButton.frame = NSRect(x: 344, y: 50, width: 88, height: 30)
        deleteButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(deleteButton)

        targetPopUp.frame = NSRect(x: 444, y: 52, width: 100, height: 26)
        targetPopUp.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(targetPopUp)

        newSessionCheckbox.frame = NSRect(x: 550, y: 55, width: 102, height: 20)
        newSessionCheckbox.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(newSessionCheckbox)

        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(forwardSelectedText)
        sendButton.frame = NSRect(x: 656, y: 50, width: 108, height: 30)
        sendButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(sendButton)

        // 底部状态提示行
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.frame = NSRect(x: 16, y: 16, width: 748, height: 22)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(statusLabel)

        window.center()
    }

    func showWindow() {
        refreshTargetAdapters()
        refreshASRInfo()
        reloadData()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshTargetAdapters() {
        targetPopUp.removeAllItems()
        let currentID = router.defaultAppID()
        let adapters = router.availableAdapters
        for adapter in adapters {
            targetPopUp.addItem(withTitle: adapter.displayName)
            targetPopUp.lastItem?.representedObject = adapter.appID
            if adapter.appID == currentID {
                targetPopUp.select(targetPopUp.lastItem)
            }
        }
    }

    func refreshASRInfo() {
        let resolved = asrService.modelManager.resolveModel()
        let hotwordCount = asrService.hotwordManager.loadHotwords().count
        let statusTag = resolved.exists ? "已就绪" : "未安装"
        if let activeDownload = asrService.downloadManager.activeProgressSummary() {
            modelInfoLabel.stringValue = "当前 ASR：\(resolved.displayLabel) ｜ \(activeDownload)"
        } else {
            modelInfoLabel.stringValue = "当前 ASR 模型：\(resolved.displayLabel) [\(statusTag)·\(resolved.source.rawValue)] ｜ 热词：\(hotwordCount) 个"
        }
    }

    private var selectedCategory: WorkbenchItem.Category? {
        switch categoryFilter.selectedSegment {
        case 1: return .ideaInbox
        case 2: return .playback
        default: return nil
        }
    }

    func reloadData() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = selectedCategory
        var loadedRows: [DisplayRow] = []
        do {
            if !query.isEmpty {
                let hits = try archive.search(query: query, category: cat)
                loadedRows = hits.map {
                    DisplayRow(
                        item: $0.item,
                        segment: $0.segment,
                        matchedKeywords: $0.matchedKeywords,
                        excerpt: $0.excerpt
                    )
                }
                statusLabel.stringValue = "检索 “\(query)” 命中 \(loadedRows.count) 个语音分段。"
            } else {
                let items = try archive.items(category: cat)
                for item in items {
                    if item.segments.isEmpty {
                        let placeholder = ArchivedSegment(
                            startMs: 0,
                            endMs: Int(item.durationMs),
                            transcript: item.title
                        )
                        loadedRows.append(
                            DisplayRow(item: item, segment: placeholder, matchedKeywords: [], excerpt: item.title)
                        )
                    } else {
                        for seg in item.segments {
                            loadedRows.append(
                                DisplayRow(
                                    item: item,
                                    segment: seg,
                                    matchedKeywords: [],
                                    excerpt: seg.transcript.isEmpty ? item.title : seg.transcript
                                )
                            )
                        }
                    }
                }
                statusLabel.stringValue = "共 \(items.count) 条归档录音，\(loadedRows.count) 个语音分段。"
            }
        } catch {
            statusLabel.stringValue = "读取归档失败：\(error)"
        }
        rows = loadedRows
        tableView.reloadData()
        if !rows.isEmpty, tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateDetailForSelection()
    }

    /// 供实时录音完成或轻敲标记录音入库使用。
    func ingestRealtimeRecording(
        fileId: UInt32,
        rawOpus: [UInt8],
        userMarked: Bool,
        transcript: String
    ) {
        let durationMs = UInt32((rawOpus.count / OggOpus.frameSize) * 20)
        let segments = (try? slicer.slice(rawOpus: rawOpus, userMarked: userMarked)) ?? []
        let entries: [(segment: VoiceSegment, transcript: String)]
        if segments.isEmpty {
            let single = VoiceSegment(
                startMs: 0,
                endMs: Int(durationMs),
                peakRMS: 0.01,
                opusFrames: rawOpus,
                userMarked: userMarked
            )
            entries = [(single, transcript)]
        } else if segments.count == 1 {
            entries = [(segments[0], transcript)]
        } else {
            entries = segments.enumerated().map { idx, seg in
                (seg, idx == 0 ? transcript : "（片段 \(idx + 1)）\(transcript)")
            }
        }
        let titlePrefix = userMarked ? "轻敲灵感" : "实时语音"
        let shortTitle = transcript.isEmpty ? "\(titlePrefix) #\(fileId)" : String(transcript.prefix(28))
        _ = try? archive.archiveRecording(
            fileId: fileId,
            createdAt: Date(),
            durationMs: durationMs,
            userMarked: userMarked,
            category: userMarked ? .ideaInbox : .playback,
            title: shortTitle,
            voiceSegments: entries
        )
        if window.isVisible {
            reloadData()
        }
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        reloadData()
    }

    @objc private func searchChanged() {
        reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        reloadData()
    }

    @objc private func openPendingInbox() {
        if let voicePanel {
            router.showPending(panel: voicePanel)
        }
    }

    @objc private func triggerIncrementalSync() {
        guard !isSyncing else { return }
        guard let session = sessionProvider?() else {
            statusLabel.stringValue = "当前未连接录音豆 BLE 会话，无法拉取设备内离机录音。"
            return
        }
        isSyncing = true
        syncButton.isEnabled = false
        statusLabel.stringValue = "正在检查并增量拉取录音豆上的离机录音…"

        let syncCoord = self.syncCoordinator
        let vadSlicer = self.slicer
        let asr = self.asrService
        let arch = self.archive

        Task {
            do {
                let pulledList = try await syncCoord.syncUnsyncedOverBLE(
                    session: session,
                    onFileProgress: { [weak self] file, bytes, expected, _ in
                        await MainActor.run {
                            let pct = expected > 0 ? Int(Double(bytes) * 100.0 / Double(expected)) : 0
                            self?.statusLabel.stringValue = "正在同步录音 #\(file.id)（\(pct)%）…"
                        }
                    }
                )
                if pulledList.isEmpty {
                    await MainActor.run {
                        self.isSyncing = false
                        self.syncButton.isEnabled = true
                        self.statusLabel.stringValue = "增量同步完成：设备上没有未同步的新录音。"
                        self.reloadData()
                    }
                    return
                }

                var archivedCount = 0
                for pulled in pulledList {
                    await MainActor.run {
                        self.statusLabel.stringValue = "正在切分并转写录音 #\(pulled.file.id)…"
                    }
                    let voiceSegments = (try? vadSlicer.slice(
                        rawOpus: pulled.transfer.audio,
                        userMarked: pulled.transfer.userMarked
                    )) ?? []

                    var transcribedPairs: [(segment: VoiceSegment, transcript: String)] = []
                    if voiceSegments.isEmpty {
                        let fallbackSeg = VoiceSegment(
                            startMs: 0,
                            endMs: Int(pulled.file.durationMs),
                            peakRMS: 0,
                            opusFrames: pulled.transfer.audio,
                            userMarked: pulled.transfer.userMarked
                        )
                        let text = (try? asr.transcribeOpusFrames(pulled.transfer.audio, isPreview: false)) ?? ""
                        transcribedPairs.append((fallbackSeg, text.isEmpty ? "（未识别出有效文字）" : text))
                    } else {
                        for seg in voiceSegments {
                            let text = (try? asr.transcribeOpusFrames(seg.opusFrames, isPreview: false)) ?? ""
                            transcribedPairs.append((seg, text.isEmpty ? "（静音或无识别文字）" : text))
                        }
                    }

                    let firstText = transcribedPairs.first?.transcript ?? ""
                    let cleanTitle = firstText.isEmpty || firstText.hasPrefix("（")
                        ? "离机录音 #\(pulled.file.id)"
                        : String(firstText.prefix(28))
                    let createdDate = pulled.file.startDate ?? Date()
                    _ = try arch.archiveRecording(
                        fileId: pulled.file.id,
                        createdAt: createdDate,
                        durationMs: pulled.file.durationMs,
                        userMarked: pulled.transfer.userMarked,
                        category: pulled.transfer.userMarked ? .ideaInbox : .playback,
                        title: cleanTitle,
                        voiceSegments: transcribedPairs
                    )
                    archivedCount += 1
                }

                await MainActor.run {
                    self.isSyncing = false
                    self.syncButton.isEnabled = true
                    self.reloadData()
                    self.statusLabel.stringValue = "增量同步完成：已归档 \(archivedCount) 条离机录音。"
                }
            } catch {
                await MainActor.run {
                    self.isSyncing = false
                    self.syncButton.isEnabled = true
                    self.statusLabel.stringValue = "增量同步失败：\(error)"
                }
            }
        }
    }

    @objc private func playSelectedSegment() {
        let idx = tableView.selectedRow
        guard idx >= 0, idx < rows.count else {
            statusLabel.stringValue = "请先选择要播放的语音分段。"
            return
        }
        let row = rows[idx]
        guard let oggURL = archive.audioURL(for: row.segment),
              FileManager.default.fileExists(atPath: oggURL.path) else {
            statusLabel.stringValue = "该分段没有关联本地音频文件。"
            return
        }

        stopPlayback()
        do {
            if let directPlayer = try? AVAudioPlayer(contentsOf: oggURL) {
                audioPlayer = directPlayer
                directPlayer.play()
                statusLabel.stringValue = "正在回放分段（\(Self.formatMs(row.segment.startMs)) - \(Self.formatMs(row.segment.endMs))）…"
                return
            }

            // macOS AVAudioPlayer 默认不直接解析 Ogg Opus 容器，通过内存或 ffmpeg 转临时 WAV 播放
            let tempWAV = FileManager.default.temporaryDirectory
                .appendingPathComponent("workbench-play-\(UUID().uuidString).wav")
            let ffmpegExe = asrService.ffmpegExecutable
            guard !ffmpegExe.isEmpty, FileManager.default.isExecutableFile(atPath: ffmpegExe) else {
                statusLabel.stringValue = "无法播放 Ogg 音频：未找到 ffmpeg。"
                return
            }
            _ = try runTool(
                ffmpegExe,
                ["-nostdin", "-loglevel", "error", "-y", "-i", oggURL.path, "-ac", "1", "-ar", "48000", tempWAV.path],
                timeout: 15
            )
            tempPlaybackURL = tempWAV
            let player = try AVAudioPlayer(contentsOf: tempWAV)
            audioPlayer = player
            player.play()
            statusLabel.stringValue = "正在回放分段（\(Self.formatMs(row.segment.startMs)) - \(Self.formatMs(row.segment.endMs))）…"
        } catch {
            statusLabel.stringValue = "播放失败：\(error)"
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        if let tempPlaybackURL {
            try? FileManager.default.removeItem(at: tempPlaybackURL)
            self.tempPlaybackURL = nil
        }
    }

    @objc private func copySelectedText() {
        let text = currentEditorOrSelectedText()
        guard !text.isEmpty else {
            statusLabel.stringValue = "没有可复制的文字。"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        saveEditedTranscriptIfNeeded()
        statusLabel.stringValue = "已复制分段文字到剪贴板。"
    }

    @objc private func forwardSelectedText() {
        let text = currentEditorOrSelectedText()
        guard !text.isEmpty else {
            statusLabel.stringValue = "待发送文字为空。"
            return
        }
        saveEditedTranscriptIfNeeded()
        let selectedAppID = (targetPopUp.selectedItem?.representedObject as? String) ?? router.defaultAppID()
        let createNew = (newSessionCheckbox.state == .on)
        let appName = router.adapter(for: selectedAppID)?.displayName ?? selectedAppID
        statusLabel.stringValue = "正在发往 \(appName)\(createNew ? "（新建独立会话）" : "")…"
        sendButton.isEnabled = false

        router.forwardExternalText(
            text,
            appID: selectedAppID,
            createNewSession: createNew,
            panel: voicePanel
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sendButton.isEnabled = true
                switch result {
                case let .success(msg):
                    if msg.state == .queued {
                        self.statusLabel.stringValue = "已成功发往 \(appName)：\(msg.note)"
                    } else {
                        self.statusLabel.stringValue = "已存入待发箱（\(appName)）：\(msg.note)"
                    }
                case let .failure(error):
                    self.statusLabel.stringValue = "发送未确认：\(error)。请打开待发箱核对。"
                }
            }
        }
    }

    @objc private func toggleSelectedCategory() {
        let idx = tableView.selectedRow
        guard idx >= 0, idx < rows.count else { return }
        let item = rows[idx].item
        let nextCategory: WorkbenchItem.Category = (item.category == .ideaInbox) ? .playback : .ideaInbox
        do {
            try archive.updateCategory(id: item.id, category: nextCategory)
            reloadData()
            statusLabel.stringValue = "已将“\(item.title)”移至\(nextCategory == .ideaInbox ? "灵感收集箱" : "工作回放")。"
        } catch {
            statusLabel.stringValue = "更新分类失败：\(error)"
        }
    }

    @objc private func deleteSelectedItem() {
        let idx = tableView.selectedRow
        guard idx >= 0, idx < rows.count else { return }
        let item = rows[idx].item
        do {
            try archive.delete(id: item.id)
            reloadData()
            statusLabel.stringValue = "已删除归档记录“\(item.title)”。"
        } catch {
            statusLabel.stringValue = "删除失败：\(error)"
        }
    }

    // MARK: - 热词与模型配置弹窗

    @objc func openHotwordEditor() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "编辑语音识别热词表（support/hotwords.txt）"
        alert.informativeText = "每行一个热词（支持中文与英文专业术语，如：安克豆、BeanBridge、Codex、豆包、Doubao、Paseo、飞书）。保存后将自动去重并作为 --prompt 注入 whisper-cli。"

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        editor.isEditable = true
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.string = asrService.hotwordManager.loadHotwords().joined(separator: "\n")
        scroll.documentView = editor
        alert.accessoryView = scroll

        alert.addButton(withTitle: "保存热词")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "恢复默认热词")

        let response = alert.runModal()
        do {
            if response == .alertFirstButtonReturn {
                let saved = try asrService.hotwordManager.saveFromText(editor.string)
                refreshASRInfo()
                onASRConfigurationChanged?()
                statusLabel.stringValue = "已保存 \(saved.count) 个热词。"
            } else if response == .alertThirdButtonReturn {
                let defaults = try asrService.hotwordManager.resetToDefaults()
                refreshASRInfo()
                onASRConfigurationChanged?()
                statusLabel.stringValue = "已恢复默认热词（共 \(defaults.count) 个）。"
            }
        } catch {
            statusLabel.stringValue = "保存热词失败：\(error)"
        }
    }

    @objc func openModelSelector() {
        let managerWindow: ASRModelManagerWindow
        if let existing = modelManagerWindow {
            managerWindow = existing
        } else {
            let created = ASRModelManagerWindow(
                modelManager: asrService.modelManager,
                downloadManager: asrService.downloadManager
            )
            created.onConfigurationChanged = { [weak self] in
                guard let self else { return }
                self.refreshASRInfo()
                self.onASRConfigurationChanged?()
            }
            created.onStatusMessage = { [weak self] text in
                self?.statusLabel.stringValue = text
            }
            modelManagerWindow = created
            managerWindow = created
        }
        managerWindow.showWindow()
    }

    // MARK: - NSTableView DataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count, let colID = tableColumn?.identifier else { return nil }
        let entry = rows[row]
        let text: String
        switch colID.rawValue {
        case "category":
            text = entry.item.category == .ideaInbox ? "灵感箱" : "回放"
        case "time":
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            text = "\(formatter.string(from: entry.item.createdAt)) · \(entry.item.title)"
        case "range":
            text = "\(Self.formatMs(entry.segment.startMs)) - \(Self.formatMs(entry.segment.endMs))"
        default:
            text = entry.excerpt
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetailForSelection()
    }

    private func updateDetailForSelection() {
        let idx = tableView.selectedRow
        guard idx >= 0, idx < rows.count else {
            transcriptView.string = ""
            playButton.isEnabled = false
            copyButton.isEnabled = false
            toggleCategoryButton.isEnabled = false
            deleteButton.isEnabled = false
            return
        }
        let row = rows[idx]
        transcriptView.string = row.segment.transcript.isEmpty ? row.item.title : row.segment.transcript
        playButton.isEnabled = archive.audioURL(for: row.segment) != nil
        copyButton.isEnabled = true
        toggleCategoryButton.isEnabled = true
        deleteButton.isEnabled = true
    }

    private func currentEditorOrSelectedText() -> String {
        let edited = transcriptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !edited.isEmpty {
            return edited
        }
        let idx = tableView.selectedRow
        guard idx >= 0, idx < rows.count else { return "" }
        return rows[idx].segment.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveEditedTranscriptIfNeeded() {
        let idx = tableView.selectedRow
        guard idx >= 0, idx < rows.count else { return }
        let row = rows[idx]
        let edited = transcriptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !edited.isEmpty, edited != row.segment.transcript {
            try? archive.updateSegmentTranscript(itemID: row.item.id, segmentID: row.segment.id, transcript: edited)
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopPlayback()
    }

    private static func formatMs(_ ms: Int) -> String {
        let totalSec = max(0, ms / 1000)
        let min = totalSec / 60
        let sec = totalSec % 60
        let tenth = (max(0, ms) % 1000) / 100
        return String(format: "%02d:%02d.%d", min, sec, tenth)
    }
}
