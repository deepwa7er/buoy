import BuoyCore
import SwiftUI

#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class ThoughtListModel {
    /// Loaded window of the stream, newest first. Grows toward older
    /// thoughts as the user scrolls back through history.
    var thoughts: [Thought] = []
    var draft: String = ""
    var errorMessage: String?
    /// When non-nil, `save` will update the existing thought instead of
    /// creating a new one. Cleared on save or cancel.
    var editingId: String?
    /// Results for the search query currently in the search field.
    var searchResults: [ThoughtMatch] = []
    /// Related past thoughts for the draft currently in the composer.
    var suggestions: [ThoughtMatch] = []
    /// Related thoughts expanded under stream rows, keyed by thought id.
    var relatedExpanded: [String: [ThoughtMatch]] = [:]

    /// Live sync state, surfaced in the UI. `lastSynced` is the time of the last
    /// *successful* reconcile and persists across later failures.
    var status: SyncStatus = .idle
    var lastSynced: Date?

    private var store: ThoughtStore?
    private var syncTask: Task<Void, Never>?
    /// Cursor for the page after the oldest loaded thought; nil when the
    /// entire stream is loaded.
    private var nextCursor: Cursor?
    private var isLoadingOlder = false
    private var searchTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    /// The exact draft for which the user dismissed the suggestion strip;
    /// it stays hidden until the draft text changes again.
    private var dismissedSuggestionsDraft: String?

    /// How close to the oldest loaded thought a row must be (in rows) to
    /// trigger fetching the next page.
    private static let loadOlderMargin = 5

    var isEditing: Bool { editingId != nil }

    func open() async {
        do {
            let path = try BuoyStore.url().path
            store = try ThoughtStore.open(path: path)
            await refresh()
            attachEmbedderInBackground()
            syncNow()
        } catch {
            errorMessage = "Failed to open store: \(error.localizedDescription)"
        }
    }

    /// Fire-and-forget reconcile, for triggers that don't need to wait (open,
    /// capture, foreground).
    func syncNow() {
        Task { await sync() }
    }

    /// Reconcile with the server: push local changes, pull remote ones. Runs the
    /// store + network work off the main actor and refreshes the stream if any
    /// remote changes landed. A failure (offline, server down) is recorded and
    /// retried on the next trigger — captures never depend on it.
    ///
    /// Awaits completion, and coalesces onto an in-flight reconcile if one is
    /// already running — so callers that must wait (pull-to-refresh) block until
    /// the work actually finishes rather than returning instantly.
    func sync() async {
        if let inFlight = syncTask {
            await inFlight.value
            return
        }
        guard let store else { return }
        status = .syncing
        let task = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                try await SyncService.reconcilePersisting(store: store, baseURL: buoyServerURL)
            }.result
            guard let self else { return }
            switch outcome {
            case let .success(applied):
                self.lastSynced = Date()
                self.status = .idle
                if applied > 0 { await self.refresh() }
            case let .failure(error):
                self.status = Self.classify(error)
            }
            self.syncTask = nil
        }
        syncTask = task
        await task.value
    }

    /// Map a reconcile failure to a status: connectivity errors become
    /// `.offline` (an expected, transient condition shown without alarm),
    /// anything else `.failed` with a message.
    private static func classify(_ error: Error) -> SyncStatus {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .timedOut, .networkConnectionLost,
                 .resourceUnavailable:
                return .offline
            default:
                return .failed(urlError.localizedDescription)
            }
        }
        return .failed(String(describing: error))
    }

    /// Load the bundled embedding model and attach it off the main actor
    /// (loading takes a few hundred milliseconds), then backfill vectors
    /// for thoughts captured before the embedder was ready. Semantic
    /// search is an enhancement: with no bundled model or a load failure,
    /// search stays keyword-only and the app works normally.
    private func attachEmbedderInBackground() {
        guard let store else { return }
        Task.detached(priority: .utility) {
            guard let modelDir = Bundle.main.url(forResource: "all-MiniLM-L6-v2", withExtension: nil)
            else { return }
            do {
                try store.attachEmbedder(modelDir: modelDir.path)
                // Small batches keep the store lock holds short so captures
                // are never blocked for long during the backfill.
                while try store.embedMissing(limit: 8) > 0 {}
            } catch {
                print("buoy: semantic search unavailable: \(error)")
            }
        }
    }

    /// Reload the stream from the newest thought, covering at least the
    /// window that was already loaded so a refresh never silently shrinks
    /// what the user can see (and never disturbs their scroll position by
    /// dropping rows).
    func refresh() async {
        guard let store else { return }
        do {
            let pageSize = defaultPageSize()
            let target = max(thoughts.count, Int(pageSize))
            var loaded: [Thought] = []
            var cursor: Cursor?
            repeat {
                let page = try store.listPaginated(before: cursor, limit: pageSize)
                loaded.append(contentsOf: page.thoughts)
                cursor = page.nextCursor
            } while cursor != nil && loaded.count < target
            thoughts = loaded
            nextCursor = cursor
        } catch {
            errorMessage = "Failed to load thoughts: \(error.localizedDescription)"
        }
    }

    /// Called as stream rows appear. When one of the oldest few loaded rows
    /// becomes visible and more history exists, fetch the next page.
    func loadOlderIfNeeded(visibleId: String) async {
        guard nextCursor != nil, !isLoadingOlder else { return }
        guard thoughts.suffix(Self.loadOlderMargin).contains(where: { $0.id == visibleId }) else {
            return
        }
        await loadOlderPage()
    }

    /// Ensure the thought with `id` is in the loaded window, fetching older
    /// pages as needed so the stream can scroll to it. Returns false when
    /// the thought isn't in the stream at all (e.g. deleted mid-search) or
    /// loading stalled on an error.
    func reveal(id: String) async -> Bool {
        while !thoughts.contains(where: { $0.id == id }) {
            guard nextCursor != nil, await loadOlderPage() else { return false }
        }
        return true
    }

    /// Debounced as-you-type search: waits ~150ms after the latest
    /// keystroke, cancelling any earlier pending query.
    func searchDebounced(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ query: String) async {
        guard let store else { return }
        do {
            searchResults = try store.searchCombined(query: query, limit: 50)
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    /// Debounced related-thought lookup for the composer draft: runs
    /// ~200ms after the last keystroke, cancelling earlier pending calls.
    func suggestDebounced(draft: String) {
        suggestionTask?.cancel()
        if draft != dismissedSuggestionsDraft {
            dismissedSuggestionsDraft = nil
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, dismissedSuggestionsDraft == nil else {
            suggestions = []
            return
        }
        suggestionTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let store else { return }
            // Suggestions must never surface an error into the composer
            // flow; on any failure the strip simply doesn't appear.
            suggestions =
                (try? store.findRelated(draftText: draft, topK: 3, excludeId: editingId)) ?? []
        }
    }

    /// Hide the strip for the current draft; it returns once the draft
    /// text changes.
    func dismissSuggestions() {
        dismissedSuggestionsDraft = draft
        suggestions = []
    }

    /// Expand or collapse the related-thoughts list under a stream row.
    func toggleRelated(for thought: Thought) async {
        if relatedExpanded[thought.id] != nil {
            relatedExpanded.removeValue(forKey: thought.id)
            return
        }
        guard let store else { return }
        do {
            relatedExpanded[thought.id] = try store.findRelatedTo(id: thought.id, topK: 3)
        } catch {
            errorMessage = "Failed to load related thoughts: \(error.localizedDescription)"
        }
    }

    /// Fetch the page after the oldest loaded thought. Returns true when
    /// the loaded window actually grew.
    @discardableResult
    private func loadOlderPage() async -> Bool {
        guard let store, let cursor = nextCursor, !isLoadingOlder else { return false }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try store.listPaginated(before: cursor, limit: defaultPageSize())
            thoughts.append(contentsOf: page.thoughts)
            nextCursor = page.nextCursor
            return !page.thoughts.isEmpty
        } catch {
            errorMessage = "Failed to load older thoughts: \(error.localizedDescription)"
            return false
        }
    }

    /// Force every currently-live thought to settle. Called when the scene
    /// moves to the background so a returning user's next edit is treated
    /// as a deliberate modification rather than a continuation.
    func settleAllLive() async {
        guard let store else { return }
        do {
            try store.settleAllLive()
        } catch {
            errorMessage = "Failed to settle thoughts: \(error.localizedDescription)"
        }
    }

    func startEditing(_ thought: Thought) {
        draft = thought.text
        editingId = thought.id
    }

    func cancelEditing() {
        draft = ""
        editingId = nil
    }

    func save() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store else { return }
        do {
            if let id = editingId {
                _ = try store.update(id: id, text: text)
            } else {
                _ = try store.create(text: text)
            }
            draft = ""
            editingId = nil
            await refresh()
            syncNow()
        } catch {
            errorMessage = "Failed to save thought: \(error.localizedDescription)"
        }
    }

}

