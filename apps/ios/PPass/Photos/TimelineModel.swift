import Foundation

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

    private var source: TimelineSource?
    private var cursor: String?
    private var exhausted = false

    func bind(_ source: TimelineSource) { if self.source == nil { self.source = source } }

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

    func loadFirst() async {
        cursor = nil
        exhausted = false
        items = []
        await load()
        if let route = openOnLoad {
            openOnLoad = nil
            autoOpen = items.first { $0.isVideo == (route == .video) }
        }
    }

    func loadMore() async {
        guard !loading, !exhausted else { return }
        await load()
    }

    private func load() async {
        guard let source else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await source.page(cursor: cursor)
            items += page.items
            cursor = page.nextCursor
            exhausted = page.nextCursor == nil
        } catch {
            self.error = String(describing: error)
        }
    }
}
