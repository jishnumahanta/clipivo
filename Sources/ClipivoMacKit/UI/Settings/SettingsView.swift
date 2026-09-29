import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClipivoCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, clipboard, history, spaces, privacy, search, appearance, keyboard, storage, advanced
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .clipboard: return "doc.on.clipboard"
        case .history: return "clock.arrow.circlepath"
        case .spaces: return "square.stack"
        case .privacy: return "hand.raised"
        case .search: return "magnifyingglass"
        case .appearance: return "paintbrush"
        case .keyboard: return "keyboard"
        case .storage: return "internaldrive"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    let app: AppModel
    @State var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch section {
                case .general: GeneralSettings(app: app)
                case .clipboard: ClipboardSettings(app: app)
                case .history: HistorySettings(app: app)
                case .spaces: SpacesSettings(app: app)
                case .privacy: PrivacySettings(app: app)
                case .search: SearchSettings(app: app)
                case .appearance: AppearanceSettings(app: app)
                case .keyboard: KeyboardSettings(app: app)
                case .storage: StorageSettings(app: app)
                case .advanced: AdvancedSettings(app: app)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(section.title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: - General

struct GeneralSettings: View {
    let app: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var axGranted = AccessibilityPermission.isGranted
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section {
                Toggle("Launch \(Branding.productName) at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        do { try LaunchAtLogin.set(value); launchError = nil }
                        catch { launchError = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
                    }
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
                if LaunchAtLogin.requiresApproval {
                    Text("Approve \(Branding.productName) in System Settings ▸ General ▸ Login Items.").font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show Dock icon", isOn: $prefs.showDockIcon)
                    .onChange(of: prefs.showDockIcon) { _, _ in app.applyAppearance() }
                Picker("Menu bar icon", selection: $prefs.colorMenuBarIcon) {
                    Text("Color logo").tag(true)
                    Text("Monochrome").tag(false)
                }
                .onChange(of: prefs.colorMenuBarIcon) { _, _ in app.onStateChange?() }
                Picker("Clicking the menu bar icon", selection: $prefs.menuBarClickAction) {
                    ForEach(MenuBarClickAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: prefs.menuBarClickAction) { _, _ in app.onStateChange?() }
            }
            Section("Permissions") {
                LabeledContent {
                    if axGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") {
                            AccessibilityPermission.requestPrompt()
                            AccessibilityPermission.openSystemSettings()
                        }
                    }
                } label: {
                    Text("Accessibility")
                    Text("Needed only to paste automatically (sending ⌘V to the app you were using). Without it, clips are copied and you press ⌘V yourself.")
                }
            }
            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                LabeledContent("Library", value: (app.library.layout.root.path as NSString).abbreviatingWithTildeInPath)
                LabeledContent("Developer") {
                    Link(Branding.developerName, destination: Branding.developerWebsite)
                }
                LabeledContent("Support") {
                    if let mail = URL(string: "mailto:\(Branding.supportEmail)?subject=\(Branding.productName)%20support") {
                        Link(Branding.supportEmail, destination: mail)
                    }
                }
                Text("\(Branding.tagline) Everything stays on this Mac — no account, no cloud, no analytics.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Branding.copyright).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onReceive(timer) { _ in axGranted = AccessibilityPermission.isGranted }
    }

    static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

// MARK: - Clipboard

struct ClipboardSettings: View {
    let app: AppModel

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section {
                Toggle("Monitor the clipboard", isOn: Binding(get: { !prefs.monitoringPaused }, set: { app.setPaused(!$0) }))
                Text("While paused, nothing new is saved. Your history stays intact.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Selecting a clip") {
                Toggle("Single-click a clip to paste it", isOn: $prefs.singleClickPastes)
                Text("The clip is pasted into the text field you were typing in, and it also becomes your newest clipboard item so you can paste it again with ⌘V.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Return key and click", selection: $prefs.pasteBehavior) {
                    ForEach(PasteBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Always paste as plain text", isOn: $prefs.alwaysPastePlainText)
                Toggle("Close the panel after copying", isOn: $prefs.closeAfterCopy)
                Toggle("Move pasted and copied clips to the top", isOn: $prefs.moveUsedToTop)
            }
            Section("Duplicates") {
                Picker("Copying something already in history", selection: $prefs.duplicatePolicy) {
                    Text("Moves the existing clip to the top").tag(DuplicatePolicy.moveToTop)
                    Text("Adds another entry").tag(DuplicatePolicy.keepAll)
                }
                .onChange(of: prefs.duplicatePolicy) { _, _ in app.applyCapturePolicy() }
            }
            Section("Formats") {
                Text("\(Branding.productName) keeps every useful representation of what you copy — plain text, rich text (RTF/HTML), images at original quality, PDFs, colors, links and file references — so pasting preserves formatting.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - History

struct HistorySettings: View {
    let app: AppModel
    @State private var confirmClear = false

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Retention") {
                LabeledContent("Keep clips") { Text(prefs.cleanupEnabled ? "Until cleanup rule applies" : "Forever").foregroundStyle(.secondary) }
                Text("By default nothing is ever deleted automatically. The only limit is the free space on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Optional cleanup") {
                Toggle("Automatically remove old clips", isOn: $prefs.cleanupEnabled)
                Picker("Remove clips not used for", selection: $prefs.cleanupAgeDays) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("6 months").tag(180)
                    Text("1 year").tag(365); Text("2 years").tag(730); Text("5 years").tag(1825)
                }
                .disabled(!prefs.cleanupEnabled)
                Toggle("Only images and screenshots", isOn: $prefs.cleanupImagesOnly)
                    .disabled(!prefs.cleanupEnabled)
                Text("Pinned clips and clips in Spaces are never removed by cleanup.").font(.caption).foregroundStyle(.secondary)
                if prefs.cleanupEnabled {
                    Button("Run Cleanup Now") { app.runMaintenance(); app.show("Cleanup finished", style: .success) }
                }
            }
            Section("Manual cleanup") {
                Button("Clear History…", role: .destructive) { confirmClear = true }
                Text("Removes every clip that is not pinned and not in a Space.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                app.perform("Clearing history") {
                    let count = try await app.library.clearHistory()
                    app.show("Removed \(count.formatted()) clips", style: .success)
                }
            }
        } message: {
            Text("Pinned clips and clips in Spaces are kept. This can't be undone.")
        }
    }
}

// MARK: - Spaces

struct SpacesSettings: View {
    let app: AppModel
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                ForEach(app.spaces) { space in
                    SpaceSettingsRow(space: space, app: app)
                }
                .onMove { from, to in
                    var ids = app.spaces.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    app.reorderSpaces(ids)
                }
                HStack {
                    TextField("New Space name", text: $newName).onSubmit(create)
                    Button("Add", action: create).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Spaces")
            } footer: {
                Text("A clip can belong to any number of Spaces. Deleting a Space never deletes its clips. History and Pinned always exist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func create() {
        let name = newName
        newName = ""
        Task { await app.createSpace(named: name) }
    }
}

private struct SpaceSettingsRow: View {
    let space: Space
    let app: AppModel
    @State private var name: String

    init(space: Space, app: AppModel) {
        self.space = space
        self.app = app
        _name = State(initialValue: space.name)
    }

    var body: some View {
        HStack {
            Menu {
                ForEach(Theme.spaceIcons, id: \.self) { icon in
                    Button { app.setSpaceIcon(space.id, icon) } label: { Label(icon, systemImage: icon) }
                }
            } label: { Image(systemName: space.icon) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Icon for \(space.name)")
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .onSubmit { app.renameSpace(space.id, name) }
            Text("\(space.clipCount) clips").font(.caption).foregroundStyle(.secondary)
            Toggle("Pinned", isOn: Binding(get: { space.isPinned }, set: { app.setSpacePinned(space.id, $0) }))
                .toggleStyle(.checkbox)
            Button(role: .destructive) { app.deleteSpace(space) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(space.name)")
        }
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    let app: AppModel
    @State private var showingPicker = false
    @State private var installed: [InstalledApplication] = []
    @State private var filter = ""

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section {
                if app.ignoredApps.isEmpty {
                    Text("No ignored applications.").foregroundStyle(.secondary)
                }
                ForEach(app.ignoredApps) { ignored in
                    HStack {
                        if let icon = ImageCache.shared.appIcon(bundleID: ignored.bundleID) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                        VStack(alignment: .leading) {
                            Text(ignored.name)
                            Text(ignored.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { app.unignoreApp(bundleID: ignored.bundleID) }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Application…") {
                        installed = InstalledApplications.scan()
                        showingPicker = true
                    }
                    Button("Choose from Disk…") { chooseFromDisk() }
                }
            } header: {
                Text("Ignored applications")
            } footer: {
                Text("Anything copied in these apps is discarded before it is read: nothing is stored, no thumbnail or text recognition runs, and nothing is sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Password managers & concealed items", selection: $prefs.concealedPolicy) { policyOptions }
                Picker("Detected secrets (keys, tokens, card numbers)", selection: $prefs.sensitivePolicy) { policyOptions }
                Picker("One-time codes", selection: $prefs.oneTimeCodePolicy) { policyOptions }
                Toggle("Respect apps that mark clipboard content as temporary", isOn: $prefs.honorTransientMarker)
            } header: {
                Text("Sensitive content")
            } footer: {
                Text("Detection uses local pattern matching (for example private keys, JWTs, AWS/GitHub/Stripe keys, Luhn-valid card numbers). It is a safety net, not a guarantee — some secrets will not be recognised. \(app.privateStorageAvailable ? "Private clips are encrypted with a key kept in your Keychain." : "Private storage is unavailable because the Keychain could not be accessed.")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: prefs.concealedPolicy) { _, _ in app.applyCapturePolicy() }
            .onChange(of: prefs.sensitivePolicy) { _, _ in app.applyCapturePolicy() }
            .onChange(of: prefs.oneTimeCodePolicy) { _, _ in app.applyCapturePolicy() }
            .onChange(of: prefs.honorTransientMarker) { _, _ in app.applyCapturePolicy() }

            Section {
                Toggle("Require \(app.lock.biometryDescription) to open \(Branding.productName)", isOn: $prefs.lockEnabled)
                    .onChange(of: prefs.lockEnabled) { _, _ in app.lock.preferencesChanged() }
                    .disabled(!app.lock.canAuthenticate)
                Picker("Lock again after", selection: $prefs.lockAfterMinutes) {
                    Text("1 minute").tag(1); Text("5 minutes").tag(5); Text("15 minutes").tag(15)
                    Text("1 hour").tag(60); Text("Never (until sleep)").tag(0)
                }
                .disabled(!prefs.lockEnabled)
                Toggle("Lock when the Mac sleeps or the screen locks", isOn: $prefs.lockOnSleep)
            } header: {
                Text("Lock")
            } footer: {
                Text("When locked, history and search results are hidden. Copying keeps being recorded. Private clips always require authentication to view or paste.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingPicker) { appPicker }
    }

    @ViewBuilder private var policyOptions: some View {
        ForEach(SensitiveContentPolicy.allCases, id: \.self) { policy in
            if policy != .saveAsPrivate || app.privateStorageAvailable { Text(policy.displayName).tag(policy) }
        }
    }

    private var appPicker: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).padding(12)
            List(installed.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { item in
                Button {
                    app.ignoreApp(bundleID: item.bundleID, name: item.name)
                    showingPicker = false
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
                        Text(item.name)
                        Spacer()
                        if app.ignoredApps.contains(where: { $0.bundleID == item.bundleID }) {
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack { Spacer(); Button("Cancel") { showingPicker = false }.keyboardShortcut(.cancelAction) }.padding(12)
        }
        .frame(width: 380, height: 460)
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let item = InstalledApplications.application(at: url) { app.ignoreApp(bundleID: item.bundleID, name: item.name) }
        }
    }
}

// MARK: - Search

struct SearchSettings: View {
    let app: AppModel

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Search in") {
                Toggle("Clip titles", isOn: $prefs.searchTitles)
                Toggle("Text recognized in images", isOn: $prefs.searchOCR)
                Toggle("File names and paths", isOn: $prefs.searchFileNames)
                Toggle("Source app names", isOn: $prefs.searchAppNames)
                Text("Clip text, links and tags are always searched.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Text recognition") {
                Toggle("Recognize text in copied images", isOn: $prefs.ocrEnabled)
                    .onChange(of: prefs.ocrEnabled) { _, value in
                        Task { await app.background.setOCREnabled(value); app.background.schedule() }
                    }
                Text("Runs on this Mac with Apple's Vision framework. Images never leave your Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Links") {
                Toggle("Fetch page titles for copied links", isOn: $prefs.fetchLinkTitles)
                Text("Off by default. When on, \(Branding.productName) requests each copied http(s) link to read its title — the website will see that request.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Search syntax") {
                syntaxRow("app:chrome", "Clips copied from an app")
                syntaxRow("type:image", "text, images, screenshots, links, files, code, colors, pdfs")
                syntaxRow("in:work", "Clips in a Space")
                syntaxRow("is:pinned", "Pinned clips")
                syntaxRow("tag:invoice", "Clips with a tag")
                syntaxRow("date:week", "today, yesterday, week, month, year")
                syntaxRow("\"exact phrase\"", "Match words together")
            }
        }
    }

    private func syntaxRow(_ syntax: String, _ meaning: String) -> some View {
        LabeledContent { Text(meaning).foregroundStyle(.secondary) } label: { Text(syntax).font(.body.monospaced()) }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    let app: AppModel

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: prefs.appearance) { _, _ in app.applyAppearance() }
                Picker("List density", selection: $prefs.density) {
                    ForEach(ListDensity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show Spaces sidebar", isOn: $prefs.showSidebar)
                Toggle("Show source app icons", isOn: $prefs.showSourceIcons)
            }
            Section("Panel") {
                Picker("Layout", selection: $prefs.panelLayout) {
                    ForEach(PanelLayout.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                // Close the panel so it reopens with the new layout's own size and position.
                .onChange(of: prefs.panelLayout) { _, _ in app.onPanelRequest?(.hide) }
                if prefs.panelLayout == .shelf {
                    Picker("Dock to", selection: $prefs.shelfEdge) {
                        ForEach(ShelfEdge.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Display", selection: $prefs.panelScreen) {
                    ForEach(PanelScreen.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Section("Floating list") {
                Picker("Position", selection: $prefs.panelPosition) {
                    ForEach(PanelPosition.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("The floating list remembers its size. Drag its background to move it. The shelf remembers its height.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Keyboard

struct KeyboardSettings: View {
    let app: AppModel

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Global shortcuts") {
                LabeledContent("Open clipboard panel") {
                    ShortcutRecorder(combo: $prefs.panelHotKey, allowsClearing: false) { app.registerHotKeys() }
                }
                LabeledContent("Paste latest clip as plain text") {
                    ShortcutRecorder(combo: $prefs.plainTextHotKey) { app.registerHotKeys() }
                }
                if let error = app.hotKeyError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("In the panel") {
                Toggle("Space opens Quick Look when the search field is empty", isOn: $prefs.spaceOpensQuickLook)
                ForEach(Self.panelShortcuts, id: \.0) { key, action in
                    LabeledContent { Text(action).foregroundStyle(.secondary) } label: { Text(key).font(.body.monospaced()) }
                }
            }
        }
    }

    static let panelShortcuts: [(String, String)] = [
        ("← → ↑ ↓", "Move selection (⇧ to extend)"), ("Click", "Paste (⇧ plain text, ⌥ copy only, ⌘ multi-select)"), ("↩", "Paste"), ("⇧↩", "Paste as plain text"), ("⌥↩ / ⌘C", "Copy without pasting"),
        ("⌘1 … ⌘9", "Paste clip 1–9"), ("Space / ⌘Y", "Quick Look"), ("⌫ / ⌘⌫", "Delete clip"), ("⌘P", "Pin / unpin"),
        ("⌘R", "Edit title"), ("⌘T", "Tags"), ("⌘N", "New Space from selection"), ("⌘O", "Open link or file"),
        ("⇥ / ⇧⇥", "Next / previous type filter"), ("⌘[ ⌘]", "Previous / next Space"), ("⌘F", "Focus search"), ("Esc", "Clear search, then close"),
    ]
}

// MARK: - Storage

struct StorageSettings: View {
    let app: AppModel
    @State private var stats: StorageStatistics?
    @State private var busy: String?
    @State private var progress: Double?

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Usage") {
                if let stats {
                    LabeledContent("Clipboard items", value: stats.totalClips.formatted())
                    LabeledContent("Pinned / private", value: "\(stats.pinnedClips.formatted()) / \(stats.privateClips.formatted())")
                    LabeledContent("Images & screenshots", value: "\(stats.count([.image, .screenshot]).formatted()) · \(ByteCountFormatter.file(stats.payloadBytes([.image, .screenshot])))")
                    LabeledContent("Files & folders", value: "\(stats.count([.file, .folder]).formatted()) references")
                    LabeledContent("PDFs", value: "\(stats.count([.pdf]).formatted()) · \(ByteCountFormatter.file(stats.payloadBytes([.pdf])))")
                    LabeledContent("Database & search index", value: ByteCountFormatter.file(stats.databaseBytes))
                    LabeledContent("Stored payloads", value: ByteCountFormatter.file(stats.blobBytes))
                    LabeledContent("Thumbnails", value: ByteCountFormatter.file(stats.thumbnailBytes))
                    LabeledContent("Recognized text", value: ByteCountFormatter.file(stats.ocrTextBytes))
                    LabeledContent("Total") { Text(ByteCountFormatter.file(stats.totalBytes)).fontWeight(.semibold) }
                    if stats.backupBytes > 0 { LabeledContent("Backups (separate)", value: ByteCountFormatter.file(stats.backupBytes)) }
                    if let oldest = stats.oldestClip { LabeledContent("Oldest clip", value: RelativeTime.full.string(from: oldest)) }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Section("Maintenance") {
                HStack {
                    Button("Clear Thumbnail Cache") { run("Clearing thumbnails") { try await app.library.removeThumbnailCache(); ImageCache.shared.removeAll(); app.background.schedule() } }
                    Button("Compact Database") { run("Compacting") { try await app.library.vacuum() } }
                    Button("Rebuild Search Index") { run("Rebuilding index") { try await app.library.rebuildSearchIndex() } }
                }
                Button("Show Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.library.layout.root]) }
                if let busy {
                    HStack { ProgressView(value: progress).frame(maxWidth: 200); Text(busy).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Export & import") {
                HStack {
                    Button("Export…") { export(includePrivate: false) }
                    Button("Export Including Private Clips…") { export(includePrivate: true) }
                    Button("Import…") { importArchive() }
                }
                Text("Archives (.clipivo) contain clips with their original data, titles, timestamps, source apps, Spaces, pins, tags and recognized text. Importing skips clips you already have.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backups") {
                Toggle("Back up automatically", isOn: $prefs.autoBackupEnabled)
                Picker("Every", selection: $prefs.autoBackupIntervalDays) {
                    Text("Day").tag(1); Text("Week").tag(7); Text("Month").tag(30)
                }
                .disabled(!prefs.autoBackupEnabled)
                Stepper("Keep the last \(prefs.backupsToKeep) backups", value: $prefs.backupsToKeep, in: 1...20)
                HStack {
                    Button("Back Up Now") {
                        run("Backing up") {
                            let url = try await ArchiveService.backup(library: app.library, keep: prefs.backupsToKeep)
                            prefs.lastBackupDate = Date()
                            app.show("Backup saved: \(url.lastPathComponent)", style: .success)
                        }
                    }
                    Button("Show Backups") { NSWorkspace.shared.open(app.library.layout.backupsDirectory) }
                }
                if let last = prefs.lastBackupDate { Text("Last backup: \(RelativeTime.full.string(from: last))").font(.caption).foregroundStyle(.secondary) }
                Text("Backups are stored locally and exclude private clips.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        stats = try? await app.library.storageStatistics()
    }

    private func run(_ label: String, _ body: @escaping () async throws -> Void) {
        busy = label
        progress = nil
        Task {
            do { try await body() } catch { app.show("\(label) failed: \(error.localizedDescription)", style: .error) }
            busy = nil
            await reload()
        }
    }

    private func export(includePrivate: Bool) {
        Task {
            if includePrivate {
                guard await app.lock.authenticate(reason: "export private clips") else { return }
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: ArchiveService.fileExtension) ?? .zip]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            panel.nameFieldStringValue = "\(Branding.productName) Export \(formatter.string(from: Date())).\(ArchiveService.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            run("Exporting") {
                let summary = try await ArchiveService.export(library: app.library, to: url, includePrivate: includePrivate) { done, total in
                    Task { @MainActor in progress = total > 0 ? Double(done) / Double(total) : nil }
                }
                app.show("Exported \(summary.clipsWritten.formatted()) clips", style: .success)
            }
        }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ArchiveService.fileExtension) ?? .zip, .zip, .folder]
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Importing") {
            let summary = try await ArchiveService.importArchive(library: app.library, from: url) { done, total in
                Task { @MainActor in progress = total > 0 ? Double(done) / Double(total) : nil }
            }
            app.show("Imported \(summary.clipsImported.formatted()) clips (\(summary.clipsMerged) merged, \(summary.clipsSkipped) already present)", style: .success)
            app.background.schedule()
        }
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    let app: AppModel
    @State private var confirmReset = false

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Clipboard monitoring") {
                LabeledContent("Check for changes every") {
                    Picker("", selection: $prefs.pollInterval) {
                        Text("0.15 s").tag(0.15); Text("0.3 s (default)").tag(0.3); Text("0.5 s").tag(0.5); Text("1 s").tag(1.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .onChange(of: prefs.pollInterval) { _, _ in app.applyPollInterval() }
                Text("macOS has no clipboard-change notification; \(Branding.productName) checks a change counter, which costs almost nothing.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Largest single item to keep", selection: $prefs.maxItemSizeMB) {
                    Text("50 MB").tag(50); Text("200 MB").tag(200); Text("1 GB").tag(1024); Text("No limit").tag(0)
                }
                .onChange(of: prefs.maxItemSizeMB) { _, _ in app.applyCapturePolicy() }
            }
            Section("Reset") {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                Text("Your clipboard history is not affected.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset Settings", role: .destructive) {
                prefs.resetToDefaults()
                app.show("Settings will be reset the next time \(Branding.productName) starts.", style: .info)
            }
        }
    }
}
