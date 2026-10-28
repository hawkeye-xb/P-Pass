import Foundation
import PPassCore

/// 时间线的分页与筛选（对位 Android PhotosScreen 的 loader 状态）。按月分组，组头 yyyy.MM。
@MainActor
final class TimelineModel: ObservableObject {
    struct MonthSection { let title: String; let items: [TimelineItem] }

    @Published private(set) var items: [TimelineItem] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var filter: TimelineFilter = .all
    /// 截图路由用：首屏加载完自动打开第一张照片 / 第一个视频。
    @Published private(set) var autoOpen: TimelineItem?
    var openOnLoad: LaunchRoute?

    /// 实时订阅的状态（对位 Android `SubscriptionSessionState`），页面据此显示「重连中 / 已断开 · 重试」。
    @Published private(set) var live = TimelineLiveState()

    private var source: TimelineSource?
    private var feed: TimelineLiveFeed?
    private var feedToken: UUID?
    private var cursor: String?
    private var exhausted = false
    /// 每装进一份新的整页快照 +1：在飞的翻页 / 首页加载回来发现快照已换，就丢掉自己的结果（否则会把旧游标的下一页接到新快照后面）。
    private var snapshot = 0
    private var refreshing = false
    private var refreshAgain = false

    func bind(_ source: TimelineSource) { if self.source == nil { self.source = source } }

    /// 接上实时更新通道（#963）。幂等；页面消失时 `detach`。
    func attach(_ feed: TimelineLiveFeed) {
        guard feedToken == nil else { return }
        self.feed = feed
        feedToken = feed.observe { [weak self] event in
            guard let self else { return }
            switch event {
            case .invalidated: Task { await self.refreshFromSignal() }
            case .fallbackTick: Task { await self.refreshFallback() }
            case .state(let s): self.live = s
            }
        }
    }

    func detach() {
        if let token = feedToken { feed?.remove(token) }
        feedToken = nil
    }

    func retryLive() { feed?.retry() }

    /// 桌面说时间线变了：整页覆盖（SYNC-01 对账删掉的照片必须真的消失），先拿到结果再换，不先清空（不闪、不丢滚动位置）。
    /// 备份一批会连发信号：刷新进行中再来信号只记一笔，跑完补一次，N 个信号不会排成 N 次请求。
    /// 失败不动已有内容也不亮错误（等下一次信号 / 兜底）；成功清错误（订阅恢复后「连不上」要能自己消掉）。
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
                // 保持现状
            }
        } while refreshAgain
    }

    /// 60 秒兜底：仅追加没见过的（不动已加载内容和翻页游标），防的是真实丢事件。
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
            // 商店截图：PPASS_VIEWER_ITEM=<序号> 指定打开第几条（从 0 数），换一张照片截看图页（仅 DEBUG，见 DebugLaunchInput）。
            if let i = DebugLaunchInput.viewerItem, items.indices.contains(i) {
                autoOpen = items[i]
            }
        }
    }

    func loadMore(retry: Bool = false) async {
        guard !loading, !exhausted, retry || error == nil else { return } // 失败后只有用户点「重试」才再试，不在滚动里反复撞
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
            guard mine == snapshot else { return } // 这期间整页被换过：这一页属于旧快照
            items += page.items
            cursor = page.nextCursor
            exhausted = page.nextCursor == nil
        } catch {
            guard mine == snapshot else { return }
            if items.isEmpty {
                self.error = String(describing: error)
            } else {
                // 已有内容时翻页失败：对位 Android，静默停在这里（不挡住已加载的照片；下一次信号整页刷新会重来）。
                exhausted = true
            }
        }
    }
}