struct ContentView: View {
    @State private var model = ThoughtListModel()
    @State private var searchText = ""
    /// When set, the stream scrolls the row with this id into view. Set
    /// after `reveal` has paged the thought into the loaded window, so the
    /// row exists by the time the scroll fires.
    @State private var scrollTarget: String?
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.status.isOffline {
                    OfflineBanner()
                }
                if searchText.isEmpty {
                    stream
                    Divider()

                    if !model.suggestions.isEmpty {
                        SuggestionStrip(
                            suggestions: model.suggestions,
                            onSelect: { match in revealInStream(match.thought.id) },
                            onDismiss: { model.dismissSuggestions() }
                        )
                    }

                    if model.isEditing {
                        EditingBanner(onCancel: { model.cancelEditing() })
                    }

                    composer
                } else {
                    SearchResultsList(results: model.searchResults) { match in
                        searchText = ""
                        revealInStream(match.thought.id)
                    }
                }
            }
            .navigationTitle("Buoy")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "Search thoughts")
            .onChange(of: searchText) { _, query in
                model.searchDebounced(query)
            }
            .onChange(of: model.draft) { _, draft in
                model.suggestDebounced(draft: draft)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SyncStatusButton(model: model)
                }
            }
        }
        .task {
            await model.open()
            composerFocused = true
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                Task { await model.settleAllLive() }
                #if os(iOS)
                // Only on a true background transition — `.inactive` fires
                // transiently (app switcher, banners) and shouldn't reschedule.
                if newPhase == .background { BackgroundSync.schedule() }
                #endif
            case .active:
                // Refresh so any thoughts that crossed the settle window
                // (or were force-settled on the way out) show up correctly,
                // and reconcile with the server.
                Task { await model.refresh() }
                model.syncNow()
            @unknown default:
                break
            }
        }
        #if os(macOS)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        #endif
        .alert(
            "Error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: {
                Button("OK") { model.errorMessage = nil }
            },
            message: {
                Text(model.errorMessage ?? "")
            }
        )
    }

    /// Page the stream until `id` is loaded, then scroll it to center.
    private func revealInStream(_ id: String) {
        Task {
            if await model.reveal(id: id) {
                scrollTarget = id
            }
        }
    }

    private var stream: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(model.thoughts.reversed()), id: \.id) { thought in
                    VStack(alignment: .leading, spacing: 0) {
                        ThoughtRow(
                            thought: thought,
                            relatedExpanded: model.relatedExpanded[thought.id] != nil,
                            onToggleRelated: {
                                Task { await model.toggleRelated(for: thought) }
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.startEditing(thought)
                            composerFocused = true
                        }

                        if let related = model.relatedExpanded[thought.id] {
                            RelatedList(related: related) { match in
                                revealInStream(match.thought.id)
                            }
                        }
                    }
                    .onAppear {
                        // Oldest loaded thoughts render at the top; when
                        // one scrolls into view, pull in the next page.
                        Task { await model.loadOlderIfNeeded(visibleId: thought.id) }
                    }
                }
            }
            .listStyle(.plain)
            .defaultScrollAnchor(.bottom)
            .refreshable { await model.sync() }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation {
                    proxy.scrollTo(target, anchor: .center)
                }
                scrollTarget = nil
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.draft)
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .frame(minHeight: 15, maxHeight: 80)
                    .modifier(BareReturnSubmits {
                        Task { await model.save() }
                    })

                if model.draft.isEmpty {
                    Text(model.isEditing ? "" : "What's on your mind?")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }

            Button(model.isEditing ? "Update" : "Save") {
                Task { await model.save() }
            }
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    #if os(macOS)
    private func installKeyMonitor() {
        // SwiftUI's `.onKeyPress` does not let an `.ignored` Return fall
        // through to the multi-line text editor's newline insertion, so on
        // macOS we intercept keystrokes at the AppKit level instead. Bare
        // Return saves; Shift+Return passes through so NSTextView inserts
        // a literal newline. Escape cancels an in-progress edit.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 = Escape
            if event.keyCode == 53 && model.isEditing {
                model.cancelEditing()
                return nil
            }
            // 36 = Return, 76 = numeric keypad Enter
            guard event.keyCode == 36 || event.keyCode == 76 else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.shift) {
                return event
            }
            Task { await model.save() }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif
}

