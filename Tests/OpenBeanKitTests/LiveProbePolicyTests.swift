import XCTest
@testable import OpenBeanKit

final class LiveProbePolicyTests: XCTestCase {
    func testStartsOnlyWhenRecorderIsKnownToBeIdle() {
        XCTAssertTrue(LiveProbePolicy.mayStart(recording: false))
        XCTAssertFalse(LiveProbePolicy.mayStart(recording: true))
        XCTAssertFalse(LiveProbePolicy.mayStart(recording: nil))
    }

    func testOnlySelectsOneNewRecording() {
        let before: Set<UInt32> = [1, 2]
        XCTAssertEqual(LiveProbePolicy.uniqueNewFile(before: before, after: [1, 2, 3]), 3)
        XCTAssertNil(LiveProbePolicy.uniqueNewFile(before: before, after: [1, 2]))
        XCTAssertNil(LiveProbePolicy.uniqueNewFile(before: before, after: [1, 2, 3, 4]))
    }

    func testTapFlagIsDistinctFromOrdinaryAndStopFrames() {
        func slice(_ flags: UInt8, sequence: UInt32) -> [UInt8] {
            u32le(sequence) + [flags] + Array(repeating: UInt8(0xAA), count: 160) + [0]
        }
        let raw = [UInt8](repeating: 0, count: 9) + slice(0, sequence: 1)
            + slice(1, sequence: 2) + slice(4, sequence: 3) + [0]
        let parsed = parseSlices(frame: raw)
        XCTAssertEqual(parsed.map(\.seq), [1, 2, 3])
        XCTAssertEqual(parsed.map(\.isUserMark), [false, true, false])
        XCTAssertTrue(parsed.allSatisfy { $0.data == Array(repeating: 0xAA, count: 160) })
        XCTAssertTrue(parseSlices(frame: Array(raw.prefix(100))).isEmpty)
    }

    func testRecorderStartAndStopNotifications() {
        let started = Packet(raw: [0x09, 0xff, 0, 0, 1, 0x1a, 0x06, 14, 0, 42, 0, 0, 0, 0])
        let stopped = Packet(raw: [0x09, 0xff, 0, 0, 1, 0x18, 0x82, 11, 0, 0, 0])
        guard case let .recordingStarted(fileID) = DeviceEvent(packet: started) else {
            return XCTFail("Expected a recording-start event")
        }
        XCTAssertEqual(fileID, 42)
        guard case .recordingStopped = DeviceEvent(packet: stopped) else {
            return XCTFail("Expected a recording-stop event")
        }
    }
}
