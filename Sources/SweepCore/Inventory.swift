import Foundation

public enum DataGroup: String, CaseIterable, Identifiable {
    case cache = "Caches & logs"
    case desktop = "Desktop data"
    case code = "Code profiles"
    case application = "Applications"
    public var id: String { rawValue }
}

public struct FileIdentity: Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let kind: FileAttributeType

    public static func read(_ url: URL) throws -> FileIdentity {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let kind = attrs[.type] as? FileAttributeType else {
            throw SweepError.message("Could not establish file identity: \(url.lastPathComponent)")
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value, kind: kind)
    }
}

public enum SweepError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct Candidate: Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let anchor: URL
    public let title: String
    public let detail: String
    public let group: DataGroup
    public let identity: FileIdentity
    public let bytes: Int64
    public let approximate: Bool
}

public struct SettingReference: Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let names: [String]
}

public struct Inventory {
    public var files: [Candidate] = []
    public var references: [SettingReference] = []
    public var warnings: [String] = []
    public init() {}
}

public enum Safety {
    public static func isInside(_ url: URL, anchor: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = anchor.standardizedFileURL.path
        return path.hasPrefix(root == "/" ? "/" : root + "/") && path != root
    }

    // Check the object and every ancestor. Never redirect a cleanup through a symlink.
    public static func checkPath(_ url: URL, anchor: URL) throws {
        guard isInside(url, anchor: anchor), anchor.path != "/" else {
            throw SweepError.message("Refused a path outside its approved folder.")
        }
        var cursor = url.standardizedFileURL
        while cursor.path != "/" {
            let identity = try FileIdentity.read(cursor)
            if identity.kind == .typeSymbolicLink {
                throw SweepError.message("Symbolic link skipped: \(cursor.path)")
            }
            cursor.deleteLastPathComponent()
        }
    }

    public static func validate(_ candidate: Candidate) throws {
        try checkPath(candidate.url, anchor: candidate.anchor)
        guard try FileIdentity.read(candidate.url) == candidate.identity else {
            throw SweepError.message("This item was replaced after the scan. Scan again: \(candidate.title)")
        }
    }

    public static func outermost(_ candidates: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        for item in candidates.sorted(by: { $0.url.path.count < $1.url.path.count }) {
            if !kept.contains(where: { $0.url == item.url || isInside(item.url, anchor: $0.url) }) {
                kept.append(item)
            }
        }
        return kept
    }

    public static func validateCustomRoot(_ url: URL, home: URL) throws {
        let root = url.standardizedFileURL
        guard isInside(root, anchor: home), root != home.appendingPathComponent("Library"),
              root != home.appendingPathComponent("Library/Application Support"),
              root.lastPathComponent != ".Trash" else {
            throw SweepError.message("Choose a dedicated Claude configuration folder inside your home folder.")
        }
        try checkPath(root, anchor: home)
        guard try FileIdentity.read(root).kind == .typeDirectory else {
            throw SweepError.message("The selected profile must be a folder.")
        }
        let markers = [".claude.json", ".credentials.json", "settings.json"]
        guard markers.contains(where: {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }) else {
            throw SweepError.message("No recognized Claude profile markers were found in that folder.")
        }
    }

    public static func allowedKeychainService(_ name: String) -> Bool {
        let exact: Set<String> = ["Claude Code-credentials", "Claude Code-device-keys",
                                  "Claude Safe Storage", "Claude Code", "coworkRemoteDevice"]
        let prefixes = ["Claude Code-credentials-", "Claude Code-device-keys-"]
        return exact.contains(name) || prefixes.contains { name.hasPrefix($0) && name.count > $0.count }
    }

    public static let settingNames = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "apiKeyHelper",
        "claudeCode.environmentVariables", "OTEL_RESOURCE_INCLUDE_HOST"]

    // Returns variable names only. Values never enter the inventory or action report.
    public static func referencedSettings(in text: String) -> [String] {
        settingNames.filter { name in
            let escaped = NSRegularExpression.escapedPattern(for: name)
            return text.range(of: "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])",
                              options: .regularExpression) != nil
        }
    }
}

