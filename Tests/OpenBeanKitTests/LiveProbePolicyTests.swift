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
