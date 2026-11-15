import Foundation
import XCTest
@testable import VoiceRouting

final class RoutingTests: XCTestCase {
    private let a = "11111111-1111-4111-8111-111111111111"
    private let b = "22222222-2222-4222-8222-222222222222"

    func testAcceptsExactLocalChatLinkAndRejectsAmbiguousDestinations() throws {
        XCTAssertEqual(try ChatLink.threadID("  codex://threads/\(a)\n"), a)
        for link in ["https://example.com/\(a)", "codex://threads/new", "codex://threads/\(a)?remote=host",
                     "codex://threads/\(a)#other", "codex://user@threads/\(a)", "codex://threads:80/\(a)",
                     "codex://threads/\(a)/", "codex://threads/../\(a)", "codex://chat/\(a)", a] {
            XCTAssertThrowsError(try ChatLink.threadID(link), link)
        }
    }

    func testClaimSurvivesRestartAndCannotBeRedirectedOrSentTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingStore(directory: directory)
        let targetA = VoiceTarget(id: a, title: "A")
        let targetB = VoiceTarget(id: b, title: "B")
        let message = PendingMessage(text: "send once", target: targetA, note: "pinned at recording start")
        try store.save(message)
        let claimed = try store.beginSubmission(message.id, target: targetA)
        XCTAssertEqual(claimed.target, targetA)
        XCTAssertEqual(claimed.state, .submitting)
        let restarted = PendingStore(directory: directory)
        XCTAssertThrowsError(try restarted.beginSubmission(message.id, target: targetB))
        XCTAssertEqual(try restarted.messages().first?.target, targetA)
        for state in [PendingMessage.State.queued, .uncertain] {
            var terminal = claimed; terminal.state = state; try store.save(terminal)
            XCTAssertThrowsError(try restarted.beginSubmission(message.id, target: targetA))
        }
    }

    func testUnresolvedTextSurvivesAndCanBeExplicitlyAssigned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingStore(directory: directory)
        let message = PendingMessage(text: "中文、换行\n以及 $(literal)", target: nil, note: "permission missing")
        try store.save(message)
        let restored = try XCTUnwrap(PendingStore(directory: directory).messages().first)
        XCTAssertEqual(restored.text, message.text)
        XCTAssertNil(restored.target)
        let target = VoiceTarget(id: b, title: "Explicit B")
        XCTAssertEqual(try store.beginSubmission(message.id, target: target).target, target)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(message.id.uuidString + ".json").path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testConcurrentClaimsHaveOneWinner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingStore(directory: directory)
        let message = PendingMessage(text: "one", target: nil, note: "")
        try store.save(message)
        let target = VoiceTarget(id: a, title: "A")
        let lock = NSLock()
        var winners = 0
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if (try? store.beginSubmission(message.id, target: target)) != nil {
                lock.lock(); winners += 1; lock.unlock()
            }
        }
        XCTAssertEqual(winners, 1)
    }
}
