import SwiftUI
import AppKit
import SweepCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ClaudeSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = SweepModel()
    var body: some Scene {
        WindowGroup("Claude Sweep") {
            MainView(model: model).frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1040, height: 740)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case files = "Local files"
    case keys = "Keychain"
    case manual = "Browser & settings"
    case report = "Activity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .files: return "folder"
        case .keys: return "key"
        case .manual: return "globe"
        case .report: return "list.bullet.rectangle"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: SweepModel
    @State private var page: Page? = .files
    @State private var reviewFiles = false
    @State private var reviewKeys = false
    @State private var scanScopeExpanded = true
    private let accent = Color(red: 0.68, green: 0.33, blue: 0.20)

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 27)).foregroundStyle(accent)
                    Text("Claude Sweep").font(.title2.weight(.semibold))
                    Text("Local data cleanup").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.top, 20)
                List(Page.allCases, selection: $page) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Works locally", systemImage: "lock.shield").font(.caption.weight(.medium))
                    Text("No uploads or analytics.\nIndependent, unofficial utility.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.navigationSplitViewColumnWidth(205)
        } detail: {
            VStack(spacing: 0) {
                if model.busy {
                    ProgressView().progressViewStyle(.linear).tint(accent)
                }
                switch page ?? .files {
                case .files: filesPage
                case .keys: keysPage
                case .manual: manualPage
                case .report: reportPage
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .toolbar {
            ToolbarItemGroup {
                if model.busy { Text("Working…").foregroundStyle(.secondary) }
                Button { model.scan() } label: { Label("Scan files", systemImage: "arrow.clockwise") }
                    .disabled(model.busy)
            }
        }
        .alert("Claude Sweep", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .sheet(isPresented: $reviewFiles) {
            FileReview(items: Safety.outermost(model.chosenFiles)) {
                reviewFiles = false; model.cleanFiles()
            } cancel: { reviewFiles = false }
        }
        .alert("Permanently delete \(model.chosenKeys.count) credentials?", isPresented: $reviewKeys) {
            Button("Cancel", role: .cancel) {}
            Button("Delete credentials", role: .destructive) { model.deleteKeys() }
        } message: {
            Text("\(model.chosenKeys.map(\.service).joined(separator: "\n"))\n\nThese Keychain entries do not go to Trash. Deleting Safe Storage can make existing encrypted app data unreadable. Quit Claude and save needed work first.")
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filesPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading("Review what stays behind.", "Find known Claude files on this Mac. Nothing is selected or changed automatically.")
                    HStack {
                        metric("\(model.inventory.files.count)", "items found")
                        Divider().frame(height: 36)
                        metric(size(model.inventory.files.reduce(0) { $0 + $1.bytes }), "estimated logical size")
                        Spacer()
                        Button("Add Code profile…") { model.addProfile() }.disabled(model.busy)
                    }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    scanScope
                    CleanupResults(title: "Last file cleanup", outcomes: model.fileOutcomes, date: model.fileCleanupDate)
                    if !model.didScan {
                        notice("Start with a scan", "Checks known locations in your home folder and the Claude app bundle. It does not inspect message contents or change files.", "magnifyingglass")
                    } else if model.inventory.files.isEmpty {
                        notice("No known files found", "Review Keychain and browser data separately. Custom profiles, inaccessible locations and unknown future paths may still contain data.", "folder.badge.questionmark")
                    }
                    ForEach(DataGroup.allCases) { group in
                        let items = model.inventory.files.filter { $0.group == group }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(group.rawValue).font(.headline)
                                VStack(spacing: 0) {
                                    ForEach(items) { item in
                                        fileRow(item)
                                        if item.id != items.last?.id { Divider().padding(.leading, 42) }
                                    }
                                }.background(.background, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    if !model.inventory.warnings.isEmpty {
                        DisclosureGroup("\(model.inventory.warnings.count) locations need attention") {
                            ForEach(Array(model.inventory.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                            }
                        }.foregroundStyle(.secondary)
                    }
                    Text("File cleanup moves items to Trash. Keep the Trash until you have recovered any work you need. This app cannot erase Anthropic’s server records or guarantee against account restrictions.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(28)
            }
            Divider()
            HStack {
                Button("Select caches & logs") {
                    model.selectedFiles.formUnion(model.inventory.files.filter { $0.group == .cache }.map(\.id))
                }.disabled(model.busy || !model.didScan)
                Button("Deselect all") { model.selectedFiles = [] }.disabled(model.busy)
                Spacer()
                Text("\(model.chosenFiles.count) selected · \(size(model.selectedSize))").foregroundStyle(.secondary).font(.caption)
                Button("Review cleanup…") { reviewFiles = true }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.chosenFiles.isEmpty)
            }.padding(16)
        }
    }

    private var scanScope: some View {
        DisclosureGroup("What the file scan checks", isExpanded: $scanScopeExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Types are inferred from known paths. File and conversation contents are not opened, except for the limited settings-name check below.")
                    .font(.caption).foregroundStyle(.secondary)
                scopeRow("Desktop profile", "Sign-in state, extensions and local work", "~/Library/Application Support/Claude")
                scopeRow("Code profiles", "History, settings, skills and local credentials", "~/.claude · ~/.claude.json · added profile folders")
                scopeRow("Caches, logs & desktop state", "Generated files, cookies, preferences and recent-document references", "Known Claude paths in ~/Library/Caches, Logs, HTTPStorages, Preferences, Saved Application State and Application Support")
                scopeRow("Application", "Installed Claude app bundles", "~/Applications/Claude.app · /Applications/Claude.app")
                scopeRow("Settings references — read only", "Looks for configuration variable names; values are not shown", "Common shell startup files and Claude / VS Code / Cursor / VSCodium settings; up to 1 MiB per file")
                Text("Keychain is inspected separately. Browser data and cloud records are not scanned. Only found file targets appear below; inaccessible paths are listed under locations needing attention.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 10)
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private func scopeRow(_ title: String, _ data: String, _ location: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title + " · " + data).font(.caption.weight(.medium))
            Text(location).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func fileRow(_ item: Candidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(item.title)", isOn: Binding(get: { model.selectedFiles.contains(item.id) }, set: { value in
                if value { model.selectedFiles.insert(item.id) } else { model.selectedFiles.remove(item.id) }
            })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).fontWeight(.medium)
                Text("Expected data: " + item.dataKind.rawValue).font(.caption.weight(.medium))
                Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Cleanup effect: " + item.dataKind.impact).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(item.url.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Text((item.approximate ? "≥ " : "") + size(item.bytes)).font(.caption).monospacedDigit()
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
        }.padding(14)
    }

    private var keysPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading("Saved credentials.", "Inspect recognized Claude entries in your login Keychain. Scanning requests names and references, never secret values.")
                notice("Optional, permanent reset", "Keychain deletion cannot be undone through Trash. Save needed work first; removing Safe Storage can make encrypted local data unreadable.", "key.horizontal")
                HStack {
                    Button("Inspect Keychain") { model.scanKeys() }.disabled(model.busy)
                    Button("Open Keychain Access") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
                        } else { model.message = "Open Keychain Access with Spotlight to review entries manually." }
                    }
                    Spacer()
                }
                CleanupResults(title: "Last Keychain cleanup", outcomes: model.keyOutcomes, date: model.keyCleanupDate)
                if model.didScanKeys && model.credentials.isEmpty {
                    Text("No matching entries found in the login Keychain. Other keychains and unknown service names are not covered.").foregroundStyle(.secondary)
                }
                ForEach(model.credentials) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("Select credential", isOn: Binding(get: { model.selectedKeys.contains(item.id) }, set: { value in
                            if value { model.selectedKeys.insert(item.id) } else { model.selectedKeys.remove(item.id) }
                        })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.service).fontWeight(.medium).textSelection(.enabled)
                            Text("Account: " + item.account).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(item.service == "Claude Safe Storage" ? "Encryption key · Removing this can make encrypted local data unreadable." : "Credential / device key · Removing this may require signing in or pairing again.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("Only this selected entry is deleted; the keychain file is kept.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
                }
                Button("Delete selected credentials…", role: .destructive) { reviewKeys = true }
                    .disabled(model.busy || model.chosenKeys.isEmpty)
                Text("Quit all Claude processes first. If macOS denies access, the operation stops and reports it. No system keychains are reset.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }

    private var manualPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading("Finish the remaining checks.", "These locations need your review. Claude Sweep does not modify browser databases or rewrite shell and editor settings.")
                notice("Browser website data", "In each browser profile you used, remove website data for claude.ai, claude.com and anthropic.com. Include cookies and site storage, not just browsing history. Remove the Claude browser extension if you are uninstalling Claude completely.", "globe")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Chrome / Edge / Brave").font(.headline)
                    Text("Settings → Privacy and security → Site settings / Site data. Search for each domain and delete only its site data. Names vary by browser version.")
                    Text("Safari").font(.headline)
                    Text("Settings → Privacy → Manage Website Data. Search for Claude and Anthropic.")
                    Text("Firefox").font(.headline)
                    Text("Settings → Privacy & Security → Cookies and Site Data → Manage Data.")
                }.font(.callout).padding(18).background(.background, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Token and configuration references").font(.headline)
                    Text("A file scan checks common shell files and VS Code / Cursor settings for variable names. Matches can be comments or examples; inspect them before editing. Token values are never displayed.").foregroundStyle(.secondary)
                    if !model.didScan { Button("Scan files") { model.scan() }.disabled(model.busy) }
                    if model.didScan && model.inventory.references.isEmpty {
                        Text("No matching names found in the settings files checked. Project files and other editors are not scanned.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.inventory.references) { ref in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(shortPath(ref.url)).font(.system(.caption, design: .monospaced))
                                Text(ref.names.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([ref.url]) }
                        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                notice("Custom profiles & integrations", "Add any dedicated CLAUDE_CONFIG_DIR folders on the Local files page. Inspect other editors, project-local settings, containers, remote hosts and account-switcher apps yourself. Uninstall Claude editor extensions if no longer needed. Do not delete project source code or shared MCP credentials indiscriminately.", "slider.horizontal.3")
                notice("Sessions on the service", "Local cleanup does not revoke every remote session, remove cloud history or delete an account. Use the account’s session and privacy controls for those actions.", "cloud")
            }.padding(28)
        }
    }

    private var reportPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("What changed.", "The activity report records actual outcomes, including partial failures. It does not certify that every trace is gone.")
            HStack {
                Button("Export report…") { model.exportReport() }.disabled(model.log.isEmpty || model.busy)
                Button("Open Trash") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CleanupResults(title: "Last file cleanup", outcomes: model.fileOutcomes, date: model.fileCleanupDate)
                    CleanupResults(title: "Last Keychain cleanup", outcomes: model.keyOutcomes, date: model.keyCleanupDate)
                    Text("Full activity log").font(.headline)
                    Text(model.log.isEmpty ? "No actions yet." : model.log.joined(separator: "\n\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(16)
            }.background(.background, in: RoundedRectangle(cornerRadius: 10))
            Text("This report stays in memory until you export it. Trash files may still contain credentials; keep only the recovery copies you need.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(minWidth: 110, alignment: .leading)
    }
    private func notice(_ title: String, _ text: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(accent).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).fontWeight(.medium)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CleanupResults: View {
    let title: String
    let outcomes: [CleanupOutcome]
    let date: Date?

    var body: some View {
        if !outcomes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.headline)
                if let date {
                    Text(date.formatted() + " · Results from this operation, not a fresh scan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    ForEach(CleanupState.allCases, id: \.self) { state in
                        Label("\(outcomes.filter { $0.state == state }.count) \(state.rawValue.lowercased())", systemImage: symbol(state))
                            .foregroundStyle(color(state)).font(.caption.weight(.medium))
                    }
                }
                ForEach(outcomes) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(item.state)).foregroundStyle(color(item.state)).font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.state.rawValue + " · " + item.title).font(.callout.weight(.medium))
                            Text(item.location).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func symbol(_ state: CleanupState) -> String {
        switch state {
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
    private func color(_ state: CleanupState) -> Color {
        switch state {
        case .completed: return .green
        case .skipped: return .secondary
        case .failed: return .red
        }
    }
}

struct FileReview: View {
    let items: [Candidate]
    let confirm: () -> Void
    let cancel: () -> Void
    @State private var savedWork = false
    private var needsAcknowledgment: Bool { items.contains { $0.group != .cache } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move \(items.count) items to Trash?").font(.title2.weight(.semibold))
            Text("Quit Claude Desktop, all Claude Code sessions and editors using Claude before continuing. The app checks running processes again before each move.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).fontWeight(.medium)
                            Text(item.url.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(item.dataKind.rawValue + " · " + item.dataKind.impact).font(.caption).foregroundStyle(.secondary)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(14)
            }.frame(maxHeight: 300).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            if needsAcknowledgment {
                Toggle("I saved any local work, skills and settings I need.", isOn: $savedWork).toggleStyle(.checkbox)
            }
            Text("Files remain recoverable from Trash until it is emptied. Credentials in Keychain and browser data are handled separately.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move to Trash", action: confirm).buttonStyle(.borderedProminent)
                    .disabled(needsAcknowledgment && !savedWork)
            }
        }.padding(26).frame(width: 590)
    }
}

func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
func shortPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return url.path.hasPrefix(home + "/") ? "~" + String(url.path.dropFirst(home.count)) : url.path
}
