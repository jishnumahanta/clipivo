import SwiftUI
import AppKit
import ClipivoCore

/// Full-width strip of clip cards docked to a screen edge. Click a card to paste it into the
/// app you were using; the clip also becomes the newest clipboard item.
struct ShelfView: View {
    @Bindable var model: PanelViewModel
    let app: AppModel
    let onOpenSettings: () -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ForEach(app.pendingCaptures) { PendingCaptureBanner(pending: $0, app: app) }
            HStack(spacing: 0) {
                if app.preferences.showSidebar {
                    SidebarView(model: model, app: app)
                        .frame(width: Theme.sidebarWidth)
                    Divider()
                }
                ZStack {
                    if model.results.isEmpty && !model.isLoading {
                        EmptyStateView(model: model, app: app)
                    } else {
                        cards
                    }
                    if let id = model.quickLookID {
                        QuickLookView(clipID: id, app: app) { model.quickLookID = nil }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(10)
                            .transition(.opacity)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { toast }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.quickLookID)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: app.notice)
        .onChange(of: model.isSearchFocused) { _, focused in searchFocused = focused }
        .onChange(of: searchFocused) { _, focused in model.isSearchFocused = focused }
        .onAppear { searchFocused = true }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { app.preferences.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show or hide Spaces").accessibilityLabel("Toggle Spaces sidebar")

            Button { app.setPaused(!app.preferences.monitoringPaused) } label: {
                Circle().fill(app.preferences.monitoringPaused ? Color.orange : Color.green).frame(width: 7, height: 7)
            }
            .buttonStyle(.plain)
            .help(app.preferences.monitoringPaused ? "Monitoring paused — click to resume" : "Recording — click to pause")
            .accessibilityLabel(app.preferences.monitoringPaused ? "Monitoring paused. Resume." : "Monitoring on. Pause.")

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { model.activate(model.selectedID) }
                    .accessibilityLabel("Search clipboard history")
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.85)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(searchFocused ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: searchFocused ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: searchFocused)

            FilterBar(model: model)
                .padding(.bottom, -8) // FilterBar carries bottom padding for the list layout

            Text(countText).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Settings (⌘,)").accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var countText: String {
        if !model.searchText.isEmpty || model.hasActiveFilters || model.sidebar != .history {
            let n = model.resultCount ?? model.results.count
            return "\(n.formatted()) result\(n == 1 ? "" : "s")"
        }
        return "\(app.totalClipCount.formatted()) clips"
    }

    // MARK: Cards

    private var cards: some View {
        let library = app.library
        let spaces = app.spaces
        return GeometryReader { geo in
            let cardHeight = max(120, geo.size.height - 22)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, clip in
                            ClipCardView(clip: clip, index: index, isSelected: clip.id == model.selectedID,
                                         isMultiSelected: model.multiSelection.contains(clip.id), spaces: spaces,
                                         thumbnailURL: clip.thumbnailKey.map { library.thumbnailURL(for: $0) },
                                         onTogglePin: { app.setPinned([clip.id], !clip.isPinned) })
                                .frame(width: min(224, cardHeight * 1.02), height: cardHeight)
                                .id(clip.id)
                                .onTapGesture { handleClick(clip) }
                                .contextMenu { ClipContextMenu(clip: clip, model: model, app: app) }
                                .onAppear { model.loadMoreIfNeeded(currentID: clip.id) }
                        }
                        if model.hasMore { ProgressView().controlSize(.small).frame(width: 60) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .scrollIndicators(.never)
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    if reduceMotion { proxy.scrollTo(target, anchor: .center) }
                    else { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) } }
                    model.scrollTarget = nil
                }
            }
        }
        .accessibilityLabel("Clips")
    }

    private func handleClick(_ clip: ClipSummary) {
        if NSEvent.modifierFlags.contains(.command) { model.toggleMultiSelection(clip.id); return }
        model.handleClick(clip.id)
    }

    @ViewBuilder private var toast: some View {
        if let notice = app.notice {
            // Inverted pill (dark on light, light on dark), bottom centre — same as the website.
            HStack(spacing: 7) {
                Image(systemName: notice.style == .error ? "xmark.octagon.fill" : notice.style == .warning ? "exclamationmark.triangle.fill" : "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(notice.style == .error ? Color.red : notice.style == .warning ? Color.orange : Color.green)
                Text(notice.message).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color(nsColor: .labelColor)))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { app.dismissNotice() }
        }
    }
}

