import SwiftUI
import PPassCore

/// 选范围「备份哪些照片」（对位 Android BucketScreen.kt，#1263）：首次配对后与设置里重选共用同一页。同 Android：说明一行 +
/// 时间二选一（从今天起 / 全部）+ **2 列封面卡片**（封面 1.6:1 + 右上勾选角标 + 名称 /「新」+ 张数，选中描边变墨色）。
/// 首次默认勾上「最近项目」、时间默认「从今天起」；新相册（不在上次已知集合里）默认不勾。允许空集 = 一个都不备份。
/// 底部只有主按钮：首次「开始备份」，编辑「保存」。不显示合计张数与大小（#1263 删掉 bucket_summary；iOS 没有公开的大小接口，#1016）。
/// 与 Android 的差别只有：标题用系统大标题导航栏；相册是异步读的，所以多了加载中 / 读取失败两种状态。
struct BucketScreen: View {
    let firstTime: Bool
    /// 选中的相册、保存时看到的全部相册、时间档是不是「全部」。
    let onDone: (Set<String>, Set<String>, Bool) -> Void
    @EnvironmentObject var app: AppModel
    @State private var albums: [AlbumBucket]?
    @State private var checked: Set<String> = []
    @State private var wantsAll = false
    /// 保存过的时间档（nil = 从未保存）：选项「M月d日起的照片」的日期从这里来。
    @State private var savedSince: BackupSince?
    @State private var known: Set<String> = []
    @State private var error: String?

