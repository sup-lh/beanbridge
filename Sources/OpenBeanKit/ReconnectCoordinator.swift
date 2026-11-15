// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreBluetooth
import Foundation

/// BLE 连接生命周期状态。
public enum BLEConnectionState: Sendable, Equatable {
    case disconnected
    case scanning
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case sleeping
}

/// 录音豆与充电盒的实时状态快照。
public struct DeviceStatus: Sendable, Equatable {
    public var micBattery: Int?
    public var micCharging: Bool
    public var caseBattery: Int?
    public var caseCharging: Bool
    public var recording: Bool?
    public var firmware: String
    public var updatedAt: Date

    public init(
        micBattery: Int? = nil,
        micCharging: Bool = false,
        caseBattery: Int? = nil,
        caseCharging: Bool = false,
        recording: Bool? = nil,
        firmware: String = "",
        updatedAt: Date = Date()
    ) {
        self.micBattery = micBattery
        self.micCharging = micCharging
        self.caseBattery = caseBattery
        self.caseCharging = caseCharging
        self.recording = recording
        self.firmware = firmware
        self.updatedAt = updatedAt
    }

    public init(info: DeviceInfo, updatedAt: Date = Date()) {
        self.micBattery = info.micBattery
        self.micCharging = info.micCharging
        self.caseBattery = info.caseBattery
        self.caseCharging = info.caseCharging
        self.recording = info.recording
        self.firmware = info.firmware
        self.updatedAt = updatedAt
    }

    public mutating func apply(_ info: DeviceInfo, at now: Date = Date()) {
        micBattery = info.micBattery
        micCharging = info.micCharging
        caseBattery = info.caseBattery
        caseCharging = info.caseCharging
        recording = info.recording
        if !info.firmware.isEmpty {
            firmware = info.firmware
        }
        updatedAt = now
    }

    public func applying(_ info: DeviceInfo, at now: Date = Date()) -> DeviceStatus {
        var copy = self
        copy.apply(info, at: now)
        return copy
    }

    public mutating func apply(_ event: DeviceEvent, at now: Date = Date()) {
        switch event {
        case .recordingStarted:
            recording = true
        case .recordingStopped:
            recording = false
        case let .charging(recorder, chargingCase):
            micCharging = recorder
            caseCharging = chargingCase
        case let .battery(recorder, chargingCase):
            if let recorder { micBattery = recorder }
            if let chargingCase { caseBattery = chargingCase }
        }
        updatedAt = now
    }

    public func applying(_ event: DeviceEvent, at now: Date = Date()) -> DeviceStatus {
        var copy = self
        copy.apply(event, at: now)
        return copy
    }
}

/// 指数退避重连策略。
public struct ReconnectPolicy: Sendable, Equatable {
    public var initialDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var multiplier: Double
    public var maxAttempts: Int?
    public var scanFallbackSeconds: Double

    public static let `default` = ReconnectPolicy()

    public init(
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        multiplier: Double = 2.0,
        maxAttempts: Int? = nil,
        scanFallbackSeconds: Double = 4.0
    ) {
        self.initialDelay = max(0, initialDelay)
        self.maxDelay = max(self.initialDelay, maxDelay)
        self.multiplier = max(1.0, multiplier)
        self.maxAttempts = maxAttempts
        self.scanFallbackSeconds = max(0.5, scanFallbackSeconds)
    }

    /// 计算第 `attempt` 次重连（从 1 开始）的等待秒数。
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let normalized = max(1, attempt)
        let raw = initialDelay * pow(multiplier, Double(normalized - 1))
        if raw.isInfinite || raw.isNaN { return maxDelay }
        return min(maxDelay, max(0, raw))
    }

    /// 是否允许执行第 `attempt` 次重连（从 1 开始）。
    public func canAttempt(_ attempt: Int) -> Bool {
        guard attempt >= 1 else { return false }
        if let maxAttempts {
            return attempt <= maxAttempts
        }
        return true
    }
}

/// 负责 BLE 自动重连、macOS 睡眠唤醒恢复与设备实时状态同步的协调器。
public final class ReconnectCoordinator: @unchecked Sendable {
    public let policy: ReconnectPolicy

    private let lock = NSLock()
    private var _link: Link?
    private var _session: D3200Session?
    private var _peripheralID: UUID?
    private var _state: BLEConnectionState = .disconnected
    private var _status = DeviceStatus()
    private var reconnectTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var shouldReconnectAfterWake = false
    private let reconnectHandler: ((Int, UUID?) async throws -> DeviceInfo?)?

    public var onConnectionStateChange: ((BLEConnectionState) -> Void)?
    public var onStatusChange: ((DeviceStatus) -> Void)?
    public var onDeviceEvent: ((DeviceEvent) -> Void)?
    public var onSessionReady: ((D3200Session, DeviceInfo?) -> Void)?

