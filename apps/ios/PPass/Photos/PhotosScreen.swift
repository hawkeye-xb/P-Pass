import SwiftUI
import PPassCore

/// 照片 tab（对位 Android PhotosScreen.kt）：失联红卡 → 筛选 chips → 3 列网格按月分组（组头 yyyy.MM、
/// serif）→ 触底翻页。视频右下角播放角标，照片没有，**不显示时长**（MOB-79）。
/// 状态：加载中 / 连不上（+ 重试）/ 空库 / 筛选结果为空；失联时这些提示全部让位给红卡。
struct PhotosScreen: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = TimelineModel()
    @State private var viewer: ViewerSession?

    var body: some View {
        NavigationStack {
            // 顺序同 Android：失联红卡 → 筛选胶囊 → 实时连接提示 → 网格。失联时胶囊和已加载的照片照常可看
            // （Android PhotosScreen 只收起重连 / 连不上这类提示，见 TimelineLiveChrome）。
            VStack(spacing: 0) {
                if app.pairingLost { lostCard }
                // #1263：范围里一个相册都没有时，照片页不空也在顶部给这条引导（空库时由下面的空状态说）。
                if !app.pairingLost, app.noAlbums, !model.items.isEmpty { chooseAlbumsBar }
                chips
                disconnected
                content
            }
            .ppScreen()
            .toolbar(.hidden, for: .navigationBar) // Android 无页标题，底部 tab 已标明所在页
        }
        .task { model.bind(app.backend.timeline); model.attach(app.backend.live); await model.loadFirst() }
        .onDisappear { model.detach() }
        .onAppear { model.attach(app.backend.live) }
        .onAppear {
            if LaunchRoute.current == .viewer || LaunchRoute.current == .video { model.openOnLoad = LaunchRoute.current }
            if LaunchRoute.current == .family { model.filter = .family }
        }
        .onChange(of: model.autoOpen) { item in if let item { open(item) } }
        .fullScreenCover(item: $viewer) { session in
            MediaViewer(session: session, timeline: app.backend.timeline)
        }
    }

    /// 配对失效红卡（Android PhotosScreen）：act-bg + act 30% 描边、内边距 18；标题无衬线粗体，出路是 ink 主按钮。
    private var lostCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.s("photos_lost_title")).font(PPFont.cardTitle).foregroundStyle(PPColor.act)
            Text(app.daysSinceLastReachable.map { L.p("photos_lost_body_days", $0) } ?? L.s("photos_lost_body_unknown"))
                .font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
            PPButton(title: L.s("photos_lost_action")) { app.startOver() }.padding(.top, 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.actBg, in: RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous).stroke(PPColor.act.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
    }

    /// 「还没选要备份的相册 · 选择相册」：一行说明 + 右侧动作，直达选范围页（#1263）。
    private var chooseAlbumsBar: some View {
        HStack(spacing: 12) {
            Text(L.s("photos_no_albums")).font(PPFont.subheadline).foregroundStyle(PPColor.ink60)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L.s("photos_choose_albums")) { app.openScopeEditor() }
                .font(PPFont.subheadlineBold).underline().foregroundStyle(PPColor.ink)
                .accessibilityIdentifier("photosChooseAlbums")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(PPColor.waitingBg, in: RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous))
        .padding(.horizontal, 20).padding(.top, 8)
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
        .padding(.horizontal, 20).padding(.top, app.pairingLost ? 0 : 8).padding(.bottom, 12)
        .background(PPColor.paper)
    }

    /// 实时更新的提示（Android `photosTimelineChrome`）：断线重连中给一行小字；退避用完停下来，提示 + 重试，不挡住已加载的照片。
    @ViewBuilder private var disconnected: some View {
        let chrome = TimelineLiveChrome(state: model.live, pairingLost: app.pairingLost)
        if chrome.showReconnecting {
            Text(L.s("photos_live_reconnecting")).font(PPFont.sans(13)).foregroundStyle(PPColor.ink40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 12)
                .background(PPColor.paper)
        }
        if chrome.showExhaustedRetry {
            HStack {
                Text(L.s("photos_live_disconnected")).font(PPFont.sans(13)).foregroundStyle(PPColor.ink40)
                Spacer()
                Button(L.s("photos_live_retry")) { model.retryLive() }
                    .font(PPFont.sans(13, .semibold)).foregroundStyle(PPColor.ink).padding(6)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            .background(PPColor.paper)
        }
    }

    @ViewBuilder private var content: some View {
        if model.loading && model.items.isEmpty {
            PPStateMessage(text: L.s("photos_loading"), loading: true)
        } else if model.error != nil, model.items.isEmpty, app.pairingLost {
            // 失联时出路只有红卡上的「重新扫码」，不再露「连不上」和原始错误（Android showTimelineError）。
            Spacer()
        } else if let error = model.error, model.items.isEmpty {
            // 同 Android：中间只说明，不放重试按钮。恢复靠桌面信号整页刷新 + 60 秒兜底，
            // 重连退避用完后顶部那行给「重试」（disconnected）。
            PPStateMessage(text: L.s("photos_unreachable") + "\n(" + String(error.prefix(100)) + ")",
                           symbol: "wifi.exclamationmark")
        } else if model.items.isEmpty {
            switch app.photosEmptyHint {
            case .chooseAlbums:
                PPStateMessage(text: L.s("photos_no_albums"), symbol: "photo.on.rectangle", actionTitle: L.s("photos_choose_albums")) {
                    app.openScopeEditor()
                }
            case .camera:
                PPStateMessage(text: L.f("home_empty_camera", app.desktopName ?? L.s("storage_device_default")), symbol: "camera")
            case .albums:
                PPStateMessage(text: L.s("home_empty_albums"), symbol: "photo.on.rectangle")
            }
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
                            .padding(.init(top: 16, leading: 8, bottom: 6, trailing: 8))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .refreshable { await model.loadFirst(reason: .pull) }
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
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L.s(item.isVideo ? "a11y_thumb_video" : "a11y_thumb_photo"))
            .accessibilityAddTraits(.isButton)
            .task(id: item.id) { image = try? await timeline.thumbnail(item, large: false) }
    }
}
