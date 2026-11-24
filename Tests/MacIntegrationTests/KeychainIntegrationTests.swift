import XCTest
import Foundation
import Security
@testable import ClaudeSweep

final class KeychainIntegrationTests: NativeFixtureTests {
    private var keychains: [SecKeychain] = []
    private var keychain: SecKeychain!
    private var previousInteraction = DarwinBoolean(true)
    private var changedInteraction = false
    private var originalSearchList: CFArray?
    private let syntheticSecret = Data("DISPOSABLE-INTEGRATION-SECRET".utf8)
    private let disposablePassword = Data(UUID().uuidString.utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        var allowed = DarwinBoolean(true)
        try check(SecKeychainGetUserInteractionAllowed(&allowed))
        previousInteraction = allowed
        try check(SecKeychainSetUserInteractionAllowed(false))
        changedInteraction = true
        try check(SecKeychainCopySearchList(&originalSearchList))
        keychain = try makeKeychain("isolated")
    }

    override func tearDownWithError() throws {
        // Delete only explicitly created disposable keychains. Never reset login.
        for item in keychains { XCTAssertEqual(SecKeychainDelete(item), errSecSuccess) }
        if let originalSearchList { XCTAssertEqual(SecKeychainSetSearchList(originalSearchList), errSecSuccess) }
        if changedInteraction { XCTAssertEqual(SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue), errSecSuccess) }
        try super.tearDownWithError()
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func makeKeychain(_ name: String) throws -> SecKeychain {
        let path = fixture.appendingPathComponent(name + ".keychain-db").path
        let password = disposablePassword
        var created: SecKeychain?
        let status = password.withUnsafeBytes {
            SecKeychainCreate(path, UInt32(password.count), $0.baseAddress, false, nil, &created)
        }
        try check(status)
        let item = try XCTUnwrap(created)
        keychains.append(item)
        try check(password.withUnsafeBytes { SecKeychainUnlock(item, UInt32(password.count), $0.baseAddress, true) })
        // Creating a keychain may add it to the search list; restore immediately.
        // Every test query selects its disposable keychain explicitly.
        if let originalSearchList { try check(SecKeychainSetSearchList(originalSearchList)) }
        return item
    }