public struct Scanner {
    public let home: URL
    public let customRoots: [URL]
    public let includeSharedApplication: Bool
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                customRoots: [URL] = [], includeSharedApplication: Bool = true) {
        self.home = home.standardizedFileURL
        self.customRoots = customRoots
        self.includeSharedApplication = includeSharedApplication
    }

    public func scan() -> Inventory {
        var result = Inventory()
        let fm = FileManager.default

        func add(_ url: URL, anchor: URL, title: String, detail: String, group: DataGroup) {
            guard !result.files.contains(where: { $0.url == url }) else { return }
            do {
                // Read first so an absent known path isn't mistaken for an error.
                let identity = try FileIdentity.read(url)
                try Safety.checkPath(url, anchor: anchor)
                let size = measure(url)
                result.files.append(Candidate(url: url, anchor: anchor, title: title, detail: detail,
                    group: group, identity: identity, bytes: size.bytes, approximate: size.partial))
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain &&
                    [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return }
                result.warnings.append("\(url.path): \(error.localizedDescription)")
            }
        }
        func relative(_ path: String, _ title: String, _ detail: String, _ group: DataGroup) {
            add(home.appendingPathComponent(path), anchor: home, title: title, detail: detail, group: group)
        }

        relative("Library/Application Support/Claude", "Claude Desktop profile",
                 "Includes sign-in state, device identifiers, extensions and locally stored Cowork work. Save needed work first.", .desktop)
        relative(".claude", "Claude Code data",
                 "Includes session history, credentials fallback, skills, plugins, configuration backups and settings.", .code)
        relative(".claude.json", "Claude Code state",
                 "Installation identifiers, account metadata, MCP configuration and project state.", .code)

        for (path, title) in [
            ("Library/Caches/com.anthropic.claudefordesktop", "Desktop cache"),
            ("Library/Caches/com.anthropic.claudefordesktop.ShipIt", "Desktop updater cache"),
            ("Library/Caches/claude-cli-nodejs", "Claude Code cache"),
            ("Library/Logs/Claude", "Desktop logs")
        ] { relative(path, title, "Generated cache or diagnostic files.", .cache) }

        for (path, title) in [
            ("Library/HTTPStorages/com.anthropic.claudefordesktop", "Desktop HTTP storage"),
            ("Library/HTTPStorages/com.anthropic.claudefordesktop.binarycookies", "Desktop HTTP cookies"),
            ("Library/Preferences/com.anthropic.claudefordesktop.plist", "Desktop preferences"),
            ("Library/Saved Application State/com.anthropic.claudefordesktop.savedState", "Saved window state")
        ] { relative(path, title, "Claude Desktop preferences or web session state.", .desktop) }

        relative("Applications/Claude.app", "Claude in your Applications folder", "Removes the application bundle.", .application)
        if includeSharedApplication {
            add(URL(fileURLWithPath: "/Applications/Claude.app"), anchor: URL(fileURLWithPath: "/Applications"),
                title: "Claude in Applications", detail: "Shared installation. Other Mac users may use this app; permission may be required.", group: .application)
        }

        // Only direct, narrowly named backup / recent-document entries are discovered.
        for (folder, prefix, title, group) in [
            (home, ".claude.json.backup", "Legacy Code state backup", DataGroup.code),
            (home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"),
             "com.anthropic.claudefordesktop.sfl", "Claude recent documents", DataGroup.desktop)
        ] {
            do {
                if folder != home { try Safety.checkPath(folder, anchor: home) }
                for child in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    where child.lastPathComponent.hasPrefix(prefix) {
                    add(child, anchor: home, title: title, detail: "A known Claude metadata file.", group: group)
                }
            } catch let error as NSError {
                if !(error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) {
                    result.warnings.append("Could not inspect \(folder.path): \(error.localizedDescription)")
                }
            }
        }

        // A custom root itself is NEVER a deletion target. Only known direct children.
        for root in customRoots {
            do {
                try Safety.validateCustomRoot(root, home: home)
                for child in [".claude.json", ".config.json", ".credentials.json", "settings.json", "settings.local.json",
                              "history.jsonl", "backups", "projects", "file-history", "plans", "tasks", "plugins",
                              "skills", "cache", "debug", "session-env", "shell-snapshots", "telemetry",
                              "daemon", "sessions", "stats-cache.json"] {
                    let url = root.appendingPathComponent(child)
                    if result.files.contains(where: { Safety.isInside(url, anchor: $0.url) }) { continue }
                    add(url, anchor: root, title: "\(root.lastPathComponent) / \(child)",
                        detail: "Custom Claude profile. May contain work and preferences; selected individually.", group: .code)
                }
            } catch { result.warnings.append(error.localizedDescription) }
        }

        let settingsFiles = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile",
            ".claude/settings.json", "Library/Application Support/Code/User/settings.json",
            "Library/Application Support/Cursor/User/settings.json", "Library/Application Support/VSCodium/User/settings.json"]
        for relativePath in settingsFiles {
            let url = home.appendingPathComponent(relativePath)
            do {
                _ = try FileIdentity.read(url)
                try Safety.checkPath(url, anchor: home)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576 else {
                    result.warnings.append("Settings file too large to inspect: \(url.path)"); continue
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    result.warnings.append("Settings file is not UTF-8: \(url.path)"); continue
                }
                let names = Safety.referencedSettings(in: text)
                if !names.isEmpty { result.references.append(SettingReference(url: url, names: names)) }
            } catch let error as NSError {
                if !(error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) {
                    result.warnings.append("Could not inspect settings at \(url.path): \(error.localizedDescription)")
                }
            }
        }
        result.files.sort { $0.url.path < $1.url.path }
        return result
    }

    private func measure(_ url: URL) -> (bytes: Int64, partial: Bool) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let value = try? url.resourceValues(forKeys: keys) else { return (0, true) }
        if value.isDirectory != true { return (Int64(value.fileSize ?? 0), false) }
        var partial = false
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in partial = true; return true }) else { return (0, true) }
        var bytes: Int64 = 0
        var count = 0
        for case let child as URL in iterator {
            count += 1
            if count > 25_000 { partial = true; break }
            guard let item = try? child.resourceValues(forKeys: keys) else { partial = true; continue }
            if item.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if item.isDirectory != true { bytes += Int64(item.fileSize ?? 0) }
        }
        return (bytes, partial)
    }
}
