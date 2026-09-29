import SwiftUI
import AppKit
import ClipivoCore

struct PanelRootView: View {
    @Bindable var model: PanelViewModel
    let app: AppModel
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .popover)
            if app.lock.isLocked {
                LockedView(app: app)
            } else if app.preferences.panelLayout == .shelf {
                ShelfView(model: model, app: app, onOpenSettings: onOpenSettings)
                overlays
            } else {
                HStack(spacing: 0) {
                    if app.preferences.showSidebar {
                        SidebarView(model: model, app: app)
                            .frame(width: Theme.sidebarWidth)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        searchBar
                        FilterBar(model: model)
                        Divider().opacity(0.6)
                        ZStack {
                            ClipListView(model: model, app: app)
                            if let id = model.quickLookID {
                                QuickLookView(clipID: id, app: app) { model.quickLookID = nil }
                                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                            }
                        }
                        Divider().opacity(0.6)
                        FooterView(model: model, app: app, onOpenSettings: onOpenSettings)
                    }
                }
                overlays
            }
        }
        .frame(minWidth: app.preferences.panelLayout == .shelf ? 480 : 560, minHeight: app.preferences.panelLayout == .shelf ? 200 : 360)
        // The panel has a hidden, transparent title bar; use that space instead of leaving a gap.
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.quickLookID)
        .onChange(of: model.isSearchFocused) { _, focused in searchFocused = focused }
        .onChange(of: searchFocused) { _, focused in model.isSearchFocused = focused }
        .onChange(of: app.libraryVersion) { _, _ in model.refreshIfLibraryChanged() }
        .onAppear { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(searchFocused ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                TextField("Search your clipboard", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .accessibilityLabel("Search clipboard history")
                    .onSubmit { model.activate(model.selectedID) }
                if model.isLoading && !model.searchText.isEmpty {
                    ProgressView().controlSize(.mini)
                }
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                } else if let combo = app.preferences.panelHotKey {
                    // The shortcut as key caps, e.g. ⇧ ⌘ V.
                    HStack(spacing: 2) {
                        ForEach(Array(combo.displayString.map(String.init).enumerated()), id: \.offset) { _, key in KeyCap(text: key) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.85)))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(searchFocused ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: searchFocused ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: searchFocused)
            Button { app.preferences.showSidebar.toggle() } label: {
                Image(systemName: "sidebar.left").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show or hide Spaces")
            .accessibilityLabel("Toggle Spaces sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var overlays: some View {
        if let id = model.titleEditorID, let clip = model.results.first(where: { $0.id == id }) {
            ModalCard {
                TitleEditor(clip: clip) { title in
                    app.setTitle(id, title)
                    model.titleEditorID = nil
                } onCancel: { model.titleEditorID = nil }
            }
        } else if let id = model.tagEditorID, let clip = model.results.first(where: { $0.id == id }) {
            ModalCard {
                TagEditor(clip: clip, app: app) { model.tagEditorID = nil }
            }
        } else if let ids = model.newSpaceForIDs {
            ModalCard {
                NewSpaceEditor(count: ids.count) { name, icon in
                    model.newSpaceForIDs = nil
                    Task {
                        if let space = await app.createSpace(named: name, icon: icon, adding: ids), ids.isEmpty {
                            model.sidebar = .space(space.id)
                        }
                    }
                } onCancel: { model.newSpaceForIDs = nil }
            }
        } else if model.deliveryChoiceID != nil {
            ModalCard {
                VStack(spacing: 12) {
                    Text("Paste or copy?").font(.headline)
                    HStack {
                        Button("Copy  C") { if let id = model.deliveryChoiceID { model.deliveryChoiceID = nil; Task { await app.deliver(id, as: .copy, plainText: false) } } }
                        Button("Paste  ↩") { if let id = model.deliveryChoiceID { model.deliveryChoiceID = nil; Task { await app.deliver(id, as: .paste, plainText: false) } } }
                            .keyboardShortcut(.defaultAction)
                    }
                    Text("Change this in Settings ▸ Clipboard").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Filter bar

struct FilterBar: View {
    @Bindable var model: PanelViewModel
    private let primary: [ClipCategory] = [.all, .text, .images, .links, .files, .code, .colors]

    var body: some View {
        HStack(spacing: 4) {
            // Scrolls sideways instead of squeezing labels when the panel is narrow.
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(primary) { category in chip(category) }
                    moreMenu
                }
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            appMenu
            dateMenu
            if model.hasActiveFilters {
                Button("Clear") { model.clearFilters() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .accessibilityLabel("Clear filters")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var moreMenu: some View {
        Menu {
            ForEach([ClipCategory.screenshots, .pdfs]) { category in
                Button { model.category = category } label: { Label(category.displayName, systemImage: Theme.symbol(for: category)) }
            }
        } label: {
            Text([ClipCategory.screenshots, .pdfs].contains(model.category) ? model.category.displayName : "More")
                .font(.system(size: 12, weight: [ClipCategory.screenshots, .pdfs].contains(model.category) ? .semibold : .regular))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 6)
    }

    private func chip(_ category: ClipCategory) -> some View {
        let selected = model.category == category
        return Button { model.category = category } label: {
            // Plain labels; only the active filter gets a tinted background.
            Text(category.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.displayName) filter")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var appMenu: some View {
        Menu {
            Button("All Apps") { model.appFilter = nil }
            Divider()
            ForEach(model.sourceApps.prefix(40)) { usage in
                Button {
                    model.appFilter = usage.app
                } label: {
                    if let icon = ImageCache.shared.appIcon(bundleID: usage.app.bundleID) {
                        Label { Text("\(usage.app.name)  (\(usage.clipCount))") } icon: { Image(nsImage: icon) }
                    } else {
                        Text("\(usage.app.name)  (\(usage.clipCount))")
                    }
                }
            }
        } label: {
            Label(model.appFilter?.name ?? "App", systemImage: "app.dashed")
                .font(.system(size: 12, weight: model.appFilter == nil ? .regular : .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Filter by source app")
    }

    private var dateMenu: some View {
        Menu {
            Button("Any Time") { model.dateFilter = nil }
            Divider()
            ForEach(DateFilter.presets, id: \.self) { preset in
                Button(preset.displayName) { model.dateFilter = preset }
            }
        } label: {
            Label(model.dateFilter?.displayName ?? "Date", systemImage: "calendar")
                .font(.system(size: 12, weight: model.dateFilter == nil ? .regular : .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Filter by date")
    }
}

// MARK: - List

struct ClipListView: View {
    @Bindable var model: PanelViewModel
    let app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(app.pendingCaptures) { pending in
                PendingCaptureBanner(pending: pending, app: app)
            }
            if model.results.isEmpty && !model.isLoading {
                EmptyStateView(model: model, app: app)
            } else {
                list
            }
        }
    }

    private var sectionTitle: String {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty { return "Best matches" }
        switch model.sidebar {
        case .history: return "History"
        case .pinned: return "Pinned"
        case .space(let id): return app.spaces.first { $0.id == id }?.name ?? "Space"
        }
    }

    private var list: some View {
        let density = app.preferences.density
        let showIcons = app.preferences.showSourceIcons
        let spaces = app.spaces
        let library = app.library
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text(sectionTitle.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, clip in
                        ClipRowView(clip: clip, index: index, isSelected: clip.id == model.selectedID,
                                    isMultiSelected: model.multiSelection.contains(clip.id), density: density,
                                    showSourceIcon: showIcons, spaces: spaces,
                                    thumbnailURL: clip.thumbnailKey.map { library.thumbnailURL(for: $0) })
                            .id(clip.id)
                            .gesture(TapGesture(count: 2).onEnded { model.selectedID = clip.id; model.activate(clip.id) },
                                     including: app.preferences.singleClickPastes ? .none : .all)
                            .simultaneousGesture(TapGesture().modifiers(.command).onEnded { model.toggleMultiSelection(clip.id) })
                            .onTapGesture {
                                model.multiSelection.removeAll()
                                model.selectedID = clip.id
                                if app.preferences.singleClickPastes {
                                    model.activate(clip.id, plainText: NSEvent.modifierFlags.contains(.shift), forceCopy: NSEvent.modifierFlags.contains(.option))
                                }
                            }
                            .contextMenu { ClipContextMenu(clip: clip, model: model, app: app) }
                            .onAppear { model.loadMoreIfNeeded(currentID: clip.id) }
                    }
                    if model.hasMore {
                        ProgressView().controlSize(.small).padding(8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target)
                model.scrollTarget = nil
            }
            .accessibilityLabel("Clips")
        }
    }
}

struct EmptyStateView: View {
    let model: PanelViewModel
    let app: AppModel

    var body: some View {
        VStack(spacing: 10) {
            if !model.searchText.isEmpty || model.hasActiveFilters {
                Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text(model.searchText.isEmpty ? "No clips match these filters" : "No clips match “\(model.searchText)”").font(.headline)
                Text("Try fewer words, or search inside images with words you remember from them.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if model.hasActiveFilters { Button("Clear Filters") { model.clearFilters() } }
            } else if case .pinned = model.sidebar {
                Image(systemName: "pin").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("No pinned clips").font(.headline)
                Text("Press ⌘P on a clip to keep it here for quick access.").font(.callout).foregroundStyle(.secondary)
            } else if case .space = model.sidebar {
                Image(systemName: "folder").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("This Space is empty").font(.headline)
                Text("Right-click any clip and choose Add to Space.").font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: "doc.on.clipboard").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("Your clipboard history starts here").font(.headline)
                Text("Copy text, images, links or files anywhere on your Mac.\n\(Branding.productName) keeps them so you can find them again.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if app.preferences.monitoringPaused {
                    Button("Resume Monitoring") { app.setPaused(false) }
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PendingCaptureBanner: View {
    let pending: PendingCapture
    let app: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.yellow).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Possible \(pending.findings.first?.displayName.lowercased() ?? "sensitive content") copied")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("From \(pending.prepared.sourceApp?.name ?? "an unknown app") · not saved yet")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Discard") { app.resolvePending(pending, decision: .discard) }
            if app.privateStorageAvailable {
                Button("Save Privately") { app.resolvePending(pending, decision: .saveAsPrivate) }
            }
            Button("Save") { app.resolvePending(pending, decision: .save) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Footer

struct FooterView: View {
    let model: PanelViewModel
    let app: AppModel
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { app.setPaused(!app.preferences.monitoringPaused) } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(app.preferences.monitoringPaused ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text(app.preferences.monitoringPaused ? "Paused" : "Recording")
                }
            }
            .buttonStyle(.plain)
            .help(app.preferences.monitoringPaused ? "Resume clipboard monitoring" : "Pause clipboard monitoring")
            .accessibilityLabel(app.preferences.monitoringPaused ? "Monitoring paused. Resume." : "Monitoring on. Pause.")

            Text(countText).monospacedDigit()

            Spacer(minLength: 8)

            if let notice = app.notice {
                Label(notice.message, systemImage: icon(for: notice.style))
                    .foregroundStyle(color(for: notice.style))
                    .lineLimit(1)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
                    .onTapGesture { app.dismissNotice() }
            } else {
                HStack(spacing: 12) {
                    hint("↩", "Paste")
                    hint("⇧↩", "Plain text")
                    hint("⌥↩", "Copy")
                    hint("Space", "Preview")
                }
                .accessibilityHidden(true)
            }
            Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var countText: String {
        if !model.searchText.isEmpty || model.hasActiveFilters || model.sidebar != .history {
            let n = model.resultCount ?? model.results.count
            return "\(n.formatted()) result\(n == 1 ? "" : "s")"
        }
        return "\(app.totalClipCount.formatted()) clip\(app.totalClipCount == 1 ? "" : "s")"
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: key)
            Text(label)
        }
    }

    private func icon(for style: Notice.Style) -> String {
        switch style {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(for style: Notice.Style) -> Color {
        switch style {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Lock

struct LockedView: View {
    let app: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("\(Branding.productName) is locked").font(.title3.weight(.semibold))
            Text("Your clipboard history is hidden. Copying still works as usual.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Unlock with \(app.lock.biometryDescription)") {
                Task { await app.lock.authenticate(reason: "show your clipboard history") }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            if let error = app.lock.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
