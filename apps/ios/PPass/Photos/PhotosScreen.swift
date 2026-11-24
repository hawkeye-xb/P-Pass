import PPassCore
import SwiftUI

struct PhotosScreen: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = TimelineModel()
    @State private var viewer: ViewerSession?

    private var conn: ConnectionState { app.connection }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if conn.needsRepair { lostCard }
                if guideShown { guideCard(app.photosGuide) }
                chips
                disconnected
                if let hint = app.scopeEmptyHint { scopeEmptyLine(hint) }
                content
            }
            .ppScreen()
            .toolbar(.hidden, for: .navigationBar)
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
            MediaViewer(session: session, timeline: app.backend.timeline, media: app.backend.media)
        }
    }

    private var lostCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.s("photos_lost_title")).font(PPFont.cardTitle).foregroundStyle(PPColor.act)
            Text(conn.daysUnreachable.map { L.p("photos_lost_body_days", $0) } ?? L.s("photos_lost_body_unknown"))
                .font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
            PPButton(title: L.s("photos_lost_action")) { app.startOver() }.padding(.top, 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.actBg, in: RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous).stroke(PPColor.act.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, PPUI.Layout.photosGutter).padding(.top, 8).padding(.bottom, 12)
    }

    private func guideCard(_ guide: PhotosGuide) -> some View {
        let text = guide == .enableScope ? L.s("photos_guide_scope") : L.s("photos_guide_background")
        let action = guide == .enableScope ? L.s(app.scopeGuideActionKey) : L.s(app.backgroundGuideActionKey)
        return NoticeRow(text: text, action: (action, { app.guideAction(guide) }),
                         close: (L.s("photos_guide_close"), { app.dismissGuide() }), standalone: true)
        .padding(.horizontal, PPUI.Layout.photosGutter).padding(.top, 8).padding(.bottom, 12)
        .onAppear { AppLog.log("photos-guide: shown \(guide.logName)") }
        .id(guide)
    }

    private func scopeEmptyLine(_ hint: String) -> some View {
        Text(hint).font(PPFont.sans(13)).foregroundStyle(PPColor.ink40)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PPUI.Layout.photosGutter).padding(.bottom, 12)
            .background(PPColor.paper)
            .onAppear { AppLog.log("photos-guide: scope empty hint") }
            .accessibilityIdentifier("photosScopeEmptyHint")
    }

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
        .padding(.horizontal, PPUI.Layout.photosGutter).padding(.top, conn.needsRepair || guideShown ? 0 : 8).padding(.bottom, 12)
        .background(PPColor.paper)
    }

    private var guideShown: Bool { !conn.needsRepair && app.photosGuide != .none }

    @ViewBuilder private var disconnected: some View {
        let chrome = TimelineLiveChrome(connection: conn)
        if chrome.showReconnecting {
            Text(L.s("photos_live_reconnecting")).font(PPFont.sans(13)).foregroundStyle(PPColor.ink40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PPUI.Layout.photosGutter).padding(.bottom, 12)
                .background(PPColor.paper)
        }
        if chrome.showExhaustedRetry {
            HStack {
                Text(L.s("photos_live_disconnected")).font(PPFont.sans(13)).foregroundStyle(PPColor.ink40)
                Spacer()
                Button(L.s("photos_live_retry")) { model.retryLive() }
                    .font(PPFont.sans(13, .semibold)).foregroundStyle(PPColor.ink).padding(6)
            }
            .padding(.horizontal, PPUI.Layout.photosGutter).padding(.bottom, 12)
            .background(PPColor.paper)
        }
    }

    @ViewBuilder private var content: some View {
        if model.loading && model.items.isEmpty {
            PPStateMessage(text: L.s("photos_loading"), loading: true)
        } else if model.error != nil, model.items.isEmpty, conn.needsRepair {
            Spacer()
        } else if let error = model.error, model.items.isEmpty {
            PPStateMessage(text: L.s("photos_unreachable"), symbol: "wifi.exclamationmark")
                .onAppear { AppLog.log("photos: timeline load failed (\(error))") }
        } else if model.items.isEmpty {
            PPStateMessage(text: L.s("home_empty_albums"), symbol: "photo.on.rectangle")
        } else if model.shown.isEmpty {
            PPStateMessage(text: L.s("photos_filter_empty"), symbol: "line.3.horizontal.decrease.circle")
        } else {
            grid
        }
    }

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
                            .padding(.init(top: 16, leading: 0, bottom: 6, trailing: 0))
                    }
                }
            }
            .padding(.horizontal, PPUI.Layout.photosGutter).padding(.bottom, 8)
        }
        .refreshable { await model.loadFirst(reason: .pull) }
    }

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
