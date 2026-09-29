import AppKit
import Observation
import ClipivoCore

public enum SidebarSelection: Hashable {
    case history
    case pinned
    case space(Int64)
}

/// State and behaviour of the clipboard panel. Holds only one window of results; more pages are
/// loaded as the user scrolls or navigates, so history size does not affect memory.
@MainActor
@Observable
public final class PanelViewModel {
    public static let pageSize = 80

    let app: AppModel

    public var searchText = "" { didSet { if searchText != oldValue { queryChanged() } } }
    public var category: ClipCategory = .all { didSet { if category != oldValue { queryChanged(immediate: true) } } }
    public var sidebar: SidebarSelection = .history { didSet { if sidebar != oldValue { queryChanged(immediate: true) } } }
    public var appFilter: SourceApplication? { didSet { if appFilter != oldValue { queryChanged(immediate: true) } } }
    public var dateFilter: DateFilter? { didSet { if dateFilter != oldValue { queryChanged(immediate: true) } } }

    public private(set) var results: [ClipSummary] = []
    public private(set) var resultCount: Int?
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    public var selectedID: Int64?
    /// Extra selected clips (⌘-click / ⇧-arrows) for bulk actions.
    public var multiSelection: Set<Int64> = []
    public private(set) var sourceApps: [SourceAppUsage] = []

    // Overlays
    public var quickLookID: Int64? { didSet { if (quickLookID == nil) != (oldValue == nil) { onQuickLookToggled?(quickLookID != nil) } } }
    @ObservationIgnored var onQuickLookToggled: ((Bool) -> Void)?
    public var titleEditorID: Int64?
    public var tagEditorID: Int64?
    public var newSpaceForIDs: [Int64]?
    public var deliveryChoiceID: Int64?
    public var isSearchFocused = true
    public var scrollTarget: Int64?

    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observedVersion = -1

    public init(app: AppModel) {
        self.app = app
    }

    // MARK: - Query

    var currentQuery: ClipQuery {
        var query = ClipQuery(text: searchText.trimmingCharacters(in: .whitespaces))
        query.kinds = category.kinds
        query.fields = app.preferences.searchFields
        if let appFilter { query.sourceBundleIDs = [appFilter.bundleID] }
        query.dateFilter = dateFilter
        switch sidebar {
        case .history: break
        case .pinned: query.pinnedOnly = true
        case .space(let id): query.spaceID = id
        }
        query.sort = query.text.isEmpty ? .recent : .relevance
        return query
    }

    var hasActiveFilters: Bool {
        category != .all || appFilter != nil || dateFilter != nil
    }

    func clearFilters() {
        category = .all
        appFilter = nil
        dateFilter = nil
    }

    private func queryChanged(immediate: Bool = false) {
        multiSelection.removeAll()
        reload(keepSelection: false, debounce: immediate ? 0 : 45)
    }

    /// Re-runs the query. With `keepSelection`, the loaded range and selection are preserved
    /// (used when the library changes underneath an open panel).
    func reload(keepSelection: Bool, debounce: Int = 0) {
        queryTask?.cancel()
        generation += 1
        let gen = generation
        let limit = keepSelection ? max(Self.pageSize, results.count) : Self.pageSize
        var query = currentQuery
        query.limit = limit + 1
        let library = app.library
        isLoading = true
        queryTask = Task { @MainActor in
            if debounce > 0 { try? await Task.sleep(for: .milliseconds(debounce)) }
            guard !Task.isCancelled else { return }
            do {
                var page = try await library.fetch(query)
                guard gen == generation else { return }
                hasMore = page.count > limit
                if hasMore { page.removeLast() }
                let previousSelection = selectedID
                results = page
                if keepSelection, let previousSelection, page.contains(where: { $0.id == previousSelection }) {
                    selectedID = previousSelection
                } else {
                    selectedID = page.first?.id
                    scrollTarget = page.first?.id
                }
                multiSelection = multiSelection.filter { id in page.contains { $0.id == id } }
                isLoading = false
                // Counting can be slower on huge searches; do it after results are on screen.
                let count = try await library.count(query)
                if gen == generation { resultCount = count }
            } catch {
                if gen == generation { isLoading = false }
            }
        }
    }

