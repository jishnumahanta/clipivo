import SwiftUI
import AppKit
import ClipivoCore

struct ClipRowView: View {
    let clip: ClipSummary
    let index: Int
    let isSelected: Bool
    let isMultiSelected: Bool
    let density: ListDensity
    let showSourceIcon: Bool
    let spaces: [Space]
    let thumbnailURL: URL?

    var body: some View {
        HStack(spacing: density == .compact ? 8 : 11) {
            ClipTile(clip: clip, size: Theme.tileSize(density), thumbnailURL: thumbnailURL)

            if density == .compact {
                Text(clip.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(clip.isPrivate ? .secondary : .primary)
                Spacer(minLength: 8)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if clip.title != nil {
                            Image(systemName: "character.cursor.ibeam")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Text(clip.displayTitle)
                            .font(.system(size: 13, weight: clip.title != nil ? .semibold : .regular, design: clip.kind == .code ? .monospaced : .default))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(clip.isPrivate ? .secondary : .primary)
                    }
                    // "App · time · detail", like the website's list rows.
                    HStack(spacing: 4) {
                        if showSourceIcon, let bundle = clip.sourceApp?.bundleID, let icon = ImageCache.shared.appIcon(bundleID: bundle) {
                            Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                        }
                        Text(clip.sourceApp?.name ?? "Unknown").fixedSize()
                        Text("·").foregroundStyle(.tertiary)
                        Text(RelativeTime.short(clip.lastUsedAt)).fixedSize()
                        let subtitle = clip.subtitle.isEmpty ? clip.kind.displayName : clip.subtitle
                        Text("·").foregroundStyle(.tertiary)
                        Text(subtitle).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
            }

            meta
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.rowHeight(density))
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : (isMultiSelected ? Color.accentColor.opacity(0.12) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Press Return to paste, Space to preview")
    }

    private var meta: some View {
        HStack(spacing: 6) {
            let memberSpaces = spaces.filter { clip.spaceIDs.contains($0.id) }
            ForEach(memberSpaces.prefix(2)) { space in
                Image(systemName: space.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(space.name)
            }
            if !clip.tags.isEmpty && density == .comfortable {
                Text("#" + clip.tags[0])
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Pinned")
            }
            if density == .compact {
                Text(RelativeTime.short(clip.lastUsedAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            if index < 9 {
                KeyCap(text: "⌘\(index + 1)", highlighted: isSelected)
                    .opacity(isSelected ? 1 : 0.75)
            } else {
                Color.clear.frame(width: 26)
            }
        }
    }
}

/// The context menu for a clip. Only actions that apply to the clip's type are shown.
struct ClipContextMenu: View {
    let clip: ClipSummary
    let model: PanelViewModel
    let app: AppModel

    var body: some View {
        let ids = model.targetIDs.contains(clip.id) ? model.targetIDs : [clip.id]
        let multi = ids.count > 1

        if !multi {
            Button("Paste") { model.selectedID = clip.id; model.activate(clip.id) }
            Button("Paste as Plain Text") { model.selectedID = clip.id; model.activate(clip.id, plainText: true) }
            Button("Copy") { model.activate(clip.id, forceCopy: true) }
            Button("Quick Look") { model.selectedID = clip.id; model.quickLookID = clip.id }
            Divider()
        }

        Button(clip.isPinned ? "Unpin" : "Pin") { app.setPinned(ids, !clip.isPinned) }
        Menu("Add to Space") {
            ForEach(app.spaces) { space in
                Button {
                    app.add(ids, toSpace: space.id)
                } label: {
                    Label(space.name, systemImage: clip.spaceIDs.contains(space.id) ? "checkmark" : space.icon)
                }
            }
            Divider()
            Button("New Space…") { model.newSpaceForIDs = ids }
        }
        let memberSpaces = app.spaces.filter { clip.spaceIDs.contains($0.id) }
        if !memberSpaces.isEmpty {
            Menu("Remove from Space") {
                ForEach(memberSpaces) { space in
                    Button(space.name) { app.remove(ids, fromSpace: space.id) }
                }
            }
        }
        if !multi {
            Button(clip.title == nil ? "Add Title…" : "Edit Title…") { model.titleEditorID = clip.id }
            Button("Add Tag…") { model.tagEditorID = clip.id }
        }
        Divider()

        if !multi && !clip.isPrivate {
            typeSpecificActions
            Divider()
        }

        if !multi, let source = clip.sourceApp {
            Button("Show Only Clips from \(source.name)") { model.appFilter = source }
        }
        if !multi {
            Button(clip.isPrivate ? "Remove Private Mark" : "Mark as Private") { app.setPrivate(clip.id, !clip.isPrivate) }
        }
        Divider()
        Button(multi ? "Delete \(ids.count) Clips" : "Delete", role: .destructive) {
            if !model.targetIDs.contains(clip.id) { model.selectedID = clip.id }
            model.deleteTargets()
        }
        if !multi {
            Button("Delete Similar Clips") { app.deleteSimilar(to: clip.id) }
            if let source = clip.sourceApp {
                Button("Delete All from \(source.name)…") { app.deleteAll(fromSource: source.bundleID, name: source.name) }
                Button("Never Save Clips from \(source.name)") { app.ignoreApp(bundleID: source.bundleID, name: source.name) }
            }
        }
    }

    @ViewBuilder private var typeSpecificActions: some View {
        switch clip.kind {
        case .image, .screenshot:
            Button("Copy Image") { model.activate(clip.id, forceCopy: true) }
            Button("Copy Text from Image") { app.copyTextFromImage(clip.id) }
            Button("Save Image As…") { withContent { ClipActions.export($0) } }
        case .url:
            Button("Open Link") { withContent { ClipActions.open($0) } }
            Button("Copy Link") { model.activate(clip.id, plainText: true, forceCopy: true) }
        case .file, .folder:
            Button("Open") { withContent { ClipActions.open($0) } }
            Button("Reveal in Finder") { withContent { ClipActions.revealInFinder($0) } }
            Button("Copy Path") { model.activate(clip.id, plainText: true, forceCopy: true) }
        case .color:
            if let color = ColorParser.parse(clip.metadata.colorHex ?? "") {
                Menu("Copy Color As") {
                    Button(color.hex) { app.copyText(color.hex) }
                    Button(color.rgbString) { app.copyText(color.rgbString) }
                    Button(color.hslString) { app.copyText(color.hslString) }
                }
            }
        case .email:
            Button("Compose Email") { withContent { ClipActions.open($0) } }
            Button("Copy Text") { model.activate(clip.id, plainText: true, forceCopy: true) }
        case .richText, .code:
            Button("Copy as Plain Text") { model.activate(clip.id, plainText: true, forceCopy: true) }
            Button("Export…") { withContent { ClipActions.export($0) } }
        case .pdf:
            Button("Export PDF…") { withContent { ClipActions.export($0) } }
        default:
            Button("Copy Text") { model.activate(clip.id, plainText: true, forceCopy: true) }
            Button("Export…") { withContent { ClipActions.export($0) } }
        }
    }

    private func withContent(_ body: @escaping @MainActor (ClipContent) -> Void) {
        Task { @MainActor in
            guard let content = try? await app.library.content(id: clip.id) else { return }
            body(content)
        }
    }
}