    public var link: Link {
        lock.lock()
        if let existing = _link {
            lock.unlock()
            return existing
        }
        let created = Link()
        _link = created
        lock.unlock()
        configureLinkCallbacks(created)
        return created
    }

    public var session: D3200Session? {
        lock.lock()
        defer { lock.unlock() }
        return _session
    }

    public var peripheralID: UUID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _peripheralID
        }
        set {
            lock.lock()
            _peripheralID = newValue
            lock.unlock()
        }
    }

    public var state: BLEConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public var status: DeviceStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public init(
        link: Link? = nil,
        policy: ReconnectPolicy = .default,
        observeWorkspaceNotifications: Bool = true,
        reconnectHandler: ((Int, UUID?) async throws -> DeviceInfo?)? = nil
    ) {
        self.policy = policy
        self._link = link
        self.reconnectHandler = reconnectHandler
        if let link {
            self._peripheralID = link.lastConnectedPeripheralID
            configureLinkCallbacks(link)
        }
        if observeWorkspaceNotifications {
            registerWorkspaceNotifications()
        }
    }

    deinit {
        reconnectTask?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
    }

    private func configureLinkCallbacks(_ link: Link) {
        link.onDisconnect = { [weak self] in
            self?.handleUnexpectedDisconnect()
        }
    }

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepObs = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleSystemWillSleep()
        }
        let wakeObs = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleSystemDidWake()
        }
        workspaceObservers = [sleepObs, wakeObs]
    }

    public func rememberPeripheral(_ id: UUID) {
        lock.lock()
        _peripheralID = id
        lock.unlock()
    }

    @discardableResult
    public func updateStatus(with info: DeviceInfo, at now: Date = Date()) -> DeviceStatus {
        let updated: DeviceStatus = {
            lock.lock()
            defer { lock.unlock() }
            _status.apply(info, at: now)
            return _status
        }()
        onStatusChange?(updated)
        return updated
    }

    @discardableResult
    public func updateStatus(with event: DeviceEvent, at now: Date = Date()) -> DeviceStatus {
        let updated: DeviceStatus = {
            lock.lock()
            defer { lock.unlock() }
            _status.apply(event, at: now)
            return _status
        }()
        onStatusChange?(updated)
        return updated
    }

    private func transition(to newState: BLEConnectionState) {
        let changed: Bool = {
            lock.lock()
            defer { lock.unlock() }
            guard _state != newState else { return false }
            _state = newState
            return true
        }()
        if changed {
            onConnectionStateChange?(newState)
        }
    }

    /// 首次或主动连接：优先使用已记录的 peripheralID，否则扫描设备并完成握手与事件监听。
    @discardableResult
    public func connect(scanSeconds: Double = 5.0) async throws -> D3200Session {
        cancelReconnectTask()
        let activeLink = self.link
        try await activeLink.waitPoweredOn()

        let targetPeripheral: CBPeripheral
        if let knownID = peripheralID, let retrieved = activeLink.retrieve(knownID) {
            targetPeripheral = retrieved
        } else {
            transition(to: .scanning)
            let devices = await activeLink.scan(seconds: scanSeconds).filter(\.serviceMatch)
            guard let first = devices.first else {
                transition(to: .disconnected)
                throw LinkError.missing("录音豆")
            }
            targetPeripheral = first.peripheral
        }

        transition(to: .connecting)
        do {
            try await activeLink.connect(targetPeripheral)
            rememberPeripheral(targetPeripheral.identifier)
            let (session, info) = try await establishSession(over: activeLink)
            transition(to: .connected)
            onSessionReady?(session, info)
            return session
        } catch {
            transition(to: .disconnected)
            throw error
        }
    }

    /// 主动断开连接并停止自动重连。
    public func disconnect() {
        cancelReconnectTask()
        lock.lock()
        shouldReconnectAfterWake = false
        let existingLink = _link
        _session = nil
        lock.unlock()
        existingLink?.disconnect()
        transition(to: .disconnected)
    }

    /// 当已建立的 BLE 连接意外断开时触发指数退避自动重连。
    public func handleUnexpectedDisconnect() {
        enum Action {
            case ignoreWhileSleeping
            case startReconnect
            case markDisconnected
        }
        let action: Action = {
            lock.lock()
            defer { lock.unlock() }
            if _state == .sleeping { return .ignoreWhileSleeping }
            if let lastID = _link?.lastConnectedPeripheralID, _peripheralID == nil {
                _peripheralID = lastID
            }
            return (_peripheralID != nil || reconnectHandler != nil) ? .startReconnect : .markDisconnected
        }()
        switch action {
        case .ignoreWhileSleeping:
            return
        case .markDisconnected:
            transition(to: .disconnected)
        case .startReconnect:
            startReconnectLoop()
        }
    }

    /// 系统即将进入睡眠：暂停扫描与重连计时器、清理悬挂等待器，并切换为 `.sleeping`。
    public func handleSystemWillSleep() {
        cancelReconnectTask()
        let existingLink: Link? = {
            lock.lock()
            defer { lock.unlock() }
            shouldReconnectAfterWake = (_state != .disconnected) || (_peripheralID != nil) || (reconnectHandler != nil)
            return _link
        }()
        existingLink?.prepareForSleep()
        transition(to: .sleeping)
    }

    /// 系统从睡眠唤醒：若睡前处于连接/重连状态或记录了外设 ID，自动恢复重连并刷新设备信息。
    public func handleSystemDidWake() {
        let canResume: Bool = {
            lock.lock()
            defer { lock.unlock() }
            let resume = shouldReconnectAfterWake || _peripheralID != nil || reconnectHandler != nil
            shouldReconnectAfterWake = false
            return resume
        }()
        guard canResume else {
            transition(to: .disconnected)
            return
        }
        startReconnectLoop(immediateFirstAttempt: true)
    }

    /// 主动向当前会话请求一次 `deviceInfo()` 并同步更新 `status`。
    @discardableResult
    public func refreshDeviceInfo() async throws -> DeviceInfo? {
        guard let currentSession = session else { throw LinkError.disconnected }
        let info = try await currentSession.deviceInfo()
        if let info {
            updateStatus(with: info)
        }
        return info
    }

    private func cancelReconnectTask() {
        lock.lock()
        let task = reconnectTask
        reconnectTask = nil
        lock.unlock()
        task?.cancel()
    }

    private func startReconnectLoop(immediateFirstAttempt: Bool = false) {
        cancelReconnectTask()
        guard policy.canAttempt(1) else {
            transition(to: .disconnected)
            return
        }
        transition(to: .reconnecting(attempt: 1))
        let task = Task { [weak self] in
            guard let self else { return }
            var attempt = 1
            while !Task.isCancelled && self.policy.canAttempt(attempt) {
                self.transition(to: .reconnecting(attempt: attempt))
                let waitSeconds = (attempt == 1 && immediateFirstAttempt) ? 0 : self.policy.delay(forAttempt: attempt)
                if waitSeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                }
                if Task.isCancelled || self.state == .sleeping { return }
                do {
                    try await self.performSingleReconnectAttempt(attempt: attempt)
                    if Task.isCancelled || self.state == .sleeping { return }
                    self.transition(to: .connected)
                    return
                } catch {
                    attempt += 1
                }
            }
            if !Task.isCancelled && self.state != .sleeping {
                self.transition(to: .disconnected)
            }
        }
        lock.lock()
        reconnectTask = task
        lock.unlock()
    }

    private func performSingleReconnectAttempt(attempt: Int) async throws {
        if let reconnectHandler {
            let info = try await reconnectHandler(attempt, peripheralID)
            if let info {
                updateStatus(with: info)
            }
            return
        }

        let activeLink = self.link
        try await activeLink.waitPoweredOn()

        var connected = false
        if let knownID = peripheralID, let retrieved = activeLink.retrieve(knownID) {
            do {
                try await activeLink.connect(retrieved, timeout: 10)
                rememberPeripheral(retrieved.identifier)
                connected = true
            } catch {
                connected = false
            }
        }

        if !connected {
            let candidates = await activeLink.scan(seconds: policy.scanFallbackSeconds).filter(\.serviceMatch)
            let chosen: Discovered?
            if let knownID = peripheralID {
                chosen = candidates.first(where: { $0.peripheral.identifier == knownID }) ?? candidates.first
            } else {
                chosen = candidates.first
            }
            guard let target = chosen else {
                throw LinkError.missing("重连未找到录音豆")
            }
            try await activeLink.connect(target.peripheral, timeout: 15)
            rememberPeripheral(target.peripheral.identifier)
        }

        let (newSession, info) = try await establishSession(over: activeLink)
        onSessionReady?(newSession, info)
    }

    private func setSession(_ newSession: D3200Session?) {
        lock.lock()
        _session = newSession
        lock.unlock()
    }

    private func setStatus(_ newStatus: DeviceStatus) {
        lock.lock()
        _status = newStatus
        lock.unlock()
    }

    private func establishSession(over activeLink: Link) async throws -> (D3200Session, DeviceInfo?) {
        let newSession = D3200Session(link: activeLink)
        newSession.onStatusChange = { [weak self] updated in
            guard let self else { return }
            self.setStatus(updated)
            self.onStatusChange?(updated)
        }
        try await newSession.handshake()
        let info = try await newSession.deviceInfo()
        newSession.observeEvents { [weak self] event in
            self?.onDeviceEvent?(event)
        }
        setSession(newSession)
        return (newSession, info)
    }
}
