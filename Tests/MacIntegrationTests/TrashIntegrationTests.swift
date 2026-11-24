import XCTest
import Foundation
import Darwin
import SweepCore
@testable import ClaudeSweep

class NativeFixtureTests: XCTestCase {
    var fixture: URL!
    var home: URL!
    var cleanupTrashURLs: [URL] = []
    var children: [Process] = []
    let fm = FileManager.default

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CLAUDESWEEP_RUN_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Opt in on a disposable Mac with CLAUDESWEEP_RUN_INTEGRATION_TESTS=1.")
        }
        fixture = fm.homeDirectoryForCurrentUser.appendingPathComponent("claudesweep-integration-" + UUID().uuidString)
        home = fixture.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for child in children where child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
        // Only exact paths returned by our own trash operations are removed.
        // Never empty Trash or enumerate/remove another app's contents.
        for url in cleanupTrashURLs where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        if let fixture, fm.fileExists(atPath: fixture.path) { try fm.removeItem(at: fixture) }
    }

    @discardableResult
    func write(_ relative: String, data: Data = Data("synthetic-test-data".utf8), under base: URL? = nil) throws -> URL {
        let url = (base ?? home!).appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func candidates(in base: URL? = nil) throws -> [Candidate] {
        let inventory = Scanner(home: base ?? home, includeSharedApplication: false).scan()
        XCTAssertTrue(inventory.warnings.isEmpty, inventory.warnings.joined(separator: "\n"))
        return inventory.files
    }

    func trash(_ items: [Candidate]) -> OperationResult {
        let result = FileCleaner.moveToTrash(items)
        cleanupTrashURLs.append(contentsOf: result.movedItems.compactMap(\.trashURL))
        return result
    }

    func recover(_ result: OperationResult) throws {
        for move in result.movedItems {
            let source = try XCTUnwrap(move.trashURL, "Foundation did not provide a recovery location.")
            XCTAssertFalse(fm.fileExists(atPath: move.originalURL.path))
            // No overwrite: a newly created original path must make recovery fail.
            try fm.moveItem(at: source, to: move.originalURL)
        }
    }

    func startSyntheticClaude() throws -> Process {
        let executable = fixture.appendingPathComponent("bin/claude")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["60"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        children.append(process)
        XCTAssertTrue(process.isRunning)
        return process
    }
}

final class TrashIntegrationTests: NativeFixtureTests {
    func testScanLeavesRealFixtureContentsUnchanged() throws {
        let payload = Data((0..<256).map(UInt8.init))
        let config = try write(".claude.json", data: payload)
        let history = try write(".claude/projects/test/history.jsonl", data: payload)
        let unrelated = try write("Documents/keep.bin", data: payload)
        let items = try candidates()
        XCTAssertEqual(items.count, 2)
        for path in [config, history, unrelated] { XCTAssertEqual(try Data(contentsOf: path), payload) }
    }

    func testProfileMovesToRealTrashAndRecoversByteForByte() throws {
        let payload = Data((0..<256).map(UInt8.init))
        let history = try write(".claude/projects/test/history.jsonl", data: payload)
        let settings = try write(".claude/settings.json", data: Data("{\"test\":true}".utf8))
        let result = trash(try candidates())
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.successfulIDs.count, 1)
        XCTAssertEqual(result.movedItems.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: history.path))
        let moved = try XCTUnwrap(result.movedItems.first?.trashURL)
        XCTAssertTrue(moved.path.contains("/.Trash/"), "Expected the user's real Trash: \(moved.path)")
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("projects/test/history.jsonl")), payload)
        try recover(result)
        XCTAssertEqual(try Data(contentsOf: history), payload)
        XCTAssertEqual(try String(contentsOf: settings), "{\"test\":true}")
    }

    func testSameNameCollisionsKeepBothFilesRecoverable() throws {
        let homeA = fixture.appendingPathComponent("a/home")
        let homeB = fixture.appendingPathComponent("b/home")
        let a = try write(".claude.json", data: Data("first".utf8), under: homeA)
        let b = try write(".claude.json", data: Data("second".utf8), under: homeB)
        let result = trash(try candidates(in: homeA) + candidates(in: homeB))
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.movedItems.count, 2)
        XCTAssertEqual(Set(result.movedItems.compactMap { $0.trashURL?.path }).count, 2)
        try recover(result)
        XCTAssertEqual(try String(contentsOf: a), "first")
        XCTAssertEqual(try String(contentsOf: b), "second")
    }

    func testNestedSymlinkDoesNotMoveItsExternalTarget() throws {
        let external = try write("Documents/keep.txt", data: Data("keep".utf8))
        _ = try write(".claude/settings.json")
        let link = home.appendingPathComponent(".claude/external")
        try fm.createSymbolicLink(at: link, withDestinationURL: external)
        let result = trash(try candidates())
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(try String(contentsOf: external), "keep")
        try recover(result)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), external.path)
    }

    func testReplacedItemIsRejectedByActualCleanup() throws {
        let original = try write(".claude.json", data: Data("original".utf8))
        let items = try candidates()
        try fm.moveItem(at: original, to: home.appendingPathComponent("original.saved"))
        try Data("replacement".utf8).write(to: original)
        let result = trash(items)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.successfulIDs.isEmpty)
        XCTAssertTrue(result.movedItems.isEmpty)
        XCTAssertEqual(try String(contentsOf: original), "replacement")
    }

    func testPartialFailurePreservesSuccessAndStopsBeforeRemainingItems() throws {
        let first = try write(".claude.json", data: Data("first".utf8))
        let second = try write("Library/Logs/Claude/log.txt", data: Data("second".utf8))
        let third = try write("Library/Caches/com.anthropic.claudefordesktop/keep.txt", data: Data("third".utf8))
        let items = try candidates()
        let logFolder = second.deletingLastPathComponent()
        try fm.moveItem(at: logFolder, to: home.appendingPathComponent("saved-logs"))
        _ = try write("Library/Logs/Claude/replacement.txt")
        let result = trash(items)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.successfulIDs, Set([first.path]))
        XCTAssertEqual(result.movedItems.count, 1)
        XCTAssertTrue(result.lines.contains { $0.hasPrefix("STOPPED:") })
        XCTAssertEqual(try String(contentsOf: third), "third")
        try recover(result)
        XCTAssertEqual(try String(contentsOf: first), "first")
    }

    func testPermissionFailureDoesNotClaimSuccess() throws {
        XCTAssertNotEqual(geteuid(), 0, "Permission checks must run as an unprivileged user.")
        let file = try write(".claude.json")
        let items = try candidates()
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path) }
        let result = trash(items)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.successfulIDs.isEmpty)
        XCTAssertTrue(result.movedItems.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }

    func testRunningClaudeBlocksCleanupWithoutChangingFiles() throws {
        let file = try write(".claude.json", data: Data("keep".utf8))
        let items = try candidates()
        _ = try startSyntheticClaude()
        XCTAssertFalse(try ProcessGuard.runningClaude().isEmpty)
        let result = trash(items)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.successfulIDs.isEmpty)
        XCTAssertTrue(result.movedItems.isEmpty)
        XCTAssertEqual(try String(contentsOf: file), "keep")
    }

    func testRecoveryDoesNotOverwriteARecreatedOriginal() throws {
        let file = try write(".claude.json", data: Data("old".utf8))
        let result = trash(try candidates())
        XCTAssertNil(result.error, result.error ?? "")
        let moved = try XCTUnwrap(result.movedItems.first?.trashURL)
        try Data("new".utf8).write(to: file)
        XCTAssertThrowsError(try fm.moveItem(at: moved, to: file))
        XCTAssertEqual(try String(contentsOf: file), "new")
        XCTAssertEqual(try String(contentsOf: moved), "old")
    }
}
