import XCTest
@testable import OpenBeanKit

final class ToolLocatorTests: XCTestCase {
    func testExplicitOverrideAndPathSearch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("example-tool")
        XCTAssertTrue(FileManager.default.createFile(atPath: binary.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertEqual(ToolLocator.resolve(name: "example-tool", override: nil, searchPath: dir.path), binary.path)
        XCTAssertEqual(ToolLocator.resolve(name: "other", override: binary.path), binary.path)
        XCTAssertNil(ToolLocator.resolve(name: "example-tool", override: "/does/not/exist", searchPath: dir.path))
    }
}