    var body: some View {
        content
            .navigationTitle(L.s("bucket_title"))
            .ppNavBar()
            .ppScreen()
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom, spacing: 0) { if albums != nil, error == nil, Self.offersChoices(Self.notice(for: app.access)) { footer } }
            .toolbar(firstTime ? .automatic : .hidden, for: .tabBar) // 选相册是一次完整任务，底部主按钮占位
            .task { await load() }
            // 从系统设置改完权限回来（sceneBecameActive 会重读权限档）：按新的一档重读相册。
            .onChange(of: app.access) { _ in Task { await load() } }
    }

    @ViewBuilder private var content: some View {
        if let error {
            PPStateMessage(text: error, symbol: "exclamationmark.triangle", actionTitle: L.s("try_again")) { Task { await load() } }
        } else if let albums {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if Self.notice(for: app.access) == .partial {
                        Text(L.s("bucket_partial_access_note")).font(PPFont.sans(14, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(PPColor.waiting).fixedSize(horizontal: false, vertical: true)
                    }
                    if Self.offersChoices(Self.notice(for: app.access)) {
                        Text(L.s("bucket_hint")).font(PPFont.sans(14, relativeTo: .subheadline)).foregroundStyle(PPColor.ink40)
                            .fixedSize(horizontal: false, vertical: true)
                        timePicker
                    }
                    if Self.notice(for: app.access) == .noAccess {
                        noAccess
                    } else if albums.isEmpty {
                        Text(L.s("bucket_empty")).font(PPFont.sans(15, relativeTo: .subheadline)).foregroundStyle(PPColor.ink40)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                            ForEach(albums) { album in card(album) }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 14)
            }
        } else {
            PPStateMessage(text: L.s("bucket_loading"), loading: true)
        }
    }

    /// 页面按照片权限档多说的一句（10-29）。
    enum AccessNotice: Equatable { case none, partial, noAccess }

    /// 只给了部分照片：页顶说明只备份允许的那些；一张都读不到：不说「没有找到照片」（那不是现状），说没有权限并给「去设置」。
    static func notice(for access: MediaAccess) -> AccessNotice {
        switch access {
        case .full: return .none
        case .partial: return .partial
        case .none: return .noAccess
        }
    }

    /// 没有照片权限时不给选择（10-30）：时间档、提示句和底部「开始备份 / 保存」都不显示——一张都读不到，选了也没用。
    static func offersChoices(_ notice: AccessNotice) -> Bool { notice != .noAccess }

    /// 没有照片权限：标题 + 一句现状 +「去设置」（打开本 App 的系统设置页）。样式同首页英雄卡的权限卡。
    private var noAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.s("bucket_no_access_title")).font(PPFont.cardTitle).foregroundStyle(PPColor.act)
            Text(L.s("bucket_no_access_body")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                .fixedSize(horizontal: false, vertical: true)
            PPButton(title: L.s("bucket_no_access_action")) { app.openAppSettings() }
                .accessibilityIdentifier("bucketOpenSettings")
        }
        .padding(.top, 24)
    }

    /// Android BucketCard：圆角 16、paper 底、2pt 描边（选中 ink / 未选 border）；文字区内边距 12/9/12/11。
    private func card(_ album: AlbumBucket) -> some View {
        let on = checked.contains(album.id)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            if on { checked.remove(album.id) } else { checked.insert(album.id) }
            Haptics.selection()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                AlbumCover(album: album)
                    .overlay(alignment: .topTrailing) { SelectBadge(selected: on).padding(8) }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(album.name ?? L.s("bucket_unnamed")).font(PPFont.sans(14.5, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(PPColor.ink).lineLimit(1)
                        Spacer(minLength: 0)
                        if !known.isEmpty, !known.contains(album.id) {
                            Text(L.s("bucket_new")).font(PPFont.sans(11, .bold, relativeTo: .caption2)).foregroundStyle(PPColor.waiting)
                        }
                    }
                    Text(L.f("bucket_count", album.count)).font(PPFont.sans(12.5, relativeTo: .caption)).foregroundStyle(PPColor.ink40)
                }
                .padding(.init(top: 9, leading: 12, bottom: 11, trailing: 12))
            }
            .background(PPColor.paper, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(on ? PPColor.ink : PPColor.border, lineWidth: 2))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// 时间二选一（M月d日起的照片 / 含以前的照片）：系统分段控件，一行。
    private var timePicker: some View {
        Picker(L.s("bucket_title"), selection: $wantsAll) {
            Text(Self.sinceOptionLabel(savedSince, now: Date())).tag(false)
            Text(L.s("scope_time_all")).tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("bucketSince")
    }

    /// 「某天起的照片」那一档的选项文字，一律写日期（10-29 文案定稿，同 Android `scopeSinceOptionLabel`）：保存过某天 → 那一天；
    /// 从未保存或存的是「全部」→ 今天（保存时落的就是今天零点，见 `ScopePolicy.sinceForSave`）。
    static func sinceOptionLabel(_ saved: BackupSince?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let start: Date
        if case .since(let ms)? = saved {
            start = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else {
            start = calendar.startOfDay(for: now)
        }
        return L.f("scope_time_since_date", SettingsScreen.scopeDate(start, calendar: calendar, locale: locale))
    }

    /// 底部唯一的主按钮：首次「开始备份」，编辑「保存」（Android 60 高 / 18 字）。paper 底 + 顶部分隔线：网格从下面滚过时仍可读。
    private var footer: some View {
        PPButton(title: L.s(firstTime ? "bucket_start" : "bucket_save"), height: 60, fontSize: 18) {
            onDone(checked, Set((albums ?? []).map(\.id)), wantsAll)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(PPColor.paper.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { PPDivider() }
    }

    private func load() async {
        error = nil
        do {
            let list = try await app.backend.media.albums()
            app.refreshAccess() // 读相册时可能刚弹过系统照片权限框（时间档初值看这一档，所以要在下面之前）
            known = app.backend.media.knownAlbums()
            let saved = try app.backend.media.savedScope() // 读失败走下面的 catch（显示错误 + 重试），不当成「从未保存」
            // 从未保存 → 默认勾「最近项目」；保存过 → 照旧，只勾当前还存在的（新相册默认不勾）。
            checked = ScopePolicy.initialSelection(saved: saved, available: Set(list.map(\.id)),
                                                   cameraAlbum: list.first(where: \.isCameraAlbum)?.id)
            // 时间档：保存过 → 回显；从未保存 → 部分照片「全部」、完整访问「从今天起」。
            let since = try app.backend.media.savedSince()
            savedSince = since
            wantsAll = ScopePolicy.initialWantsAll(saved: since, partialAccess: app.access == .partial)
            albums = list
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// 右上勾选角标（Android SelectBadge）：22 圆；选中 = ink 底 paper 勾，未选 = paper-dim 底 + 1.5 border-strong 圈。
private struct SelectBadge: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().fill(selected ? PPColor.ink : PPColor.paperDim)
            if selected {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(PPColor.paper)
            } else {
                Circle().strokeBorder(PPColor.borderStrong, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// 封面 1.6:1（Android BucketCoverImage），linen 占位，裁切填满。
private struct AlbumCover: View {
    let album: AlbumBucket
    @EnvironmentObject var app: AppModel
    @State private var image: UIImage?

    var body: some View {
        PPColor.linen
            .aspectRatio(1.6, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipped()
            // side = 封面高（pt），宽按 1.6 由 cover 自己算。
            .task(id: album.id) { image = await app.backend.media.cover(album, side: 120) }
    }
}
