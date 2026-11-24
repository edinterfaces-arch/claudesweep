import XCTest
@testable import SweepCore

final class SafetyTests: XCTestCase {
    private var fixture: URL!
    private var home: URL!

    override func setUpWithError() throws {
        // Resolve /var -> /private/var on macOS before testing the no-symlink policy.
        fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-sweep-tests-" + UUID().uuidString)
        home = fixture.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Only this test-owned UUID directory is removed. No real Claude paths or Keychain calls.
        if let fixture { try FileManager.default.removeItem(at: fixture) }
    }

    private func write(_ path: String, _ text: String = "{}") throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEmptyHomeDoesNotScanRealSharedApplications() {
        XCTAssertTrue(Scanner(home: home, includeSharedApplication: false).scan().files.isEmpty)
    }

    func testKnownDataFoundAndUnrelatedDataUntouched() throws {
        let known = try write(".claude.json")
        let unrelated = try write("Documents/important.json", "must survive")
        let inventory = Scanner(home: home, includeSharedApplication: false).scan()
        XCTAssertEqual(inventory.files.map(\.url), [known])
        XCTAssertEqual(try String(contentsOf: unrelated), "must survive")
    }

    func testSymlinkedProfileRejected() throws {
        let outside = fixture.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: outside)
        let inventory = Scanner(home: home, includeSharedApplication: false).scan()
        XCTAssertTrue(inventory.files.isEmpty)
        XCTAssertFalse(inventory.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSymlinkedAncestorRejected() throws {
        let outside = fixture.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("Application Support/Claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library"), withDestinationURL: outside)
        let inventory = Scanner(home: home, includeSharedApplication: false).scan()
        XCTAssertFalse(inventory.files.contains { $0.group == .desktop })
        XCTAssertFalse(inventory.warnings.isEmpty)
    }

    func testReplacementAfterScanRejected() throws {
        let url = try write(".claude.json", "original")
        let candidate = try XCTUnwrap(Scanner(home: home, includeSharedApplication: false).scan().files.first)
        let replacement = try write("replacement.json", "different object")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        XCTAssertThrowsError(try Safety.validate(candidate))
    }

    func testReplacedWithSymlinkRejected() throws {
        let url = try write(".claude.json")
        let candidate = try XCTUnwrap(Scanner(home: home, includeSharedApplication: false).scan().files.first)
        let target = try write("Documents/keep.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try Safety.validate(candidate))
    }

    func testPathBoundariesAndTraversal() {
        XCTAssertFalse(Safety.isInside(URL(fileURLWithPath: "/Users/test-other/file"), anchor: URL(fileURLWithPath: "/Users/test")))
        XCTAssertFalse(Safety.isInside(home.appendingPathComponent("../outside"), anchor: home))
        XCTAssertFalse(Safety.isInside(home, anchor: home))
        XCTAssertTrue(Safety.isInside(home.appendingPathComponent(".claude.json"), anchor: home))
    }

    func testCustomProfileNeverIncludesRootOrUnrelatedChildren() throws {
        let root = home.appendingPathComponent("profiles/claude-work")
        _ = try write("profiles/claude-work/.credentials.json")
        let unrelated = try write("profiles/claude-work/important.txt", "keep")
        let result = Scanner(home: home, customRoots: [root], includeSharedApplication: false).scan()
        XCTAssertEqual(result.files.count, 1)
        XCTAssertFalse(result.files.contains { $0.url == root || $0.url == unrelated })
    }

    func testCustomProfileCannotBeHomeOrOutside() throws {
        XCTAssertThrowsError(try Safety.validateCustomRoot(home, home: home))
        XCTAssertThrowsError(try Safety.validateCustomRoot(fixture, home: home))
        let empty = home.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Safety.validateCustomRoot(empty, home: home))
    }

    func testCustomDefaultProfileDoesNotDuplicateNestedTargets() throws {
        _ = try write(".claude/settings.json")
        _ = try write(".claude/.credentials.json")
        let result = Scanner(home: home, customRoots: [home.appendingPathComponent(".claude")], includeSharedApplication: false).scan()
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.url, home.appendingPathComponent(".claude"))
    }

    func testOnlySettingNamesAppearInInventory() throws {
        _ = try write(".zshrc", "export ANTHROPIC_API_KEY='test-secret-never-display'\nexport CLAUDE_CODE_OAUTH_TOKEN='another-test-secret'")
        let inventory = Scanner(home: home, includeSharedApplication: false).scan()
        let reference = try XCTUnwrap(inventory.references.first)
        XCTAssertEqual(Set(reference.names), Set(["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]))
        XCTAssertFalse(reference.names.joined().contains("secret"))
    }

    func testSettingNameBoundaries() {
        XCTAssertTrue(Safety.referencedSettings(in: "NOT_ANTHROPIC_API_KEY_EXAMPLE=1").isEmpty)
        XCTAssertEqual(Safety.referencedSettings(in: "\"apiKeyHelper\": \"example\""), ["apiKeyHelper"])
    }

    func testCredentialAllowlistIsNarrow() {
        XCTAssertTrue(Safety.allowedKeychainService("Claude Code-credentials"))
        XCTAssertTrue(Safety.allowedKeychainService("Claude Code-credentials-a1b2c3d4"))
        XCTAssertTrue(Safety.allowedKeychainService("Claude Safe Storage"))
        XCTAssertFalse(Safety.allowedKeychainService("Claude Code-credentials-"))
        XCTAssertFalse(Safety.allowedKeychainService("Google Chrome Safe Storage"))
        XCTAssertFalse(Safety.allowedKeychainService("My Claude notes"))
    }

    func testLegacyBackupsAreFoundWithoutMatchingUnrelatedFiles() throws {
        let backup = try write(".claude.json.backup.1234")
        _ = try write(".not-claude.json.backup.1234")
        let result = Scanner(home: home, includeSharedApplication: false).scan()
        XCTAssertEqual(result.files.map(\.url), [backup])
    }
}
