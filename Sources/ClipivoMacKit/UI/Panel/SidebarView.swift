import SwiftUI
import ClipivoCore

struct SidebarView: View {
    @Bindable var model: PanelViewModel
    let app: AppModel
    @State private var renamingID: Int64?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row(.history, title: "History", icon: "clock.arrow.circlepath", count: app.totalClipCount)
                    row(.pinned, title: "Pinned", icon: "pin", count: app.pinnedCount)

                    HStack {
                        Text("Spaces")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { model.newSpaceForIDs = [] } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New Space (⌘N)")
                        .accessibilityLabel("New Space")
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                    ForEach(app.spaces) { space in
                        if renamingID == space.id {
                            TextField("Name", text: $renameText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5))
                                .focused($renameFocused)
                                .onSubmit { commitRename(space) }
                                .onExitCommand { renamingID = nil }
                                .padding(.horizontal, 6)
                                .onAppear { renameFocused = true }
                        } else {
                            row(.space(space.id), title: space.name, icon: space.icon, count: space.clipCount, pinned: space.isPinned)
                                .contextMenu { spaceMenu(space) }
                                .onDrag { NSItemProvider(object: "space:\(space.id)" as NSString) }
                                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                                    handleReorderDrop(providers, onto: space)
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .background(VisualEffectBackground(material: .sidebar, blending: .withinWindow).opacity(0.6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }

    private func row(_ selection: SidebarSelection, title: String, icon: String, count: Int?, pinned: Bool = false) -> some View {
        let selected = model.sidebar == selection
        return Button { model.sidebar = selection } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12.5))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                if let count, count > 0 {
                    Text(count.formatted(.number.notation(.compactName)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func spaceMenu(_ space: Space) -> some View {
        Button("Rename…") { renameText = space.name; renamingID = space.id }
        Menu("Icon") {
            ForEach(Theme.spaceIcons, id: \.self) { icon in
                Button { app.setSpaceIcon(space.id, icon) } label: { Label(icon, systemImage: icon) }
            }
        }
        Button(space.isPinned ? "Unpin Space" : "Pin Space to Top") { app.setSpacePinned(space.id, !space.isPinned) }
        if let index = app.spaces.firstIndex(where: { $0.id == space.id }) {
            Divider()
            Button("Move Up") { move(from: index, by: -1) }.disabled(index == 0)
            Button("Move Down") { move(from: index, by: 1) }.disabled(index == app.spaces.count - 1)
        }
        Divider()
        Button("Delete Space…", role: .destructive) {
            if model.sidebar == .space(space.id) { model.sidebar = .history }
            app.deleteSpace(space)
        }
    }

    private func commitRename(_ space: Space) {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { app.renameSpace(space.id, name) }
        renamingID = nil
    }

    private func move(from index: Int, by delta: Int) {
        var ids = app.spaces.map(\.id)
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        app.reorderSpaces(ids)
    }

    private func handleReorderDrop(_ providers: [NSItemProvider], onto target: Space) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, string.hasPrefix("space:"), let id = Int64(string.dropFirst(6)) else { return }
            Task { @MainActor in
                var ids = app.spaces.map(\.id)
                guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target.id), from != to else { return }
                ids.remove(at: from)
                ids.insert(id, at: to)
                app.reorderSpaces(ids)
            }
        }
        return true
    }
}

// MARK: - Editors

/// Centered card over a dimmed panel, used for small in-panel editors (no separate windows,
/// so the app the user is pasting into stays active).
struct ModalCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            content
                .padding(18)
                .frame(width: 340)
                .background(VisualEffectBackground(material: .hudWindow, blending: .withinWindow))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
        }
        .accessibilityAddTraits(.isModal)
    }
}

struct TitleEditor: View {
    let clip: ClipSummary
    let onSave: (String?) -> Void
    let onCancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(clip: ClipSummary, onSave: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self.clip = clip
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: clip.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(clip.title == nil ? "Add Title" : "Edit Title").font(.headline)
            TextField("e.g. Production API endpoint", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { onSave(text) }
            Text("Titles are searchable and never replaced automatically.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if clip.title != nil {
                    Button("Remove Title", role: .destructive) { onSave(nil) }
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text) }.keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { focused = true }
    }
}

struct TagEditor: View {
    let clip: ClipSummary
    let app: AppModel
    let onDone: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags").font(.headline)
            if !clip.tags.isEmpty {
                FlowTags(tags: clip.tags) { tag in app.removeTag(tag, from: [clip.id]) }
            }
            TextField("Add a tag and press Return", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    let tag = text.trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty { app.addTag(tag, to: [clip.id]) }
                    text = ""
                }
            Text("Search tags with tag:name.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { focused = true }
    }
}

struct FlowTags: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text("#" + tag).font(.system(size: 12))
                    Button { onRemove(tag) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }
        }
    }
}

struct NewSpaceEditor: View {
    let count: Int
    let onCreate: (String, String) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var icon = "folder"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Space").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 8), spacing: 6) {
                ForEach(Theme.spaceIcons, id: \.self) { symbol in
                    Button { icon = symbol } label: {
                        Image(systemName: symbol)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(icon == symbol ? Color.accentColor.opacity(0.2) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                }
            }
            if count > 0 {
                Text("\(count) selected clip\(count == 1 ? "" : "s") will be added.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private func create() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        onCreate(clean, icon)
    }
}
