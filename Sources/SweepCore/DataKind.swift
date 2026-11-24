import Foundation

/// Descriptions are based on known locations, not inspection of file contents.
public enum DataKind: String {
    case profile = "Profile & local work"
    case cache = "Generated cache"
    case logs = "Diagnostic logs"
    case preferences = "Settings & configuration"
    case session = "Cookies & session storage"
    case metadata = "Identifiers & metadata"
    case application = "Application bundle"
    case credentials = "Saved credentials"
    case history = "History & local work"
    case extensions = "Skills & extensions"

    public var impact: String {
        switch self {
        case .profile: return "Resets this local profile and may remove sign-ins, settings and locally saved work. Export anything you need first."
        case .cache: return "Removes generated files. Claude may rebuild them on its next launch."
        case .logs: return "Removes diagnostic history that may be useful for troubleshooting. New logs can be created later."
        case .preferences: return "Removes saved preferences or integration settings. You may need to configure them again."
        case .session: return "Removes this local session storage and may sign you out of the desktop app. Browser sessions are separate."
        case .metadata: return "Removes local state or references. This does not delete cloud records or the documents those references point to."
        case .application: return "Removes this copy of the app. Its profiles, browser data and Keychain entries are separate."
        case .credentials: return "Removes this local credential file and may require signing in or configuring authentication again."
        case .history: return "Removes local history or work files. Save anything you want to keep before cleanup."
        case .extensions: return "Removes local skills, plugins or extensions. Save custom work before reinstalling."
        }
    }
}

public extension Candidate {
    var dataKind: DataKind {
        let name = url.lastPathComponent
        if group == .application { return .application }
        if group == .cache { return url.path.contains("/Logs/") ? .logs : .cache }
        if name == "Claude" || name == ".claude" { return .profile }
        if name.contains("binarycookies") || url.path.contains("/HTTPStorages/") { return .session }
        if name == ".credentials.json" { return .credentials }
        if ["skills", "plugins"].contains(name) { return .extensions }
        if ["projects", "file-history", "history.jsonl", "plans", "tasks", "sessions", "backups"].contains(name) { return .history }
        if ["cache", "stats-cache.json"].contains(name) { return .cache }
        if ["debug", "telemetry"].contains(name) { return .logs }
        if name.hasPrefix("settings") || name.hasSuffix(".plist") || name == ".config.json" { return .preferences }
        if group == .code && !name.hasPrefix(".claude.json") { return .profile }
        return .metadata
    }
}
