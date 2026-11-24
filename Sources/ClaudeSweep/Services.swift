import AppKit
import Combine
import Security
import SweepCore

struct Credential: Identifiable {
    let reference: Data
    let service: String
    let account: String
    var id: String { reference.base64EncodedString() }
}

enum ProcessGuard {
    static func runningClaude() throws -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ww", "-axo", "pid=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            throw SweepError.message("Could not check running processes. Cleanup was stopped.")
        }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let name = URL(fileURLWithPath: path).lastPathComponent
            let isClaude = path.contains("/Claude.app/") || path.contains("/Application Support/Claude/") ||
                ["claude", "claude-code"].contains(name)
            return isClaude ? "\(name) (PID \(parts[0]))" : nil
        }
    }

    static func requireStopped() throws {
        let running = try runningClaude()
        guard running.isEmpty else {
            throw SweepError.message("Quit Claude Desktop, Claude Code sessions and editors running Claude, then retry. Still running: " + running.joined(separator: ", "))
        }
    }
}

enum KeychainService {
    private static func loginKeychain() throws -> SecKeychain {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else { throw error(status) }
        return keychain
    }

    static func scan() throws -> [Credential] {
        try scan(in: loginKeychain())
    }

    // The app always uses loginKeychain(). Integration tests supply a disposable
    // keychain so they exercise these same SecItem operations without real secrets.
    static func scan(in keychain: SecKeychain) throws -> [Credential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw error(status) }
        guard let rows = result as? [[String: Any]] else {
            throw SweepError.message("Keychain returned an unexpected result. No credentials were changed.")
        }
        return rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String,
                  Safety.allowedKeychainService(service),
                  let reference = row[kSecValuePersistentRef as String] as? Data else { return nil }
            return Credential(reference: reference, service: service,
                              account: row[kSecAttrAccount as String] as? String ?? "Unnamed account")
        }.sorted { $0.service < $1.service }
    }

    static func delete(_ credential: Credential) throws {
        try delete(credential, in: loginKeychain())
    }

    static func delete(_ credential: Credential, in keychain: SecKeychain) throws {
        try ProcessGuard.requireStopped()
        guard Safety.allowedKeychainService(credential.service) else {
            throw SweepError.message("Credential service is outside the allowlist.")
        }
        // Re-read this exact item before deletion. Never delete with a name wildcard.
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchSearchList as String: [keychain],
            kSecMatchItemList as String: [credential.reference],
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(identityQuery as CFDictionary, &result)
        guard status == errSecSuccess else { throw error(status) }
        guard let row = result as? [String: Any],
              row[kSecAttrService as String] as? String == credential.service,
              (row[kSecAttrAccount as String] as? String ?? "Unnamed account") == credential.account else {
            throw SweepError.message("Credential changed after the scan. Scan again.")
        }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchSearchList as String: [keychain],
            kSecMatchItemList as String: [credential.reference]
        ]
        let deletion = SecItemDelete(deleteQuery as CFDictionary)
        guard deletion == errSecSuccess else { throw error(deletion) }
    }

    private static func error(_ status: OSStatus) -> SweepError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .message("Keychain: \(message)")
    }
}

struct TrashedItem {
    let originalURL: URL
    let trashURL: URL?
}

struct OperationResult {
    var lines: [String] = []
    var error: String?
    var successfulIDs: Set<String> = []
    var movedItems: [TrashedItem] = []
}

enum FileCleaner {
    static func moveToTrash(_ candidates: [Candidate]) -> OperationResult {
        var result = OperationResult()
        do { try ProcessGuard.requireStopped() }
        catch { result.error = error.localizedDescription; return result }
        for candidate in Safety.outermost(candidates) {
            do {
                try ProcessGuard.requireStopped()
                try Safety.validate(candidate)
                var trashed: NSURL?
                try FileManager.default.trashItem(at: candidate.url, resultingItemURL: &trashed)
                result.successfulIDs.insert(candidate.id)
                result.movedItems.append(TrashedItem(originalURL: candidate.url, trashURL: trashed.map { $0 as URL }))
                result.lines.append("MOVED TO TRASH: \(candidate.url.path)\n  Trash location: \(trashed?.path ?? "Open Finder Trash")")
            } catch {
                result.lines.append("STOPPED: \(candidate.url.path) — \(error.localizedDescription)")
                result.error = error.localizedDescription
                break // preserve a reviewable partial result; don't continue after an unexpected failure
            }
        }
        return result
    }
}