/// Bare Return submits; Shift+Return inserts a newline. On macOS this is
/// handled at the AppKit level (see `installKeyMonitor`), so the modifier
/// is a no-op there to avoid SwiftUI's surprising `.onKeyPress` behavior.
/// iOS has no Shift modifier on the on-screen keyboard, so the
/// `.onKeyPress` form is sufficient.
private struct BareReturnSubmits: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        content.onKeyPress(keys: [.return]) { keyPress in
            if keyPress.modifiers.contains(.shift) {
                return .ignored
            }
            action()
            return .handled
        }
        #endif
    }
}

/// Toolbar sync indicator: a spinner while reconciling, an error glyph (tap to
/// retry) when the last sync failed, or a synced glyph with the time otherwise.
/// Tapping forces a sync.
private struct SyncStatusButton: View {
    let model: ThoughtListModel

    var body: some View {
        Button { model.syncNow() } label: {
            switch model.status {
            case .syncing:
                ProgressView().controlSize(.small)
            case .offline:
                Image(systemName: "wifi.slash").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.secondary)
            case .idle:
                Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
            }
        }
        .help(helpText)
        .disabled(model.status == .syncing)
    }

    private var helpText: String {
        switch model.status {
        case .syncing:
            return "Syncing…"
        case .offline:
            return "Offline — will sync when the server is reachable"
        case let .failed(message):
            return "Sync failed: \(message)"
        case .idle:
            if let synced = model.lastSynced {
                return "Last synced \(synced.formatted(date: .omitted, time: .shortened))"
            }
            return "Sync"
        }
    }
}

