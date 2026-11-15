import AppKit
import Foundation
import OpenBeanKit

@MainActor
final class ASRModelManagerWindow: NSObject, NSWindowDelegate {
    let window: NSPanel
    let modelManager: ASRModelManager
    let downloadManager: ASRModelDownloadManager

    var onConfigurationChanged: (() -> Void)?
    var onStatusMessage: ((String) -> Void)?

    private let activeModelLabel = NSTextField(labelWithString: "")
    private let strategyLabel = NSTextField(labelWithString: "")
    private let envWarningLabel = NSTextField(wrappingLabelWithString: "")
    private let sourcePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoActivateCheckbox = NSButton(checkboxWithTitle: "下载并校验完成后自动切换为当前模型", target: nil, action: nil)
    private let autoPolicyButton = NSButton(title: "改为自动优选", target: nil, action: nil)
    private let openFolderButton = NSButton(title: "打开 Models 目录", target: nil, action: nil)
    private let verifyAllButton = NSButton(title: "校验本地模型", target: nil, action: nil)
    private let copyCommandButton = NSButton(title: "复制终端命令", target: nil, action: nil)
    private let footerHintLabel = NSTextField(labelWithString: "关闭窗口后下载会在后台继续；所有模型均先流式校验 SHA-256 再安装。")

    private final class TierRowViews {
        let tier: ASRModelTier
        let cardBox: NSBox
        let titleLabel: NSTextField
        let badgeLabel: NSTextField
        let detailLabel: NSTextField
        let deleteButton: NSButton
        let primaryButton: NSButton
        let progressContainer: NSStackView
        let progressBar: NSProgressIndicator
        let progressStatusLabel: NSTextField

        init(
            tier: ASRModelTier,
            cardBox: NSBox,
            titleLabel: NSTextField,
            badgeLabel: NSTextField,
            detailLabel: NSTextField,
            deleteButton: NSButton,
            primaryButton: NSButton,
            progressContainer: NSStackView,
            progressBar: NSProgressIndicator,
            progressStatusLabel: NSTextField
        ) {
            self.tier = tier
            self.cardBox = cardBox
            self.titleLabel = titleLabel
            self.badgeLabel = badgeLabel
            self.detailLabel = detailLabel
            self.deleteButton = deleteButton
            self.primaryButton = primaryButton
            self.progressContainer = progressContainer
            self.progressBar = progressBar
            self.progressStatusLabel = progressStatusLabel
        }
    }

    private var rowsByTier: [ASRModelTier: TierRowViews] = [:]
    private var latestSnapshots: [ASRModelTier: ASRModelDownloadSnapshot] = [:]
    private var lastObservedCompleted: [ASRModelTier: URL] = [:]
    private var isVerifyingInstalled = false

    private static let displayOrder: [ASRModelTier] = [.small, .smallQ5_1, .medium, .base]