@MainActor
final class SweepModel: ObservableObject {
    @Published var inventory = Inventory()
    @Published var selectedFiles: Set<String> = []
    @Published var credentials: [Credential] = []
    @Published var selectedKeys: Set<String> = []
    @Published var customRoots: [URL] = []
    @Published var busy = false
    @Published var didScan = false
    @Published var didScanKeys = false
    @Published var message: String?
    @Published var log: [String] = []
    @Published var lastScan: Date?

    var chosenFiles: [Candidate] { inventory.files.filter { selectedFiles.contains($0.id) } }
    var chosenKeys: [Credential] { credentials.filter { selectedKeys.contains($0.id) } }
    var selectedSize: Int64 { Safety.outermost(chosenFiles).reduce(0) { $0 + $1.bytes } }

    func scan() {
        guard !busy else { return }
        busy = true
        selectedFiles = []
        let roots = customRoots
        Task {
            let result = await Task.detached(priority: .userInitiated) { Scanner(customRoots: roots).scan() }.value
            inventory = result
            didScan = true
            lastScan = Date()
            log.append("SCAN: \(Date().formatted()) — \(result.files.count) file targets; \(result.warnings.count) scan warnings.")
            busy = false
        }
    }

    func addProfile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a dedicated Claude Code profile"
        panel.message = "Use a folder you configured with CLAUDE_CONFIG_DIR. Only known Claude children are offered for cleanup."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Safety.validateCustomRoot(url, home: FileManager.default.homeDirectoryForCurrentUser)
            if !customRoots.contains(url) { customRoots.append(url) }
            scan()
        } catch { message = error.localizedDescription }
    }

    func cleanFiles() {
        guard !busy, !chosenFiles.isEmpty else { return }
        let items = chosenFiles
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { FileCleaner.moveToTrash(items) }.value
            log.append(contentsOf: result.lines)
            if let error = result.error { message = error; log.append("CLEANUP STOPPED: \(error)") }
            inventory.files.removeAll { result.successfulIDs.contains($0.id) }
            selectedFiles.subtract(result.successfulIDs)
            busy = false
            if result.error == nil {
                message = "Moved \(result.successfulIDs.count) items to Trash. Browser data, remaining credentials and manual checks are separate. Rescan after completing those steps."
            }
        }
    }

    func scanKeys() {
        guard !busy else { return }
        busy = true
        selectedKeys = []
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[Credential], Error> in
                Result { try KeychainService.scan() }
            }.value
            switch result {
            case .success(let items):
                credentials = items; didScanKeys = true
                log.append("KEYCHAIN SCAN: \(items.count) matching generic-password entries in the login keychain. Secret values were not requested.")
            case .failure(let error): message = error.localizedDescription
            }
            busy = false
        }
    }

    func deleteKeys() {
        guard !busy, !chosenKeys.isEmpty else { return }
        let items = chosenKeys
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> OperationResult in
                var result = OperationResult()
                for item in items {
                    do {
                        try ProcessGuard.requireStopped()
                        try KeychainService.delete(item)
                        result.successfulIDs.insert(item.id)
                        result.lines.append("DELETED KEYCHAIN ENTRY: \(item.service)")
                    } catch {
                        result.error = error.localizedDescription
                        result.lines.append("KEYCHAIN RESET STOPPED: \(error.localizedDescription)")
                        break
                    }
                }
                return result
            }.value
            log.append(contentsOf: result.lines)
            credentials.removeAll { result.successfulIDs.contains($0.id) }
            selectedKeys.subtract(result.successfulIDs)
            busy = false
            message = result.error ?? "Deleted \(result.successfulIDs.count) selected Keychain entries. Those sign-ins or encryption keys cannot be restored by this app."
        }
    }

    func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClaudeSweep-report.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = (["Claude Sweep — local action report", Date().formatted(),
            "Scope: known local paths and selected login-keychain entries. Browser and manual checks are not verified.",
            "Does not verify server-side deletion or account unlinking. Paths can contain your Mac username.", ""] + log +
            ["", "Latest file-scan warnings:"] + inventory.warnings).joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { message = error.localizedDescription }
    }
}