    @discardableResult
    private func insert(_ service: String, account: String = "synthetic-account", into target: SecKeychain? = nil) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseKeychain as String: target ?? keychain!,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: syntheticSecret,
            kSecReturnPersistentRef as String: true
        ]
        var result: CFTypeRef?
        try check(SecItemAdd(query as CFDictionary, &result))
        return try XCTUnwrap(result as? Data)
    }

    private func contains(_ service: String, account: String = "synthetic-account", in target: SecKeychain? = nil) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchSearchList as String: [target ?? keychain!],
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    private func readyScan(in target: SecKeychain) throws -> [Credential] {
        // The production guard requires a snapshot made at least two seconds
        // after creation/modification because keychain dates have second precision.
        Thread.sleep(forTimeInterval: 2.1)
        return try KeychainService.scan(in: target)
    }

    func testFreshCredentialRequiresNewScanAfterQuietInterval() throws {
        let service = "Claude Code-credentials-fixture"
        try insert(service)
        let fresh = try XCTUnwrap(KeychainService.scan(in: keychain).first)
        XCTAssertThrowsError(try KeychainService.delete(fresh, in: keychain))
        XCTAssertTrue(try contains(service))
        // Waiting without rescanning must not authorize the old snapshot.
        Thread.sleep(forTimeInterval: 2.1)
        XCTAssertThrowsError(try KeychainService.delete(fresh, in: keychain))
        let rescanned = try XCTUnwrap(KeychainService.scan(in: keychain).first)
        try KeychainService.delete(rescanned, in: keychain)
        XCTAssertFalse(try contains(service))
    }

    func testInPlaceCredentialUpdateAfterScanIsRejected() throws {
        let service = "Claude Code-credentials-fixture"
        try insert(service)
        let item = try XCTUnwrap(readyScan(in: keychain).first)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchSearchList as String: [keychain!],
            kSecAttrService as String: service,
            kSecAttrAccount as String: "synthetic-account"
        ]
        let changes: [String: Any] = [kSecValueData as String: Data("REPLACEMENT-SYNTHETIC-SECRET".utf8)]
        try check(SecItemUpdate(query as CFDictionary, changes as CFDictionary))
        XCTAssertThrowsError(try KeychainService.delete(item, in: keychain))
        XCTAssertTrue(try contains(service))
    }

    func testMetadataScanFiltersUnrelatedEntriesAndExcludesSecretValues() throws {
        try insert("Claude Code-credentials-fixture")
        try insert("Claude Safe Storage")
        try insert("Unrelated synthetic service")
        let rows = try readyScan(in: keychain)
        XCTAssertEqual(Set(rows.map(\.service)), Set(["Claude Code-credentials-fixture", "Claude Safe Storage"]))
        XCTAssertTrue(rows.allSatisfy { !$0.reference.isEmpty })
        XCTAssertFalse(String(reflecting: rows).contains("DISPOSABLE-INTEGRATION-SECRET"))
        XCTAssertTrue(try contains("Unrelated synthetic service"))
    }

    func testDeletingSelectedReferencePreservesOtherAccountsAndUnrelatedEntries() throws {
        let service = "Claude Code-credentials-fixture"
        try insert(service, account: "selected")
        try insert(service, account: "keep")
        try insert("Unrelated synthetic service")
        let selected = try XCTUnwrap(readyScan(in: keychain).first { $0.account == "selected" })
        try KeychainService.delete(selected, in: keychain)
        XCTAssertFalse(try contains(service, account: "selected"))
        XCTAssertTrue(try contains(service, account: "keep"))
        XCTAssertTrue(try contains("Unrelated synthetic service"))
        XCTAssertEqual(try readyScan(in: keychain).count, 1)
    }

    func testIdentityMismatchCannotDeleteCredential() throws {
        let service = "Claude Code-credentials-fixture"
        try insert(service)
        let original = try XCTUnwrap(readyScan(in: keychain).first)
        let wrong = Credential(reference: original.reference, service: service,
                               account: "wrong-account", createdAt: original.createdAt,
                               modifiedAt: original.modifiedAt, scannedAt: original.scannedAt)
        XCTAssertThrowsError(try KeychainService.delete(wrong, in: keychain))
        XCTAssertTrue(try contains(service))
    }

    func testUnrecognizedServiceCannotBeDeletedEvenWithValidReference() throws {
        let service = "Unrelated synthetic service"
        let reference = try insert(service)
        let item = Credential(reference: reference, service: service, account: "synthetic-account")
        XCTAssertThrowsError(try KeychainService.delete(item, in: keychain))
        XCTAssertTrue(try contains(service))
    }

    func testStaleReferenceDoesNotDeleteReplacement() throws {
        let service = "Claude Code-credentials-fixture"
        try insert(service)
        let original = try XCTUnwrap(readyScan(in: keychain).first)
        try KeychainService.delete(original, in: keychain)
        // Persistent references can legitimately be reused for identical primary
        // attributes. The deletion must validate the scanned metadata instead.
        try insert(service)
        XCTAssertThrowsError(try KeychainService.delete(original, in: keychain))
        XCTAssertTrue(try contains(service))
    }

    func testSameNamesInAnotherKeychainRemainUntouched() throws {
        let service = "Claude Code-credentials-fixture"
        let other = try makeKeychain("other")
        try insert(service)
        try insert(service, into: other)
        let selected = try XCTUnwrap(readyScan(in: keychain).first)
        try KeychainService.delete(selected, in: keychain)
        XCTAssertFalse(try contains(service))
        XCTAssertTrue(try contains(service, in: other))
    }

    func testExternalReplacementIsRejectedAfterScan() throws {
        let service = "Claude Code-credentials-fixture"
        try insert(service)
        let original = try XCTUnwrap(readyScan(in: keychain).first)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // The last argument explicitly limits the command to our UUID-owned
        // disposable keychain. No password, login keychain or search-list query.
        task.arguments = ["delete-generic-password", "-s", service, "-a", "synthetic-account",
                          fixture.appendingPathComponent("isolated.keychain-db").path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        try insert(service)
        XCTAssertThrowsError(try KeychainService.delete(original, in: keychain))
        XCTAssertTrue(try contains(service))
    }

    func testReferenceFromAnotherKeychainIsRejected() throws {
        let other = try makeKeychain("other")
        let service = "Claude Code-credentials-fixture"
        try insert(service, into: other)
        let item = try XCTUnwrap(readyScan(in: other).first)
        XCTAssertThrowsError(try KeychainService.delete(item, in: keychain))
        XCTAssertTrue(try contains(service, in: other))
    }

    func testRunningClaudeBlocksCredentialDeletion() throws {
        let service = "Claude Code-credentials-fixture"
        try insert(service)
        let item = try XCTUnwrap(readyScan(in: keychain).first)
        _ = try startSyntheticClaude()
        XCTAssertThrowsError(try KeychainService.delete(item, in: keychain))
        XCTAssertTrue(try contains(service))
    }

    func testLockedKeychainRefusesDeletionWithoutPrompt() throws {
        let service = "Claude Code-credentials-fixture"
        try insert(service)
        let item = try XCTUnwrap(readyScan(in: keychain).first)
        try check(SecKeychainLock(keychain))
        XCTAssertThrowsError(try KeychainService.delete(item, in: keychain))
        try check(disposablePassword.withUnsafeBytes {
            SecKeychainUnlock(keychain, UInt32(disposablePassword.count), $0.baseAddress, true)
        })
        XCTAssertTrue(try contains(service))
    }
}