/// One clip as a card: a large preview of the content with the source app, age and shortcut underneath.
struct ClipCardView: View {
    let clip: ClipSummary
    let index: Int
    let isSelected: Bool
    let isMultiSelected: Bool
    let spaces: [Space]
    let thumbnailURL: URL?
    var onTogglePin: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            footer
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.94)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : (isMultiSelected ? Color.accentColor.opacity(0.5) : Theme.hairline),
                              lineWidth: isSelected ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(hovering || isSelected ? 0.22 : 0.08), radius: hovering || isSelected ? 8 : 3, y: 2)
        .offset(y: hovering && !isSelected ? -2 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Click or press Return to paste")
    }

    /// Kind strip: a coloured label so types are recognisable at a glance.
    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: clip.isPrivate ? "lock.fill" : Theme.symbol(for: clip.kind))
                .font(.system(size: 10, weight: .semibold))
            Text(clip.isPrivate ? "Private" : clip.kind.displayName).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
            if let meta = headerMeta, !clip.isPrivate {
                Text("· " + meta).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let onTogglePin, hovering || clip.isPinned {
                Button(action: onTogglePin) {
                    Image(systemName: clip.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                }
                .buttonStyle(.plain)
                .help(clip.isPinned ? "Unpin (⌘P)" : "Pin (⌘P)")
                .accessibilityLabel(clip.isPinned ? "Unpin" : "Pin")
            } else if clip.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 9))
            }
            ForEach(spaces.filter { clip.spaceIDs.contains($0.id) }.prefix(2)) { space in
                Image(systemName: space.icon).font(.system(size: 9)).help(space.name)
            }
        }
        .foregroundStyle(clip.isPrivate ? Color.secondary : Theme.tint(for: clip.kind))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.tint(for: clip.kind).opacity(clip.isPrivate ? 0.04 : 0.12))
    }

    /// Secondary header detail, e.g. "Shell", "1920×1080", "3 pages".
    private var headerMeta: String? {
        switch clip.kind {
        case .code: return clip.metadata.codeLanguage.map(CodeDetector.displayName)
        case .image, .screenshot:
            if let w = clip.metadata.imageWidth, let h = clip.metadata.imageHeight { return "\(w)×\(h)" }
            return nil
        case .pdf: return clip.metadata.pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" }
        case .file, .folder:
            if let count = clip.metadata.fileCount, count > 1 { return "\(count) items" }
            return nil
        default: return nil
        }
    }

    @ViewBuilder private var preview: some View {
        if clip.isPrivate {
            VStack(spacing: 6) {
                Image(systemName: "eye.slash").font(.system(size: 22)).foregroundStyle(.secondary)
                Text(clip.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch clip.kind {
            case .image, .screenshot, .pdf:
                ZStack {
                    Color.black.opacity(0.18)
                    if let thumbnailURL {
                        CardThumbnail(url: thumbnailURL)
                    } else {
                        Image(systemName: Theme.symbol(for: clip.kind)).font(.system(size: 26)).foregroundStyle(.secondary)
                    }
                }
            case .color:
                if let color = ColorParser.parse(clip.metadata.colorHex ?? "") {
                    ZStack(alignment: .bottomLeading) {
                        Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
                        Text(color.hex)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
            case .url:
                VStack(alignment: .leading, spacing: 6) {
                    Text(clip.metadata.urlHost.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "Link")
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if let title = clip.metadata.urlTitle { Text(title).font(.system(size: 12)).lineLimit(2) }
                    Text(clip.previewText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4)
                }
                .padding(10)
            case .file, .folder:
                VStack(spacing: 8) {
                    if let path = clip.previewText.split(separator: "\n").first {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: String(path))).resizable().frame(width: 56, height: 56)
                    }
                    Text(clip.autoTitle ?? clip.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .code:
                Text(AttributedString(SyntaxHighlighter.highlight(String(clip.previewText.prefix(900)), language: clip.metadata.codeLanguage, fontSize: 11)))
                    .padding(10)
            default:
                VStack(alignment: .leading, spacing: 4) {
                    if let title = clip.title {
                        Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    }
                    Text(String(clip.previewText.prefix(900)).trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12.5))
                        .lineSpacing(1.5)
                        .foregroundStyle(clip.title == nil ? .primary : .secondary)
                }
                .padding(10)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if let bundle = clip.sourceApp?.bundleID, let icon = ImageCache.shared.appIcon(bundleID: bundle) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(clip.sourceApp?.name ?? "Unknown").lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Text(RelativeTime.short(clip.lastUsedAt)).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

private struct CardThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? ImageCache.shared.cachedThumbnail(at: url) {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit).padding(6)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            guard ImageCache.shared.cachedThumbnail(at: url) == nil else { return }
            let path = url
            if let loaded = await loadImageOffMain({ NSImage(contentsOf: path) }) {
                ImageCache.shared.store(loaded, for: url)
                image = loaded
            }
        }
    }
}