    init(modelManager: ASRModelManager, downloadManager: ASRModelDownloadManager) {
        self.modelManager = modelManager
        self.downloadManager = downloadManager
        self.window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 590),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        setupUI()
        refresh()
    }

    private func setupUI() {
        window.title = "ASR 语音识别模型管理与下载中心"
        window.minSize = NSSize(width: 660, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self

        guard let contentView = window.contentView else { return }

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])

        // 顶部摘要与配置区
        let headerBox = NSBox()
        headerBox.boxType = .custom
        headerBox.cornerRadius = 8
        headerBox.borderWidth = 1
        headerBox.borderColor = .separatorColor
        headerBox.fillColor = .controlBackgroundColor
        headerBox.contentViewMargins = NSSize(width: 12, height: 10)
        headerBox.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headerBox)
        headerBox.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerBox.contentView?.addSubview(headerStack)

        if let headerContent = headerBox.contentView {
            NSLayoutConstraint.activate([
                headerStack.topAnchor.constraint(equalTo: headerContent.topAnchor),
                headerStack.leadingAnchor.constraint(equalTo: headerContent.leadingAnchor),
                headerStack.trailingAnchor.constraint(equalTo: headerContent.trailingAnchor),
                headerStack.bottomAnchor.constraint(equalTo: headerContent.bottomAnchor)
            ])
        }

        activeModelLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        activeModelLabel.lineBreakMode = .byTruncatingMiddle
        headerStack.addArrangedSubview(activeModelLabel)

        let strategyRow = NSStackView()
        strategyRow.orientation = .horizontal
        strategyRow.alignment = .centerY
        strategyRow.spacing = 10
        strategyLabel.font = .systemFont(ofSize: 12)
        strategyLabel.textColor = .secondaryLabelColor
        autoPolicyButton.bezelStyle = .rounded
        autoPolicyButton.controlSize = .small
        autoPolicyButton.target = self
        autoPolicyButton.action = #selector(switchToAutoPolicy)
        strategyRow.addArrangedSubview(strategyLabel)
        strategyRow.addArrangedSubview(autoPolicyButton)
        headerStack.addArrangedSubview(strategyRow)

        envWarningLabel.font = .systemFont(ofSize: 11.5)
        envWarningLabel.textColor = .systemOrange
        envWarningLabel.isHidden = true
        headerStack.addArrangedSubview(envWarningLabel)

        let controlsRow = NSStackView()
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 10
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        let sourceTitle = NSTextField(labelWithString: "下载源：")
        sourceTitle.font = .systemFont(ofSize: 12, weight: .medium)
        sourcePopUp.removeAllItems()
        for source in ASRDownloadSource.allCases {
            sourcePopUp.addItem(withTitle: source.displayName)
            sourcePopUp.lastItem?.representedObject = source.rawValue
        }
        sourcePopUp.controlSize = .regular

        autoActivateCheckbox.state = .on
        autoActivateCheckbox.font = .systemFont(ofSize: 12)

        openFolderButton.bezelStyle = .rounded
        openFolderButton.controlSize = .small
        openFolderButton.target = self
        openFolderButton.action = #selector(openModelsDirectory)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        controlsRow.addArrangedSubview(sourceTitle)
        controlsRow.addArrangedSubview(sourcePopUp)
        controlsRow.addArrangedSubview(autoActivateCheckbox)
        controlsRow.addArrangedSubview(spacer)
        controlsRow.addArrangedSubview(openFolderButton)
        headerStack.addArrangedSubview(controlsRow)
        controlsRow.widthAnchor.constraint(equalTo: headerStack.widthAnchor).isActive = true

        // 中部 4 个模型卡片
        for tier in Self.displayOrder {
            let row = buildTierRow(tier)
            rowsByTier[tier] = row
            rootStack.addArrangedSubview(row.cardBox)
            row.cardBox.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }

        // 底部工具栏
        let footerRow = NSStackView()
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 8
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        verifyAllButton.bezelStyle = .rounded
        verifyAllButton.target = self
        verifyAllButton.action = #selector(verifyInstalledModels)

        copyCommandButton.bezelStyle = .rounded
        copyCommandButton.target = self
        copyCommandButton.action = #selector(copyCLICommand)

        let refreshButton = NSButton(title: "刷新状态", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        footerRow.addArrangedSubview(verifyAllButton)
        footerRow.addArrangedSubview(copyCommandButton)
        footerRow.addArrangedSubview(footerSpacer)
        footerRow.addArrangedSubview(refreshButton)
        footerRow.addArrangedSubview(closeButton)
        rootStack.addArrangedSubview(footerRow)
        footerRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        footerHintLabel.font = .systemFont(ofSize: 11)
        footerHintLabel.textColor = .secondaryLabelColor
        rootStack.addArrangedSubview(footerHintLabel)

        window.center()
    }

    private func buildTierRow(_ tier: ASRModelTier) -> TierRowViews {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .windowBackgroundColor
        box.contentViewMargins = NSSize(width: 12, height: 10)
        box.translatesAutoresizingMaskIntoConstraints = false

        let rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(rowStack)

        if let boxContent = box.contentView {
            NSLayoutConstraint.activate([
                rowStack.topAnchor.constraint(equalTo: boxContent.topAnchor),
                rowStack.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor),
                rowStack.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor),
                rowStack.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor)
            ])
        }

        let topLine = NSStackView()
        topLine.orientation = .horizontal
        topLine.alignment = .centerY
        topLine.spacing = 8
        topLine.translatesAutoresizingMaskIntoConstraints = false

        let titleText = tier.isRecommended ? "\(tier.displayName)  [推荐]" : tier.displayName
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let deleteButton = NSButton(title: "删除", target: self, action: #selector(deleteButtonClicked(_:)))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.identifier = NSUserInterfaceItemIdentifier(tier.rawValue)
        deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true

        let primaryButton = NSButton(title: "下载模型", target: self, action: #selector(primaryButtonClicked(_:)))
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .small
        primaryButton.identifier = NSUserInterfaceItemIdentifier(tier.rawValue)
        primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        topLine.addArrangedSubview(titleLabel)
        topLine.addArrangedSubview(badgeLabel)
        topLine.addArrangedSubview(topSpacer)
        topLine.addArrangedSubview(deleteButton)
        topLine.addArrangedSubview(primaryButton)
        rowStack.addArrangedSubview(topLine)
        topLine.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true

        let detailLabel = NSTextField(wrappingLabelWithString: "\(tier.recommendationSummary)（文件：\(tier.fileName)）")
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(detailLabel)
        detailLabel.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true

        let progressContainer = NSStackView()
        progressContainer.orientation = .vertical
        progressContainer.alignment = .leading
        progressContainer.spacing = 4
        progressContainer.translatesAutoresizingMaskIntoConstraints = false
        progressContainer.isHidden = true

        let progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let progressStatusLabel = NSTextField(labelWithString: "")
        progressStatusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressStatusLabel.textColor = .secondaryLabelColor
        progressStatusLabel.lineBreakMode = .byTruncatingMiddle

        progressContainer.addArrangedSubview(progressBar)
        progressContainer.addArrangedSubview(progressStatusLabel)
        progressBar.widthAnchor.constraint(equalTo: progressContainer.widthAnchor).isActive = true

        rowStack.addArrangedSubview(progressContainer)
        progressContainer.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true

        return TierRowViews(
            tier: tier,
            cardBox: box,
            titleLabel: titleLabel,
            badgeLabel: badgeLabel,
            detailLabel: detailLabel,
            deleteButton: deleteButton,
            primaryButton: primaryButton,
            progressContainer: progressContainer,
            progressBar: progressBar,
            progressStatusLabel: progressStatusLabel
        )
    }

    func showWindow() {
        latestSnapshots = downloadManager.snapshots()
        refresh()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applyDownloadSnapshots(_ snapshots: [ASRModelTier: ASRModelDownloadSnapshot]) {
        latestSnapshots = snapshots
        var newCompletion = false
        for (tier, snap) in snapshots {
            if case let .completed(url, _) = snap.phase, lastObservedCompleted[tier] != url {
                lastObservedCompleted[tier] = url
                newCompletion = true
                onStatusMessage?("ASR 模型 \(tier.shortName) 下载并校验完成。")
            } else if case let .failed(msg) = snap.phase {
                onStatusMessage?("ASR 模型 \(tier.shortName) 下载失败：\(msg)")
            }
        }
        refresh()
        if newCompletion {
            onConfigurationChanged?()
        }
    }

    func refresh() {
        let resolved = modelManager.resolveModel()
        let activeBadge = resolved.exists ? "已就绪" : "未安装"
        activeModelLabel.stringValue = "当前生效：\(resolved.displayLabel)  [\(activeBadge) · \(resolved.source.rawValue)]"

        if let pref = modelManager.preferredTier() {
            strategyLabel.stringValue = "当前策略：已固定首选 \(pref.shortName)（可切回自动优选本地最高精度）"
            autoPolicyButton.isEnabled = !modelManager.isOverriddenByEnvironment
        } else {
            strategyLabel.stringValue = "当前策略：自动优选本地最高精度（Medium > Small > Small-Q5_1 > Base）"
            autoPolicyButton.isEnabled = false
        }

        if modelManager.isOverriddenByEnvironment {
            envWarningLabel.stringValue = "⚠ 已检测到环境变量 BEANBRIDGE_MODEL=\(resolved.path)，下载完成后需取消该环境变量才能切换默认模型。"
            envWarningLabel.isHidden = false
        } else {
            envWarningLabel.isHidden = true
        }

        for tier in Self.displayOrder {
            guard let row = rowsByTier[tier] else { continue }
            let installed = modelManager.isTierInstalled(tier)
            let sizeBytes = modelManager.installedFileSizeBytes(for: tier)
            let isActive = resolved.exists && resolved.tier == tier
            let snap = latestSnapshots[tier]

            if let snap {
                switch snap.phase {
                case .downloading:
                    row.badgeLabel.stringValue = "正在下载"
                    row.badgeLabel.textColor = .systemBlue
                    row.cardBox.borderColor = .systemBlue.withAlphaComponent(0.55)
                    row.primaryButton.title = "取消下载"
                    row.primaryButton.isEnabled = true
                    row.deleteButton.isHidden = true
                    row.progressContainer.isHidden = false
                    row.progressBar.isIndeterminate = false
                    row.progressBar.doubleValue = snap.fractionCompleted
                    row.progressStatusLabel.stringValue = snap.statusText
                    row.progressStatusLabel.textColor = .secondaryLabelColor
                    continue
                case .verifying:
                    row.badgeLabel.stringValue = "校验完整性…"
                    row.badgeLabel.textColor = .systemOrange
                    row.cardBox.borderColor = .systemOrange.withAlphaComponent(0.55)
                    row.primaryButton.title = "校验中…"
                    row.primaryButton.isEnabled = false
                    row.deleteButton.isHidden = true
                    row.progressContainer.isHidden = false
                    row.progressBar.isIndeterminate = true
                    row.progressBar.startAnimation(nil)
                    row.progressStatusLabel.stringValue = snap.statusText
                    row.progressStatusLabel.textColor = .systemOrange
                    continue
                case .failed, .cancelled, .completed:
                    row.progressBar.stopAnimation(nil)
                    row.progressBar.isIndeterminate = false
                    row.progressContainer.isHidden = false
                    row.progressBar.doubleValue = snap.fractionCompleted
                    row.progressStatusLabel.stringValue = snap.statusText
                    if case .failed = snap.phase {
                        row.progressStatusLabel.textColor = .systemRed
                    } else if case .completed = snap.phase {
                        row.progressStatusLabel.textColor = .systemGreen
                    } else {
                        row.progressStatusLabel.textColor = .secondaryLabelColor
                    }
                case .idle:
                    row.progressContainer.isHidden = true
                }
            } else {
                row.progressBar.stopAnimation(nil)
                row.progressContainer.isHidden = true
            }

            if installed {
                let sizeText = sizeBytes.map { ASRByteFormatter.formatSize($0) } ?? "已存在"
                if isActive {
                    row.badgeLabel.stringValue = "当前生效 ✓（\(sizeText)）"
                    row.badgeLabel.textColor = .systemGreen
                    row.cardBox.borderColor = .systemGreen.withAlphaComponent(0.55)
                    row.primaryButton.title = "当前使用中"
                    row.primaryButton.isEnabled = false
                } else {
                    row.badgeLabel.stringValue = "已下载（\(sizeText)）"
                    row.badgeLabel.textColor = .labelColor
                    row.cardBox.borderColor = .separatorColor
                    row.primaryButton.title = "设为当前"
                    row.primaryButton.isEnabled = !modelManager.isOverriddenByEnvironment
                }
                row.deleteButton.isHidden = false
                row.deleteButton.isEnabled = true
            } else {
                row.badgeLabel.stringValue = "未下载"
                row.badgeLabel.textColor = .secondaryLabelColor
                row.cardBox.borderColor = .separatorColor
                row.primaryButton.title = "下载模型"
                row.primaryButton.isEnabled = true
                row.deleteButton.isHidden = true
            }
        }
    }

    // MARK: - Actions

    private func selectedDownloadSource() -> ASRDownloadSource {
        let raw = (sourcePopUp.selectedItem?.representedObject as? String) ?? ASRDownloadSource.huggingFace.rawValue
        return ASRDownloadSource(rawValue: raw) ?? .huggingFace
    }

    @objc private func primaryButtonClicked(_ sender: NSButton) {
        guard let rawTier = sender.identifier?.rawValue,
              let tier = ASRModelTier.parse(rawTier) else {
            return
        }
        if let snap = latestSnapshots[tier], snap.isInProgress {
            downloadManager.cancelDownload(tier: tier)
            onStatusMessage?("已请求取消 \(tier.shortName) 模型下载。")
            return
        }

        if modelManager.isTierInstalled(tier) {
            do {
                try modelManager.setPreferredTier(tier)
                refresh()
                onConfigurationChanged?()
                let resolved = modelManager.resolveModel()
                onStatusMessage?("ASR 模型已切换为：\(resolved.displayLabel)")
            } catch {
                onStatusMessage?("切换 ASR 模型失败：\(error)")
            }
            return
        }

        let source = selectedDownloadSource()
        let autoActivate = (autoActivateCheckbox.state == .on)
        downloadManager.startDownload(tier: tier, source: source, setAsDefaultOnSuccess: autoActivate)
        onStatusMessage?("开始下载 \(tier.shortName) 模型（\(source.displayName)）…")
    }

    @objc private func deleteButtonClicked(_ sender: NSButton) {
        guard let rawTier = sender.identifier?.rawValue,
              let tier = ASRModelTier.parse(rawTier),
              modelManager.isTierInstalled(tier) else {
            return
        }
        guard !(latestSnapshots[tier]?.isInProgress ?? false) else { return }

        let installedCount = modelManager.installedTiers().count
        let sizeText = modelManager.installedFileSizeBytes(for: tier).map { ASRByteFormatter.formatSize($0) } ?? ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除本地模型 \(tier.fileName)？"
        if installedCount <= 1 {
            alert.informativeText = "这是本地唯一的语音模型（\(sizeText)）。删除后在下载其他模型之前将无法进行离线语音识别，确定删除吗？"
        } else {
            alert.informativeText = "将从本地删除 \(tier.fileName)（\(sizeText)）释放磁盘空间；如它是当前默认模型，系统会自动回退到其他已安装模型。"
        }
        alert.addButton(withTitle: "确认删除")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try modelManager.deleteInstalledModel(tier: tier)
            downloadManager.clearSnapshot(for: tier)
            lastObservedCompleted.removeValue(forKey: tier)
            latestSnapshots = downloadManager.snapshots()
            refresh()
            onConfigurationChanged?()
            let updated = modelManager.resolveModel()
            onStatusMessage?("已删除模型 \(tier.fileName)，当前生效：\(updated.displayLabel)")
        } catch {
            onStatusMessage?("删除模型失败：\(error)")
        }
    }

    @objc private func switchToAutoPolicy() {
        do {
            try modelManager.clearPreference()
            refresh()
            onConfigurationChanged?()
            let updated = modelManager.resolveModel()
            onStatusMessage?("已切换为自动优选模式，当前生效：\(updated.displayLabel)")
        } catch {
            onStatusMessage?("切回自动优选失败：\(error)")
        }
    }

    @objc private func openModelsDirectory() {
        do {
            let dir = try modelManager.ensureModelsDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } catch {
            onStatusMessage?("无法打开 Models 目录：\(error)")
        }
    }

    @objc private func verifyInstalledModels() {
        guard !isVerifyingInstalled else { return }
        let installed = ASRModelTier.allCases.filter { modelManager.isTierInstalled($0) }
        guard !installed.isEmpty else {
            footerHintLabel.stringValue = "当前没有已安装的本地模型可供校验。"
            return
        }
        isVerifyingInstalled = true
        verifyAllButton.isEnabled = false
        footerHintLabel.stringValue = "正在后台流式校验 \(installed.count) 个本地模型的 SHA-256…"

        let manager = self.modelManager
        Task { @MainActor [weak self] in
            let summaryText = await Task.detached(priority: .userInitiated) { () -> String in
                var summaryParts: [String] = []
                for tier in installed {
                    do {
                        let ok = try manager.verifyInstalledModel(tier)
                        summaryParts.append("\(tier.shortName): \(ok ? "✓通过" : "✗校验不匹配")")
                    } catch {
                        summaryParts.append("\(tier.shortName): ✗读取失败")
                    }
                }
                return "SHA-256 校验结果 → " + summaryParts.joined(separator: " ｜ ")
            }.value
            guard let self else { return }
            self.isVerifyingInstalled = false
            self.verifyAllButton.isEnabled = true
            self.footerHintLabel.stringValue = summaryText
            self.onStatusMessage?(summaryText)
        }
    }

    @objc private func copyCLICommand() {
        let preferred = modelManager.preferredTier() ?? .small
        let cmd = "./scripts/setup-model.sh --tier \(preferred.rawValue) --set-default"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        footerHintLabel.stringValue = "已复制终端命令：\(cmd)"
        onStatusMessage?("已复制终端下载命令：\(cmd)")
    }

    @objc private func refreshClicked() {
        latestSnapshots = downloadManager.snapshots()
        refresh()
    }

    @objc private func closeClicked() {
        window.close()
    }
}
