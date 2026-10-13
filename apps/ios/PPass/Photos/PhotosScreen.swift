import SwiftUI

/// 照片 tab（对位 Android PhotosScreen.kt）：失联红卡 → 筛选 chips → 3 列网格按月分组（组头 yyyy.MM、
/// serif）→ 触底翻页。视频右下角播放角标，照片没有，**不显示时长**（MOB-79）。
/// 状态：加载中 / 连不上（+ 重试）/ 空库 / 筛选结果为空；失联时这些提示全部让位给红卡。
struct PhotosScreen: View {
    @EnvironmentObject var app: AppModel
    @Binding var tabBarHidden: Bool
    @StateObject private var model = TimelineModel()
    @State private var viewer: ViewerSession?

    var body: some View {
        VStack(spacing: 0) {
            if app.pairingLost {
                PPCard(fill: PPColor.actBg, stroke: PPColor.act.opacity(0.3)) {
                    Text(L.s("photos_lost_title")).font(PPFont.serif(24)).foregroundStyle(PPColor.act)
                    Text(L.s("photos_lost_body_unknown")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                    PPButton(title: L.s("photos_lost_action"), kind: .danger) { app.startOver() }
                }
                .padding(16)
            }
            chips
            content
        }
        .ppScreen()
        .task { model.bind(app.backend.timeline); await model.loadFirst() }
        .onAppear {
            if LaunchRoute.current == .viewer || LaunchRoute.current == .video { model.openOnLoad = LaunchRoute.current }
        }
        // 备份确认数变了 = 电脑上有新照片入库：重取第一页（daemon 入库索引略晚于确认，等一拍）。
        .onChange(of: app.facts.confirmed) { _ in
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await model.loadFirst() }
        }
        .onChange(of: model.autoOpen) { item in if let item { open(item) } }
        .fullScreenCover(item: $viewer, onDismiss: { tabBarHidden = false }) { session in
            MediaViewer(session: session, timeline: app.backend.timeline)
                .preferredColorScheme(.dark) // 深色看图底：状态栏用浅色字，否则时间看不见
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(TimelineFilter.allCases, id: \.self) { f in
                let on = model.filter == f
                Button { model.filter = f } label: {
                    Text(L.s(f.key)).font(PPFont.sans(16, on ? .bold : .regular))
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .foregroundStyle(on ? PPColor.paper : PPColor.ink60)
                        .background(on ? PPColor.ink : PPColor.linen, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if app.pairingLost {
            Spacer()
        } else if model.loading && model.items.isEmpty {
            PPStateMessage(text: L.s("photos_loading"), loading: true)
        } else if let error = model.error, model.items.isEmpty {
            PPStateMessage(text: L.s("photos_unreachable") + "\n" + String(error.prefix(100)),
                           actionTitle: L.s("photos_live_retry")) { Task { await model.loadFirst() } }
        } else if model.items.isEmpty {
            PPStateMessage(text: L.s("photos_empty"))
        } else if model.shown.isEmpty {
            PPStateMessage(text: L.s("photos_filter_empty"))
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4,
                      pinnedViews: []) {
                ForEach(model.sections, id: \.title) { section in
                    Section {
                        ForEach(section.items) { item in
                            Thumb(item: item, timeline: app.backend.timeline)
                                .onTapGesture { open(item) }
                                .onAppear { if item == model.shown.last { Task { await model.loadMore() } } }
                        }
                    } header: {
                        Text(section.title).font(PPFont.serif(22)).foregroundStyle(PPColor.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14).padding(.bottom, 4)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 16)
        }
    }

    /// 以打开那一刻的筛选结果为页序快照（Android MediaViewerSession.open）；找不到被点项就不打开。
    private func open(_ item: TimelineItem) {
        guard let index = model.shown.firstIndex(of: item) else { return }
        tabBarHidden = true
        viewer = ViewerSession(items: model.shown, start: index)
    }
}

enum TimelineFilter: CaseIterable {
    case all, local, family
    var key: String { ["chip_all", "chip_local", "chip_family"][TimelineFilter.allCases.firstIndex(of: self)!] }

    func keeps(_ item: TimelineItem) -> Bool {
        switch self {
        case .all: return true
        case .local: return item.isMine == true
        case .family: return item.isMine == false
        }
    }
}

struct ViewerSession: Identifiable {
    let id = UUID()
    let items: [TimelineItem]
    let start: Int
}

/// 网格里的一格：缩略图 + 视频角标（22pt 深色半透明圆 + 纸色三角）。
struct Thumb: View {
    let item: TimelineItem
    let timeline: TimelineSource
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background(PPColor.linen)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PPColor.paper)
                        .frame(width: 22, height: 22)
                        .background(PPColor.surfaceDark.opacity(0.62), in: Circle())
                        .padding(6)
                        .accessibilityLabel("video")
                }
            }
            .task(id: item.id) { image = try? await timeline.thumbnail(item, large: false) }
    }
}
