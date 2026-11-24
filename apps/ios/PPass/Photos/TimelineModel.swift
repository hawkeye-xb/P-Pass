import Foundation
import PPassCore

@MainActor
final class TimelineModel: ObservableObject {
    struct MonthSection { let title: String; let items: [TimelineItem] }

    @Published private(set) var items: [TimelineItem] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var filter: TimelineFilter = .all
    @Published private(set) var autoOpen: TimelineItem?
    var openOnLoad: LaunchRoute?

    @Published private(set) var live = TimelineLiveState()

    private var source: TimelineSource?
    private var feed: TimelineLiveFeed?
    private var feedToken: UUID?
    private var cursor: String?
    private var exhausted = false
    private var snapshot = 0
    private var refreshing = false
    private var refreshAgain = false

    func bind(_ source: TimelineSource) { if self.source == nil { self.source = source } }

    func attach(_ feed: TimelineLiveFeed) {
        guard feedToken == nil else { return }
        self.feed = feed
        feedToken = feed.observe { [weak self] event in
            guard let self else { return }
            switch event {
            case .invalidated: Task { await self.refreshFromSignal() }
            case .fallbackTick: Task { await self.refreshFallback() }
            case .state(let s):
                self.live = s
                if s.connected, self.error != nil {
                    Task { await self.refreshFromSignal() }
                }
            }
        }
    }

    func detach() {
        if let token = feedToken { feed?.remove(token) }
        feedToken = nil
    }

    func retryLive() { feed?.retry() }

    func refreshFromSignal() async {
        guard let source else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            do {
                let page = try await source.page(cursor: nil, reason: .signal)
                items = page.items
                cursor = page.nextCursor
                exhausted = page.nextCursor == nil
                snapshot += 1
                error = nil
            } catch {
            }
        } while refreshAgain
    }

    func refreshFallback() async {
        guard let source, !refreshing else { return }
        guard let page = try? await source.page(cursor: nil, reason: .fallback) else { return }
        let known = Set(items.map(\.id))
        let fresh = page.items.filter { !known.contains($0.id) }
        if !fresh.isEmpty { items = fresh + items }
    }

    var shown: [TimelineItem] { items.filter(filter.keeps) }

    var sections: [MonthSection] {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM"
        var out: [MonthSection] = []
        for item in shown {
            let title = f.string(from: item.takenAt)
            if out.last?.title == title {
                out[out.count - 1] = MonthSection(title: title, items: out[out.count - 1].items + [item])
            } else {
                out.append(MonthSection(title: title, items: [item]))
            }
        }
        return out
    }

    func loadFirst(reason: TimelinePageReason = .open) async {
        cursor = nil
        exhausted = false
        snapshot += 1
        items = []
        await load(reason)
        if let route = openOnLoad {
            openOnLoad = nil
            autoOpen = items.first { $0.isVideo == (route == .video) }
            if let i = DebugLaunchInput.viewerItem, items.indices.contains(i) {
                autoOpen = items[i]
            }
        }
    }

    func loadMore(retry: Bool = false) async {
        guard !loading, !exhausted, retry || error == nil else { return }
        await load(.more)
    }

    private func load(_ reason: TimelinePageReason) async {
        guard let source else { return }
        loading = true
        error = nil
        defer { loading = false }
        let mine = snapshot
        do {
            let page = try await source.page(cursor: cursor, reason: reason)
            guard mine == snapshot else { return }
            items += page.items
            cursor = page.nextCursor
            exhausted = page.nextCursor == nil
        } catch {
            guard mine == snapshot else { return }
            if items.isEmpty {
                self.error = String(describing: error)
            } else {
                exhausted = true
            }
        }
    }
}
