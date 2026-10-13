import SwiftUI

/// 照片 tab（对位 Android PhotosScreen.kt）：失联红卡 → 筛选 chips → 3 列网格按月分组（组头 yyyy.MM、
/// serif）→ 触底翻页。视频右下角播放角标，照片没有，**不显示时长**（MOB-79）。
/// 状态：加载中 / 连不上（+ 重试）/ 空库 / 筛选结果为空；失联时这些提示全部让位给红卡。
struct PhotosScreen: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = TimelineModel()
    @State private var viewer: ViewerSession?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if app.pairingLost {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L.s("photos_lost_title"), systemImage: "exclamationmark.triangle.fill")
                            .font(PPFont.title3).foregroundStyle(PPColor.act)
                        Text(L.s("photos_lost_body_unknown")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                        PPButton(title: L.s("photos_lost_action"), kind: .danger) { app.startOver() }
                    }
                    .padding(16)
                    .background(PPColor.actBg, in: RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous))
                    .padding(16)
                }
                content
            }
            .ppScreen()
            .toolbar(.hidden, for: .navigationBar) // Android 无页标题，底部 tab 已标明所在页
            .safeAreaInset(edge: .top, spacing: 0) { if !app.pairingLost { VStack(spacing: 0) { chips; disconnected } } }
        }
        .task { model.bind(app.backend.timeline); await model.loadFirst() }
        .onAppear {
            if LaunchRoute.current == .viewer || LaunchRoute.current == .video { model.openOnLoad = LaunchRoute.current }
        }
        // 备份确认数变了 = 电脑上有新照片入库：重取第一页（daemon 入库索引略晚于确认，等一拍）。
        .onChange(of: app.facts.confirmed) { _ in
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await model.loadFirst() }
        }
        .onChange(of: model.autoOpen) { item in if let item { open(item) } }
        .fullScreenCover(item: $viewer) { session in
            MediaViewer(session: session, timeline: app.backend.timeline)
        }
    }

    /// 全部 / 本机 / 家人：胶囊 chips（Android PhotoFilterChip）：高 36、linen 底 ink-60 字，选中 = ink 底 paper 字。
    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(TimelineFilter.allCases, id: \.self) { f in
                let on = model.filter == f
                Button { model.filter = f } label: {
                    Text(L.s(f.key)).font(PPFont.sans(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(on ? PPColor.paper : PPColor.ink60)
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(on ? PPColor.ink : PPColor.linen, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        .background(PPColor.paper)
    }

    /// 已有照片时翻页 / 刷新失败：不挡住已加载的内容，只在上面提示「连不上」+ 重试（Android SYNC-04）。
    @ViewBuilder private var disconnected: some View {
        if model.error != nil, !model.items.isEmpty {
            HStack {
                Text(L.s("photos_live_disconnected")).font(PPFont.sans(13)).foregroundStyle(PPColor.ink40)
                Spacer()
                Button(L.s("photos_live_retry")) { Task { await model.loadMore(retry: true) } }
                    .font(PPFont.sans(13, .semibold)).foregroundStyle(PPColor.ink).padding(6)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            .background(PPColor.paper)
        }
    }

    @ViewBuilder private var content: some View {
        if app.pairingLost {
            Spacer()
        } else if model.loading && model.items.isEmpty {
            PPStateMessage(text: L.s("photos_loading"), loading: true)
        } else if let error = model.error, model.items.isEmpty {
            PPStateMessage(text: L.s("photos_unreachable") + "\n" + String(error.prefix(100)),
                           symbol: "wifi.exclamationmark",
                           actionTitle: L.s("photos_live_retry")) { Task { await model.loadFirst() } }
        } else if model.items.isEmpty {
            PPStateMessage(text: L.s("photos_empty"), symbol: "photo.on.rectangle")
        } else if model.shown.isEmpty {
            PPStateMessage(text: L.s("photos_filter_empty"), symbol: "line.3.horizontal.decrease.circle")
        } else {
            grid
        }
    }

    /// 网格对齐 Android：3 列、4pt 间隔、左右 12pt 边距、缩略图圆角 10；月份组头 serif 18，不吸顶。
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(model.sections, id: \.title) { section in
                    Section {
                        ForEach(section.items) { item in
                            Thumb(item: item, timeline: app.backend.timeline)
                                .onTapGesture { open(item) }
                                .onAppear { if item == model.shown.last { Task { await model.loadMore() } } }
                        }
                    } header: {
                        Text(section.title).font(PPFont.serif(18, .regular, relativeTo: .title3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.init(top: 16, leading: 8, bottom: 2, trailing: 8))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    /// 以打开那一刻的筛选结果为页序快照（Android MediaViewerSession.open）；找不到被点项就不打开。
    private func open(_ item: TimelineItem) {
        guard let index = model.shown.firstIndex(of: item) else { return }
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

/// 网格里的一格：缩略图 + 视频角标（SF Symbol `play.fill` + 材质圆底）。
struct Thumb: View {
    let item: TimelineItem
    let timeline: TimelineSource
    @State private var image: UIImage?

    var body: some View {
        PPColor.linen
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PPColor.paper)
                        .frame(width: 22, height: 22)
                        .background(PPColor.surfaceDark.opacity(0.62), in: Circle())
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.isVideo ? "Video" : "Photo")
            .accessibilityAddTraits(.isButton)
            .task(id: item.id) { image = try? await timeline.thumbnail(item, large: false) }
    }
}