    func loadMoreIfNeeded(currentID: Int64) {
        guard hasMore, !isLoading, let index = results.firstIndex(where: { $0.id == currentID }), index >= results.count - 15 else { return }
        isLoading = true
        var query = currentQuery
        query.offset = results.count
        query.limit = Self.pageSize + 1
        let gen = generation
        let library = app.library
        Task { @MainActor in
            defer { if gen == generation { isLoading = false } }
            guard var page = try? await library.fetch(query), gen == generation else { return }
            hasMore = page.count > Self.pageSize
            if hasMore { page.removeLast() }
            let existing = Set(results.map(\.id))
            results.append(contentsOf: page.filter { !existing.contains($0.id) })
        }
    }

    /// Called when the panel opens and whenever the library version changes.
    func refreshIfLibraryChanged() {
        guard observedVersion != app.libraryVersion else { return }
        observedVersion = app.libraryVersion
        reload(keepSelection: true)
    }

    func loadSourceApps() {
        Task { sourceApps = (try? await app.library.sourceApps()) ?? [] }
    }

    /// Resets transient state when the panel is shown.
    func prepareForShow() {
        quickLookID = nil
        titleEditorID = nil
        tagEditorID = nil
        newSpaceForIDs = nil
        deliveryChoiceID = nil
        isSearchFocused = true
        observedVersion = -1
        refreshIfLibraryChanged()
        loadSourceApps()
    }

    func resetSearch() {
        searchText = ""
        clearFilters()
        sidebar = .history
    }

    // MARK: - Selection

    var selectedSummary: ClipSummary? {
        guard let selectedID else { return nil }
        return results.first { $0.id == selectedID }
    }

    /// Clips targeted by an action: the multi-selection if any, otherwise the selected clip.
    var targetIDs: [Int64] {
        if !multiSelection.isEmpty {
            var ids = multiSelection
            if let selectedID { ids.insert(selectedID) }
            return results.map(\.id).filter { ids.contains($0) }
        }
        return selectedID.map { [$0] } ?? []
    }

    func moveSelection(by delta: Int, extend: Bool = false) {
        guard !results.isEmpty else { return }
        let current = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? -1
        let next = min(max(current + delta, 0), results.count - 1)
        if extend, let selectedID { multiSelection.insert(selectedID) } else if !extend { multiSelection.removeAll() }
        selectedID = results[next].id
        if extend { multiSelection.insert(results[next].id) }
        scrollTarget = results[next].id
        loadMoreIfNeeded(currentID: results[next].id)
    }

    func selectFirst() {
        guard let first = results.first else { return }
        selectedID = first.id
        scrollTarget = first.id
    }

    func selectLast() {
        guard let last = results.last else { return }
        selectedID = last.id
        scrollTarget = last.id
        loadMoreIfNeeded(currentID: last.id)
    }

    func toggleMultiSelection(_ id: Int64) {
        if multiSelection.contains(id) { multiSelection.remove(id) } else {
            if let selectedID, multiSelection.isEmpty { multiSelection.insert(selectedID) }
            multiSelection.insert(id)
        }
        selectedID = id
    }

    func clip(at index: Int) -> ClipSummary? {
        results.indices.contains(index) ? results[index] : nil
    }

    // MARK: - Actions

    func activate(_ id: Int64?, plainText: Bool = false, forceCopy: Bool = false) {
        guard let id else { return }
        if app.lock.isLocked { return }
        let behavior = app.preferences.pasteBehavior
        if forceCopy || behavior == .copyOnly {
            Task { await app.deliver(id, as: .copy, plainText: plainText) }
        } else if behavior == .ask && deliveryChoiceID == nil {
            deliveryChoiceID = id
        } else {
            Task { await app.deliver(id, as: .paste, plainText: plainText) }
        }
    }

    func deleteTargets() {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        // Move the selection to the neighbour so keyboard deletion can continue.
        if let last = ids.last, let index = results.firstIndex(where: { $0.id == last }) {
            let remaining = results.filter { !ids.contains($0.id) }
            let neighbour = remaining.indices.contains(index - ids.count + 1) ? remaining[index - ids.count + 1] : remaining.last
            selectedID = neighbour?.id
        }
        multiSelection.removeAll()
        results.removeAll { ids.contains($0.id) }
        app.delete(ids)
    }

    func togglePinTargets() {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        let pin = !(results.first { $0.id == ids[0] }?.isPinned ?? false)
        app.setPinned(ids, pin)
    }
}
