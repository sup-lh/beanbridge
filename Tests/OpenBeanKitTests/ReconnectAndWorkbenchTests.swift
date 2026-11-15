import AVFoundation
import Foundation
import XCTest
@testable import OpenBeanKit

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class ReconnectAndWorkbenchTests: XCTestCase {
    private func makeTempDirectory(_ suffix: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("beanbridge-openbeankit-tests-\(suffix)", isDirectory: true)
    }

    private func makePacket(type: UInt8, id: UInt8, status: UInt8 = 0x01, payload: [UInt8]) -> Packet {
        let total = 9 + payload.count + 1
        var raw: [UInt8] = [0x09, 0xFF, 0x00, 0x00, status, type, id, UInt8(total & 0xFF), UInt8(total >> 8)]
        raw.append(contentsOf: payload)
        raw.append(Frame.checksum(raw[...]))
        return Packet(raw: raw)
    }

    private func makeDeviceInfo(
        micBattery: UInt8 = 90,
        micCharging: Bool = false,
        firmware: String = "04.92",
        caseBattery: UInt8 = 100,
        caseCharging: Bool = false,
        recording: Bool = false
    ) throws -> DeviceInfo {
        var fwBytes = Array(firmware.utf8.prefix(5))
        while fwBytes.count < 5 { fwBytes.append(0) }

        var payload = [UInt8]()
        payload.append(0x01)
        payload.append(micBattery)
        payload.append(micCharging ? 1 : 0)
        payload.append(contentsOf: fwBytes)
        payload.append(contentsOf: Array("SN1234567890ABCD".utf8.prefix(16)))
        payload.append(contentsOf: u32le(1024))
        payload.append(contentsOf: u32le(512))
        payload.append(caseCharging ? 1 : 0)
        payload.append(contentsOf: Array("01.10".utf8))
        payload.append(caseBattery)
        payload.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        payload.append(contentsOf: [0, 0, 0, 0, 0])
        payload.append(recording ? 1 : 0)
        payload.append(contentsOf: Array("02.05".utf8))

        return try XCTUnwrap(DeviceInfo(frame: makePacket(type: 0x01, id: 0x01, payload: payload).raw))
    }

    private func makeRawOpus(frameCount: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: frameCount * OggOpus.frameSize)
        for idx in 0..<frameCount {
            let offset = idx * OggOpus.frameSize
            bytes[offset] = 0xFC
            bytes[offset + 1] = UInt8((idx % 250) + 1)
            bytes[offset + 2] = UInt8((idx >> 8) & 0xFF)
        }
        return bytes
    }

    private func parseOggPages(_ data: [UInt8]) throws -> [(flags: UInt8, sequence: UInt32, granule: UInt64, body: [UInt8], validCRC: Bool)] {
        var pages: [(flags: UInt8, sequence: UInt32, granule: UInt64, body: [UInt8], validCRC: Bool)] = []
        var offset = 0
        while offset < data.count {
            XCTAssertLessThanOrEqual(offset + 27, data.count)
            XCTAssertEqual(Array(data[offset..<(offset + 4)]), Array("OggS".utf8))
            let flags = data[offset + 5]
            var granule: UInt64 = 0
            for b in 0..<8 {
                granule |= UInt64(data[offset + 6 + b]) << (8 * UInt64(b))
            }
            let sequence = readU32(data, offset + 18)
            let recordedCRC = readU32(data, offset + 22)
            let segmentCount = Int(data[offset + 26])
            let lacingStart = offset + 27
            let bodyStart = lacingStart + segmentCount
            XCTAssertLessThanOrEqual(bodyStart, data.count)
            let bodyLength = data[lacingStart..<bodyStart].reduce(0) { $0 + Int($1) }
            let pageEnd = bodyStart + bodyLength
            XCTAssertLessThanOrEqual(pageEnd, data.count)

            var zeroed = Array(data[offset..<pageEnd])
            zeroed.replaceSubrange(22..<26, with: [0, 0, 0, 0])
            let computedCRC = OggOpus.crc32(zeroed)

            pages.append((
                flags: flags,
                sequence: sequence,
                granule: granule,
                body: Array(data[bodyStart..<pageEnd]),
                validCRC: recordedCRC == computedCRC
            ))
            offset = pageEnd
        }
        return pages
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    // MARK: - 1. 04.92 Slice.isUserMark & DeviceEvent / DeviceStatus

    func testFirmware0492SliceUserMarkBit0Regression() {
        func makeSlice(seq: UInt32, flags: UInt8, fill: UInt8, trailingPad: Bool = true) -> [UInt8] {
            var out = u32le(seq) + [flags] + Array(repeating: fill, count: 160)
            if trailingPad { out.append(0x00) }
            return out
        }

        // bit 0 set -> true; bit 0 clear (even when higher bits like 0x02, 0x04, 0x80, 0xFE are set) -> false
        let header = [UInt8](repeating: 0, count: 9)
        let frame = header
            + makeSlice(seq: 1, flags: 0x00, fill: 0x11)
            + makeSlice(seq: 2, flags: 0x01, fill: 0x22)
            + makeSlice(seq: 3, flags: 0x02, fill: 0x33)
            + makeSlice(seq: 4, flags: 0x03, fill: 0x44)
            + makeSlice(seq: 5, flags: 0x04, fill: 0x55)
            + makeSlice(seq: 6, flags: 0xFE, fill: 0x66)
            + makeSlice(seq: 7, flags: 0xFF, fill: 0x77, trailingPad: false) // 165-byte final slice still parses

        let slices = parseSlices(frame: frame)
        XCTAssertEqual(slices.map(\.seq), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(slices.map(\.isUserMark), [false, true, false, true, false, false, true])
        XCTAssertEqual(slices[1].data, Array(repeating: UInt8(0x22), count: 160))
        XCTAssertEqual(slices[6].data, Array(repeating: UInt8(0x77), count: 160))
    }

    func testDeviceEventParsingAndStatusUpdates() {
        // recordingStarted
        let startPkt = makePacket(type: 0x1A, id: 0x06, payload: u32le(123_456))
        XCTAssertEqual(DeviceEvent(packet: startPkt), .recordingStarted(fileId: 123_456))
        XCTAssertNil(DeviceEvent(packet: makePacket(type: 0x1A, id: 0x06, payload: u32le(0))))
        XCTAssertNil(DeviceEvent(packet: makePacket(type: 0x1A, id: 0x06, payload: [1, 2, 3])))

        // recordingStopped (0x00 button stop & 0x02 pause ack)
        XCTAssertEqual(DeviceEvent(packet: makePacket(type: 0x18, id: 0x82, payload: [0x00])), .recordingStopped)
        XCTAssertEqual(DeviceEvent(packet: makePacket(type: 0x18, id: 0x82, payload: [0x02])), .recordingStopped)
        XCTAssertNil(DeviceEvent(packet: makePacket(type: 0x18, id: 0x82, payload: [0x01])))
        XCTAssertNil(DeviceEvent(packet: makePacket(type: 0x18, id: 0x82, payload: [])))

        // charging
        XCTAssertEqual(
            DeviceEvent(packet: makePacket(type: 0x01, id: 0x04, payload: [0x01, 0x00])),
            .charging(recorder: true, chargingCase: false)
        )
        XCTAssertEqual(
            DeviceEvent(packet: makePacket(type: 0x01, id: 0x04, payload: [0x00, 0x01])),
            .charging(recorder: false, chargingCase: true)
        )
        XCTAssertNil(DeviceEvent(packet: makePacket(type: 0x01, id: 0x04, payload: [0x01])))

        // battery: 0...9 tiers -> (tier+1)*10, 10...100 direct, >100 -> nil
        XCTAssertEqual(
            DeviceEvent(packet: makePacket(type: 0x01, id: 0x03, payload: [0, 9])),
            .battery(recorder: 10, chargingCase: 100)
        )
        XCTAssertEqual(
            DeviceEvent(packet: makePacket(type: 0x01, id: 0x03, payload: [45, 101])),
            .battery(recorder: 45, chargingCase: nil)
        )
        XCTAssertNil(DeviceEvent(packet: makePacket(type: 0x01, id: 0x03, payload: [50])))
        XCTAssertNil(DeviceEvent(packet: makePacket(type: 0x99, id: 0x99, payload: [1, 2, 3, 4])))

        // D3200Session & DeviceStatus state updates
        let session = D3200Session(link: Link())
        var observedStatuses: [DeviceStatus] = []
        session.onStatusChange = { observedStatuses.append($0) }

        let t1 = Date(timeIntervalSince1970: 1_700_000_001)
        let s1 = session.applyDeviceEvent(.battery(recorder: 80, chargingCase: 90), at: t1)
        XCTAssertEqual(s1.micBattery, 80)
        XCTAssertEqual(s1.caseBattery, 90)
        XCTAssertEqual(s1.updatedAt, t1)

        // Partial battery event preserves non-nil existing field
        let s2 = session.applyDeviceEvent(.battery(recorder: nil, chargingCase: 70), at: t1.addingTimeInterval(1))
        XCTAssertEqual(s2.micBattery, 80)
        XCTAssertEqual(s2.caseBattery, 70)

        let s3 = session.applyDeviceEvent(.charging(recorder: true, chargingCase: false), at: t1.addingTimeInterval(2))
        XCTAssertTrue(s3.micCharging)
        XCTAssertFalse(s3.caseCharging)

        let s4 = session.applyDeviceEvent(.recordingStarted(fileId: 99), at: t1.addingTimeInterval(3))
        XCTAssertEqual(s4.recording, true)

        let s5 = session.applyDeviceEvent(.recordingStopped, at: t1.addingTimeInterval(4))
        XCTAssertEqual(s5.recording, false)
        XCTAssertEqual(session.status, s5)
        XCTAssertEqual(observedStatuses.count, 5)
    }

    func testDeviceInfoFrameParsingAndStatusFirmwarePreservation() throws {
        var payload = [UInt8]()
        payload.append(0x01) // connectStatus
        payload.append(7)    // micBattery tier 7 -> 80%
        payload.append(1)    // micCharging
        payload.append(contentsOf: Array("04.92".utf8))
        payload.append(contentsOf: Array("SN1234567890ABCD".utf8.prefix(16)))
        payload.append(contentsOf: u32le(1024)) // totalKB
        payload.append(contentsOf: u32le(512))  // freeKB
        payload.append(0)    // caseCharging
        payload.append(contentsOf: Array("01.10".utf8))
        payload.append(85)   // caseBattery 85%
        payload.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]) // caseMac
        payload.append(contentsOf: [0, 0, 0, 0, 0]) // color, auto-off, LEDs
        payload.append(1)    // recording
        payload.append(contentsOf: Array("02.05".utf8)) // wifiFirmware

        let pkt = makePacket(type: 0x01, id: 0x01, payload: payload)
        let info = try XCTUnwrap(DeviceInfo(frame: pkt.raw))
        XCTAssertEqual(info.micBattery, 80)
        XCTAssertTrue(info.micCharging)
        XCTAssertEqual(info.firmware, "04.92")
        XCTAssertEqual(info.serial, "sn1234567890abcd")
        XCTAssertEqual(info.totalKB, 1024)
        XCTAssertEqual(info.freeKB, 512)
        XCTAssertFalse(info.caseCharging)
        XCTAssertEqual(info.caseBattery, 85)
        XCTAssertEqual(info.caseMac, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(info.recording, true)
        XCTAssertEqual(info.wifiFirmware, "02.05")

        var status = DeviceStatus(info: info)
        XCTAssertEqual(status.firmware, "04.92")

        // Applying DeviceInfo with empty firmware keeps previous non-empty firmware
        let emptyFirmwareInfo = try makeDeviceInfo(micBattery: 50, firmware: "", caseBattery: 60, recording: false)
        status.apply(emptyFirmwareInfo)
        XCTAssertEqual(status.firmware, "04.92")
        XCTAssertEqual(status.micBattery, 50)
    }

    // MARK: - 2. ReconnectPolicy & ReconnectCoordinator

    func testReconnectPolicyExponentialBackoffAndMaxAttemptsBounds() {
        let policy = ReconnectPolicy(
            initialDelay: 1.5,
            maxDelay: 10.0,
            multiplier: 2.0,
            maxAttempts: 4,
            scanFallbackSeconds: 0.1
        )
        XCTAssertEqual(policy.scanFallbackSeconds, 0.5, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 0), 1.5, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1.5, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 2), 3.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 3), 6.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 4), 10.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 10_000), 10.0, accuracy: 0.0001) // overflow/inf capped to maxDelay

        XCTAssertFalse(policy.canAttempt(0))
        XCTAssertFalse(policy.canAttempt(-1))
        XCTAssertTrue(policy.canAttempt(1))
        XCTAssertTrue(policy.canAttempt(4))
        XCTAssertFalse(policy.canAttempt(5))

        let clamped = ReconnectPolicy(initialDelay: -5, maxDelay: 1, multiplier: 0.5, maxAttempts: 0)
        XCTAssertEqual(clamped.initialDelay, 0)
        XCTAssertEqual(clamped.maxDelay, 1)
        XCTAssertEqual(clamped.multiplier, 1.0)
        XCTAssertFalse(clamped.canAttempt(1))

        let unbounded = ReconnectPolicy(maxAttempts: nil)
        XCTAssertTrue(unbounded.canAttempt(100))
    }

    func testReconnectCoordinatorRetrySuccessAndStatusUpdate() async throws {
        let recordedStates = LockedBox<[BLEConnectionState]>([])
        let recordedAttempts = LockedBox<[(Int, UUID?)]>([])

        let expectedID = UUID()
        let returnedInfo = try makeDeviceInfo(micBattery: 90, firmware: "04.92", recording: false)

        let policy = ReconnectPolicy(initialDelay: 0.01, maxDelay: 0.03, multiplier: 2.0, maxAttempts: 5)
        let coordinator = ReconnectCoordinator(
            policy: policy,
            observeWorkspaceNotifications: false
        ) { attempt, peripheralID in
            recordedAttempts.withValue { $0.append((attempt, peripheralID)) }
            if attempt < 3 {
                throw LinkError.disconnected
            }
            return returnedInfo
        }

        coordinator.rememberPeripheral(expectedID)
        coordinator.onConnectionStateChange = { newState in
            recordedStates.withValue { $0.append(newState) }
        }

        coordinator.handleUnexpectedDisconnect()
        try await waitUntil { coordinator.state == .connected }

        let attemptsSnapshot = recordedAttempts.value
        let statesSnapshot = recordedStates.value

        XCTAssertEqual(attemptsSnapshot.map(\.0), [1, 2, 3])
        XCTAssertTrue(attemptsSnapshot.allSatisfy { $0.1 == expectedID })
        XCTAssertEqual(
            statesSnapshot,
            [.reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3), .connected]
        )
        XCTAssertEqual(coordinator.status.micBattery, 90)
        XCTAssertEqual(coordinator.status.firmware, "04.92")
        XCTAssertEqual(coordinator.status.recording, false)
    }

    func testReconnectCoordinatorStopsAtMaxAttemptsAndZeroMaxAttempts() async throws {
        let attemptCount = LockedBox(0)

        let failingPolicy = ReconnectPolicy(initialDelay: 0.01, maxDelay: 0.02, multiplier: 2.0, maxAttempts: 2)
        let coordinator = ReconnectCoordinator(
            policy: failingPolicy,
            observeWorkspaceNotifications: false
        ) { _, _ in
            attemptCount.withValue { $0 += 1 }
            throw LinkError.timeout("simulated")
        }

        coordinator.handleUnexpectedDisconnect()
        XCTAssertEqual(coordinator.state, .reconnecting(attempt: 1))
        try await waitUntil { coordinator.state == .disconnected }
        XCTAssertEqual(attemptCount.value, 2)

        // maxAttempts == 0 immediately transitions to disconnected without invoking handler
        let zeroHandlerCalls = LockedBox(0)
        let zeroCoordinator = ReconnectCoordinator(
            policy: ReconnectPolicy(initialDelay: 0.01, maxDelay: 0.01, multiplier: 2.0, maxAttempts: 0),
            observeWorkspaceNotifications: false
        ) { _, _ in
            zeroHandlerCalls.withValue { $0 += 1 }
            return nil
        }
        zeroCoordinator.handleUnexpectedDisconnect()
        XCTAssertEqual(zeroCoordinator.state, .disconnected)
        XCTAssertEqual(zeroHandlerCalls.value, 0)
    }

    func testReconnectCoordinatorSleepWakeAndDisconnectTransitions() async throws {
        let wakeAttempts = LockedBox(0)
        let wakeInfo = try makeDeviceInfo(micBattery: 60, firmware: "04.92", caseBattery: 100)

        let policy = ReconnectPolicy(initialDelay: 0.5, maxDelay: 2.0, multiplier: 2.0, maxAttempts: 3)
        let coordinator = ReconnectCoordinator(
            policy: policy,
            observeWorkspaceNotifications: false
        ) { attempt, _ in
            wakeAttempts.withValue { $0 += 1 }
            XCTAssertEqual(attempt, 1)
            return wakeInfo
        }
        let peripheralID = UUID()
        coordinator.rememberPeripheral(peripheralID)

        // Establish connected state first
        coordinator.handleUnexpectedDisconnect()
        try await waitUntil { coordinator.state == .connected }
        XCTAssertEqual(coordinator.status.micBattery, 60)

        wakeAttempts.withValue { $0 = 0 }

        // Sleep suspends reconnects; unexpected disconnect while sleeping must keep .sleeping and preserve state
        coordinator.handleSystemWillSleep()
        XCTAssertEqual(coordinator.state, .sleeping)
        coordinator.handleUnexpectedDisconnect()
        XCTAssertEqual(wakeAttempts.value, 0)
        XCTAssertEqual(coordinator.state, .sleeping)
        XCTAssertEqual(coordinator.peripheralID, peripheralID)
        XCTAssertEqual(coordinator.status.micBattery, 60)

        // Wake triggers immediate attempt (ignoring 0.5s initialDelay) and restores connection without losing state
        let beforeWake = Date()
        coordinator.handleSystemDidWake()
        try await waitUntil(timeout: 0.4) { coordinator.state == .connected }
        XCTAssertLessThan(Date().timeIntervalSince(beforeWake), 0.4)

        XCTAssertEqual(wakeAttempts.value, 1)
        XCTAssertEqual(coordinator.peripheralID, peripheralID)
        XCTAssertEqual(coordinator.status.micBattery, 60)
        XCTAssertEqual(coordinator.status.caseBattery, 100)

        // Disconnect clears reconnect state
        coordinator.disconnect()
        XCTAssertEqual(coordinator.state, .disconnected)

        // Idle coordinator without peripheralID or handler goes sleeping -> disconnected on wake
        let idleCoordinator = ReconnectCoordinator(
            policy: policy,
            observeWorkspaceNotifications: false,
            reconnectHandler: nil
        )
        idleCoordinator.handleSystemWillSleep()
        XCTAssertEqual(idleCoordinator.state, .sleeping)
        idleCoordinator.handleSystemDidWake()
        XCTAssertEqual(idleCoordinator.state, .disconnected)
    }

    // MARK: - 3. SyncManifestStore & OfflineSyncCoordinator Validation

    func testSyncManifestStorePermissionsFilteringAndRecovery() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SyncManifestStore(directoryURL: dir, fileName: "../nested/sync-manifest.json")
        XCTAssertEqual(store.manifestFileURL.path, dir.appendingPathComponent("sync-manifest.json").path)

        let files = [
            RecordingFile(id: 300, endTime: 360, durationMs: 60_000),
            RecordingFile(id: 200, endTime: 230, durationMs: 30_000),
            RecordingFile(id: 100, endTime: 110, durationMs: 10_000)
        ]
        XCTAssertEqual(try store.unsyncedFiles(from: files).map(\.id), [300, 200, 100])
        XCTAssertFalse(store.isSynced(200))

        let syncedAt1 = Date(timeIntervalSince1970: 1_700_000_100)
        let syncedAt2 = Date(timeIntervalSince1970: 1_700_000_200)
        try store.markSynced(fileId: 200, syncedAt: syncedAt1, source: .ble, durationMs: 30_000, userMarked: true)
        try store.markSynced(fileId: 100, syncedAt: syncedAt2, source: .wifi, durationMs: 10_000, userMarked: false)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: store.manifestFileURL.path)
        XCTAssertEqual((fileAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        XCTAssertEqual(try store.unsyncedFiles(from: files).map(\.id), [300])

        // Recover across fresh SyncManifestStore instance
        let recovered = SyncManifestStore(directoryURL: dir)
        XCTAssertTrue(recovered.isSynced(200))
        XCTAssertTrue(recovered.isSynced(100))
        XCTAssertFalse(recovered.isSynced(300))

        let rec200 = try XCTUnwrap(recovered.record(for: 200))
        XCTAssertEqual(rec200.source, .ble)
        XCTAssertEqual(rec200.durationMs, 30_000)
        XCTAssertTrue(rec200.userMarked)

        let all = try recovered.allRecords()
        XCTAssertEqual(all.map(\.fileId), [100, 200]) // sorted by syncedAt descending
        XCTAssertEqual(try recovered.unsyncedFiles(from: files).map(\.id), [300])
    }

    func testOfflineSyncCoordinatorValidateTransfer() throws {
        let valid = Transfer(
            userMarked: false,
            fileId: 1,
            audio: [0xFC, 0x01],
            head: nil,
            decrypted: true,
            decryptError: nil,
            slices: 1,
            firstSeq: 0,
            lastSeq: 0,
            missingSeqs: 0,
            gotDone: true,
            seconds: 0.1,
            arrivals: [],
            packets: [],
            newFileAt: nil
        )
        XCTAssertNoThrow(try OfflineSyncCoordinator.validateTransfer(valid))

        let notDecrypted = Transfer(
            userMarked: false, fileId: 2, audio: [0xFC], head: nil, decrypted: false,
            decryptError: "bad key", slices: 1, firstSeq: 0, lastSeq: 0, missingSeqs: 0,
            gotDone: true, seconds: 0.1, arrivals: [], packets: [], newFileAt: nil
        )
        XCTAssertThrowsError(try OfflineSyncCoordinator.validateTransfer(notDecrypted)) { error in
            XCTAssertEqual(error as? OfflineSyncError, .notDecrypted(fileId: 2, detail: "bad key"))
        }

        let emptyAudio = Transfer(
            userMarked: false, fileId: 3, audio: [], head: nil, decrypted: true,
            decryptError: nil, slices: 0, firstSeq: nil, lastSeq: nil, missingSeqs: 0,
            gotDone: true, seconds: 0.1, arrivals: [], packets: [], newFileAt: nil
        )
        XCTAssertThrowsError(try OfflineSyncCoordinator.validateTransfer(emptyAudio)) { error in
            XCTAssertEqual(error as? OfflineSyncError, .emptyAudio(fileId: 3))
        }

        let incomplete = Transfer(
            userMarked: false, fileId: 4, audio: [0xFC], head: nil, decrypted: true,
            decryptError: nil, slices: 2, firstSeq: 0, lastSeq: 3, missingSeqs: 2,
            gotDone: true, seconds: 0.1, arrivals: [], packets: [], newFileAt: nil
        )
        XCTAssertThrowsError(try OfflineSyncCoordinator.validateTransfer(incomplete, allowMissingSeqs: 1)) { error in
            XCTAssertEqual(error as? OfflineSyncError, .incompleteTransfer(fileId: 4, missingSeqs: 2))
        }
        XCTAssertNoThrow(try OfflineSyncCoordinator.validateTransfer(incomplete, allowMissingSeqs: 2))
    }

    // MARK: - 4. AudioVADslicer & OggOpus

    func testAudioVADslicerSilenceFilteringShortPauseMergeAndLongSilenceSplit() throws {
        let slicer = AudioVADslicer(
            rmsThreshold: 0.05,
            minSpeechMs: 100,        // 5 frames
            minSilenceSplitMs: 200,  // 10 frames
            paddingMs: 40            // 2 frames
        )

        // Empty / sub-frame input
        XCTAssertTrue(try slicer.slice(rawOpus: []).isEmpty)
        XCTAssertTrue(try slicer.slice(rawOpus: [UInt8](repeating: 0, count: 159)).isEmpty)

        // Pure silence (20 frames = 400 ms)
        let silenceRaw = makeRawOpus(frameCount: 20)
        XCTAssertTrue(try slicer.slice(rawOpus: silenceRaw) { _, _ in 0.01 }.isEmpty)

        // Short spike (< minSpeechMs: 4 frames = 80 ms) is filtered out
        let spikeRaw = makeRawOpus(frameCount: 15)
        let spikeSegments = try slicer.slice(rawOpus: spikeRaw) { idx, _ in
            (3..<7).contains(idx) ? 0.2 : 0.0
        }
        XCTAssertTrue(spikeSegments.isEmpty)

        // Complex timeline (40 frames = 800 ms):
        //  [0..4)   silence
        //  [4..9)   voiced burst 1 (5 frames = 100 ms, RMS 0.30)
        //  [9..13)  short pause (4 frames < 10 -> merged!)
        //  [13..18) voiced burst 2 (5 frames = 100 ms, RMS 0.60)
        //  -> merged interval [4..18), padded [2..20) => 40ms..400ms
        //  [18..28) long silence (10 frames >= 10 -> split!)
        //  [28..35) voiced burst 3 (7 frames = 140 ms, RMS 0.45)
        //  [35..40) trailing silence
        //  -> padded [26..37) => 520ms..740ms
        let totalFrames = 40
        let raw = makeRawOpus(frameCount: totalFrames)
        let rmsTable: [Float] = (0..<totalFrames).map { idx in
            if (4..<9).contains(idx) { return 0.30 }
            if (13..<18).contains(idx) { return 0.60 }
            if (28..<35).contains(idx) { return 0.45 }
            return 0.005
        }

        let segments = try slicer.slice(rawOpus: raw, userMarked: true) { idx, _ in
            rmsTable[idx]
        }
        XCTAssertEqual(segments.count, 2)

        let first = segments[0]
        XCTAssertEqual(first.startMs, 40)
        XCTAssertEqual(first.endMs, 400)
        XCTAssertEqual(first.durationMs, 360)
        XCTAssertEqual(first.peakRMS, 0.60, accuracy: 0.0001)
        XCTAssertTrue(first.userMarked)
        XCTAssertEqual(first.opusFrames, Array(raw[(2 * 160)..<(20 * 160)]))

        let second = segments[1]
        XCTAssertEqual(second.startMs, 520)
        XCTAssertEqual(second.endMs, 740)
        XCTAssertEqual(second.durationMs, 220)
        XCTAssertEqual(second.peakRMS, 0.45, accuracy: 0.0001)
        XCTAssertTrue(second.userMarked)
        XCTAssertEqual(second.opusFrames, Array(raw[(26 * 160)..<(37 * 160)]))

        // Verify OggOpus muxing & CRC-32 for each segment
        for seg in segments {
            let ogg = seg.oggOpusData()
            let pages = try parseOggPages(ogg)
            XCTAssertGreaterThanOrEqual(pages.count, 3)
            XCTAssertTrue(pages.allSatisfy(\.validCRC))
            XCTAssertEqual(pages[0].flags, 0x02) // BOS
            XCTAssertTrue(pages[0].body.starts(with: Array("OpusHead".utf8)))
            XCTAssertTrue(pages[1].body.starts(with: Array("OpusTags".utf8)))
            XCTAssertEqual(pages.last?.flags, 0x04) // EOS
            XCTAssertFalse(pages[2].body.isEmpty)
        }
    }

    func testAudioVADslicerMidpointSplitPreventsPaddingOverlap() throws {
        // Long padding (200 ms = 10 frames) with silence gap of 10 frames:
        // [0..6) voiced, [6..16) silence, [16..22) voiced -> mid = (6 + 16) / 2 = 11
        let slicer = AudioVADslicer(
            rmsThreshold: 0.1,
            minSpeechMs: 100,       // 5 frames
            minSilenceSplitMs: 200, // 10 frames
            paddingMs: 200          // 10 frames
        )
        let raw = makeRawOpus(frameCount: 24)
        let segments = try slicer.slice(rawOpus: raw) { idx, _ in
            ((0..<6).contains(idx) || (16..<22).contains(idx)) ? 0.5 : 0.0
        }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].startMs, 0)
        XCTAssertEqual(segments[0].endMs, 11 * 20)
        XCTAssertEqual(segments[1].startMs, 11 * 20)
        XCTAssertEqual(segments[1].endMs, 24 * 20)
    }

    func testAudioVADslicerCalculateRMS() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples[0] = 0.5
        samples[1] = -0.5
        samples[2] = 0.5
        samples[3] = -0.5
        XCTAssertEqual(AudioVADslicer.calculateRMS(buffer), 0.5, accuracy: 0.0001)

        let zeroBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        zeroBuffer.frameLength = 0
        XCTAssertEqual(AudioVADslicer.calculateRMS(zeroBuffer), 0)
    }

    // MARK: - 5. WorkbenchArchive CRUD, Category Filtering, Traversal & Search

    func testWorkbenchArchiveCRUDCategoryFilteringAndPersistence() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let archive = WorkbenchArchive(rootDirectoryURL: dir)
        let segA = VoiceSegment(startMs: 0, endMs: 400, peakRMS: 0.4, opusFrames: makeRawOpus(frameCount: 20), userMarked: true)
        let segB = VoiceSegment(startMs: 800, endMs: 1200, peakRMS: 0.5, opusFrames: makeRawOpus(frameCount: 20), userMarked: true)

        let tOld = Date(timeIntervalSince1970: 1_700_000_000)
        let tNew = Date(timeIntervalSince1970: 1_700_000_500)

        let ideaItem = try archive.archiveRecording(
            fileId: 101,
            createdAt: tOld,
            durationMs: 2000,
            userMarked: true, // defaults to .ideaInbox
            title: "灵感：优化蓝牙断线重连",
            voiceSegments: [
                (segA, "第一步先加上指数退避"),
                (segB, "第二步加上睡眠唤醒恢复")
            ]
        )
        XCTAssertEqual(ideaItem.category, .ideaInbox)

        let playbackSeg = VoiceSegment(startMs: 100, endMs: 500, peakRMS: 0.3, opusFrames: makeRawOpus(frameCount: 20), userMarked: false)
        let playbackItem = try archive.archiveRecording(
            fileId: 102,
            createdAt: tNew,
            durationMs: 1500,
            userMarked: false, // defaults to .playback
            title: "周会回放",
            voiceSegments: [
                (playbackSeg, "本周完成 Swift 语音路由改造")
            ]
        )
        XCTAssertEqual(playbackItem.category, .playback)

        // Permissions check (0o700 dirs, 0o600 index & audio files)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: archive.audioDirectoryURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: archive.indexFileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let firstSegURL = try XCTUnwrap(archive.audioURL(for: ideaItem.segments[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstSegURL.path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: firstSegURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let oggBytes = Array(try Data(contentsOf: firstSegURL))
        XCTAssertEqual(Array(oggBytes.prefix(4)), Array("OggS".utf8))

        // List & filter
        XCTAssertEqual(try archive.items().map(\.id), [playbackItem.id, ideaItem.id])
        XCTAssertEqual(try archive.items(category: .ideaInbox).map(\.id), [ideaItem.id])
        XCTAssertEqual(try archive.items(category: .playback).map(\.id), [playbackItem.id])
        XCTAssertEqual(try archive.item(id: ideaItem.id)?.title, ideaItem.title)
        XCTAssertNil(try archive.item(id: UUID()))

        // Update category & transcript
        try archive.updateCategory(id: playbackItem.id, category: .ideaInbox)
        try archive.updateSegmentTranscript(
            itemID: ideaItem.id,
            segmentID: ideaItem.segments[0].id,
            transcript: "第一步先实现 ReconnectPolicy 指数退避"
        )

        // Reload from fresh instance
        let reloaded = WorkbenchArchive(rootDirectoryURL: dir)
        XCTAssertEqual(try reloaded.items(category: .ideaInbox).count, 2)
        XCTAssertTrue(try reloaded.items(category: .playback).isEmpty)
        XCTAssertEqual(
            try reloaded.item(id: ideaItem.id)?.segments[0].transcript,
            "第一步先实现 ReconnectPolicy 指数退避"
        )

        // Delete removes item and cleans up .ogg audio files
        let secondSegURL = try XCTUnwrap(reloaded.audioURL(for: ideaItem.segments[1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSegURL.path))
        try reloaded.delete(id: ideaItem.id)
        XCTAssertNil(try reloaded.item(id: ideaItem.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstSegURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondSegURL.path))
        XCTAssertEqual(try WorkbenchArchive(rootDirectoryURL: dir).items().map(\.id), [playbackItem.id])
    }

    func testWorkbenchArchiveAudioFileNameTraversalProtection() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = WorkbenchArchive(rootDirectoryURL: dir)

        let maliciousNames = [
            "../outside.ogg",
            "../../etc/passwd.ogg",
            "subdir/clip.ogg",
            "subdir\\clip.ogg",
            "..",
            ".",
            "",
            "   ",
            "bad..name.ogg"
        ]
        for badName in maliciousNames {
            let seg = ArchivedSegment(startMs: 0, endMs: 100, transcript: "t", audioFileName: badName)
            XCTAssertNil(archive.audioURL(for: seg), "Expected nil for malicious file name: \(badName)")
        }

        // Saving with malicious preferred file name or non-.ogg extension falls back to safe UUID-based .ogg inside audioDirectoryURL
        let itemID = UUID()
        let seg1ID = UUID()
        let seg2ID = UUID()
        let seg3ID = UUID()
        let item = WorkbenchItem(
            id: itemID,
            fileId: 500,
            durationMs: 600,
            userMarked: false,
            title: "Path Hygiene",
            segments: [
                ArchivedSegment(id: seg1ID, startMs: 0, endMs: 200, transcript: "a", audioFileName: "../../escape.ogg"),
                ArchivedSegment(id: seg2ID, startMs: 200, endMs: 400, transcript: "b", audioFileName: "not-ogg.txt"),
                ArchivedSegment(id: seg3ID, startMs: 400, endMs: 600, transcript: "c", audioFileName: "../no-data.ogg")
            ]
        )

        let saved = try archive.save(item, segmentAudioData: [
            seg1ID: Data("ogg1".utf8),
            seg2ID: Data("ogg2".utf8)
        ])

        XCTAssertEqual(saved.segments[0].audioFileName, "\(itemID.uuidString)-\(seg1ID.uuidString).ogg")
        XCTAssertEqual(saved.segments[1].audioFileName, "\(itemID.uuidString)-\(seg2ID.uuidString).ogg")
        XCTAssertNil(saved.segments[2].audioFileName)

        let outsideFile = dir.deletingLastPathComponent().appendingPathComponent("escape.ogg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideFile.path))

        let savedURL1 = try XCTUnwrap(archive.audioURL(for: saved.segments[0]))
        XCTAssertEqual(savedURL1.deletingLastPathComponent().standardizedFileURL, archive.audioDirectoryURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: savedURL1), Data("ogg1".utf8))
    }

    func testWorkbenchArchiveMultiKeywordSearchAndCategoryFiltering() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = WorkbenchArchive(rootDirectoryURL: dir)

        let item1 = WorkbenchItem(
            fileId: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            durationMs: 2000,
            userMarked: true,
            category: .ideaInbox,
            title: "Swift BLE 架构想法",
            segments: [
                ArchivedSegment(
                    startMs: 120,
                    endMs: 640,
                    transcript: "建议给 ReconnectCoordinator 增加睡眠唤醒后的指数退避重试逻辑"
                ),
                ArchivedSegment(
                    startMs: 900,
                    endMs: 1400,
                    transcript: "另一段只谈录音豆电量显示"
                )
            ]
        )
        let item2 = WorkbenchItem(
            fileId: 2,
            createdAt: Date(timeIntervalSince1970: 200),
            durationMs: 1500,
            userMarked: false,
            category: .playback,
            title: "日常复盘",
            segments: [
                ArchivedSegment(
                    startMs: 40,
                    endMs: 480,
                    transcript: "今天测试了 swift ble 断线后自动重连"
                )
            ]
        )
        try archive.save(item1)
        try archive.save(item2)

        // Blank query returns empty
        XCTAssertTrue(try archive.search(query: "   \n\t ").isEmpty)

        // Multi-keyword case-insensitive search combining title ("Swift BLE") + transcript ("指数退避")
        let ideaHits = try archive.search(query: "swift 指数退避")
        XCTAssertEqual(ideaHits.count, 1)
        let hit = try XCTUnwrap(ideaHits.first)
        XCTAssertEqual(hit.item.id, item1.id)
        XCTAssertEqual(hit.segment.id, item1.segments[0].id)
        XCTAssertEqual(hit.startMs, 120)
        XCTAssertEqual(hit.endMs, 640)
        XCTAssertEqual(Set(hit.matchedKeywords.map { $0.lowercased() }), Set(["swift", "指数退避"]))
        XCTAssertTrue(hit.excerpt.contains("指数退避"))

        // Cross-category search vs category-scoped search
        let allBLEHits = try archive.search(query: "swift ble")
        XCTAssertEqual(allBLEHits.count, 3) // item2 segment 0 + item1 segment 0 & 1 (all share item1 title "Swift BLE")

        let playbackOnly = try archive.search(query: "swift ble", category: .playback)
        XCTAssertEqual(playbackOnly.count, 1)
        XCTAssertEqual(playbackOnly.first?.item.id, item2.id)

        let inboxOnly = try archive.search(query: "唤醒", category: .ideaInbox)
        XCTAssertEqual(inboxOnly.count, 1)
        XCTAssertEqual(inboxOnly.first?.item.id, item1.id)
        XCTAssertTrue(try archive.search(query: "重连", category: .ideaInbox).isEmpty)
    }

    func testFirmware0492BitMaskCompatibilityAndVADSlicedSearchTimestampIndex() throws {
        // Verify all 8 single-bit flag values: only bit 0 (0x01) marks user tap
        for bit in 0..<8 {
            let flag = UInt8(1 << bit)
            let slice = Slice(seq: UInt32(bit), data: [UInt8](repeating: 0xFC, count: 160), flags: flag)
            XCTAssertEqual(slice.isUserMark, bit == 0, "Unexpected isUserMark for bit \(bit)")
        }

        // End-to-end VAD slicing -> WorkbenchArchive -> timestamp-indexed search
        let slicer = AudioVADslicer(
            rmsThreshold: 0.1,
            minSpeechMs: 100,
            minSilenceSplitMs: 200,
            paddingMs: 20
        )
        let totalFrames = 36
        let raw = makeRawOpus(frameCount: totalFrames)
        let segments = try slicer.slice(rawOpus: raw, userMarked: true) { idx, _ in
            if (3..<9).contains(idx) || (21..<28).contains(idx) { return 0.5 }
            return 0.0
        }
        XCTAssertEqual(segments.count, 2)

        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = WorkbenchArchive(rootDirectoryURL: dir)
        let saved = try archive.archiveRecording(
            fileId: 888,
            durationMs: UInt32(totalFrames * 20),
            userMarked: true,
            title: "04.92 轻敲灵感",
            voiceSegments: [
                (segments[0], "第一段讨论 音频切片 权限"),
                (segments[1], "第二段讨论 搜索时间戳 定位")
            ]
        )
        XCTAssertEqual(saved.category, .ideaInbox)

        let hits = try archive.search(query: "定位 搜索时间戳", category: .ideaInbox)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].startMs, segments[1].startMs)
        XCTAssertEqual(hits[0].endMs, segments[1].endMs)
        XCTAssertEqual(hits[0].startMs, 20 * 20)
        XCTAssertEqual(hits[0].endMs, 29 * 20)
        let audioFile = try XCTUnwrap(archive.audioURL(for: hits[0].segment))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile.path))
    }
}