/// Slim, passive banner shown while the server is unreachable. Capture works
/// fully offline; this only tells the user their changes haven't synced yet.
private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)
            Text("Offline — changes will sync when the server is reachable")
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary)
    }
}

private struct EditingBanner: View {
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text("Editing thought")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }
}

private struct SearchResultsList: View {
    let results: [ThoughtMatch]
    let onSelect: (ThoughtMatch) -> Void

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView.search
        } else {
            List(results, id: \.thought.id) { match in
                SearchResultRow(match: match)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(match) }
            }
            .listStyle(.plain)
        }
    }
}

private struct SearchResultRow: View {
    let match: ThoughtMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlightedSnippet)
            Text(
                Date(timeIntervalSince1970: Double(match.thought.createdAt) / 1000),
                style: .relative
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// The snippet with matched terms emphasized. Match ranges are UTF-8
    /// byte offsets from the core; anything that doesn't land on a valid
    /// boundary is skipped rather than crashing the row.
    private var highlightedSnippet: AttributedString {
        var attributed = AttributedString(match.snippet)
        let utf8 = match.snippet.utf8
        for range in match.ranges {
            guard
                let start = utf8.index(
                    utf8.startIndex,
                    offsetBy: Int(range.start),
                    limitedBy: utf8.endIndex
                ),
                let end = utf8.index(start, offsetBy: Int(range.len), limitedBy: utf8.endIndex),
                let highlight = Range(start..<end, in: attributed)
            else { continue }
            attributed[highlight].inlinePresentationIntent = .stronglyEmphasized
            attributed[highlight].foregroundColor = .accentColor
        }
        return attributed
    }
}

private struct ThoughtRow: View {
    let thought: Thought
    let relatedExpanded: Bool
    let onToggleRelated: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(thought.text)
            HStack(spacing: 5) {
                if !thought.isSettled {
                    Circle()
                        .fill(.tint)
                        .frame(width: 5, height: 5)
                        .help("Live — edits will overwrite without history")
                }
                Text(
                    Date(timeIntervalSince1970: Double(thought.createdAt) / 1000),
                    style: .relative
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button(action: onToggleRelated) {
                    Image(systemName: relatedExpanded ? "link.circle.fill" : "link.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Related thoughts")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Thin, passive strip above the composer showing related past thoughts
/// while the user types. It never takes focus and never blocks input —
/// it appears under the stream and gets out of the way when dismissed or
/// when the draft stops matching anything.
private struct SuggestionStrip: View {
    let suggestions: [ThoughtMatch]
    let onSelect: (ThoughtMatch) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "link")
                .imageScale(.small)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.thought.id) { match in
                        Button {
                            onSelect(match)
                        } label: {
                            Text(match.thought.text)
                                .lineLimit(1)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Color.accentColor.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: 240)
                    }
                }
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide suggestions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Related thoughts expanded under a stream row; tapping one jumps the
/// stream to it.
private struct RelatedList: View {
    let related: [ThoughtMatch]
    let onSelect: (ThoughtMatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if related.isEmpty {
                Text("No related thoughts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(related, id: \.thought.id) { match in
                    Button {
                        onSelect(match)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                            Text(match.thought.text)
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.bottom, 6)
    }
}

#Preview {
    ContentView()
}
