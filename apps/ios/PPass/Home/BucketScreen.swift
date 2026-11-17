import SwiftUI
import PPassCore
import PPassMedia

/// 统一备份范围：相册与文件夹卡片共用选中表现、同一时间档和同一个保存动作。
/// 添加文件夹只登记授权并标成待保存；取消勾选保留授权，移除需单独确认且不删原素材。
/// 首次默认勾上「最近项目」、时间默认「从今天起」；新相册默认不勾。允许空集 = 一个都不备份。
/// 底部只有主按钮：首次「开始备份」，编辑「保存」。不显示合计张数与大小（#1263 删掉 bucket_summary；iOS 没有公开的大小接口，#1016）。
/// 与 Android 的差别只有：标题用系统大标题导航栏；相册是异步读的，所以多了加载中 / 读取失败两种状态。
struct BucketScreen: View {
    let firstTime: Bool
    /// 选中的来源、保存时看到的全部来源、时间档是不是「全部」。
    let onDone: (Set<String>, Set<String>, Bool) -> Void
    @EnvironmentObject var app: AppModel
    @State private var albums: [AlbumBucket]?
    @State private var checked: Set<String> = []
    @State private var wantsAll = false
    /// 保存过的时间档（nil = 从未保存）：选项「M月d日起的照片」的日期从这里来。
    @State private var savedSince: BackupSince?
    @State private var known: Set<String> = []
    @State private var error: String?
    @State private var folders: [FolderSourceInfo] = []
    @State private var showingAddPicker = false
    @State private var reauthTarget: FolderSourceInfo?
    @State private var removeTarget: FolderSourceInfo?
    @State private var folderBusy = false
    @State private var hasLoaded = false

    var body: some View {
        content
            .navigationTitle(L.s("backup_scope"))
            .ppNavBar()
            .ppScreen()
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom, spacing: 0) { if albums != nil, error == nil { footer } }
            .toolbar(firstTime ? .automatic : .hidden, for: .tabBar) // 选范围是一次完整任务，底部主按钮占位
            .task { await load() }
            // 从系统设置改完权限回来（sceneBecameActive 会重读权限档）：按新的一档重读相册。
            .onChange(of: app.access) { _ in Task { await load() } }
            .sheet(isPresented: $showingAddPicker) {
                FolderPicker { url in Task { await addFolder(url) } }
            }
            .sheet(item: $reauthTarget) { target in
                FolderPicker { url in Task { await reauthorize(target, at: url) } }
            }
            .confirmationDialog(L.s("folder_sources_remove_confirm_title"), isPresented: Binding(
                get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
                Button(L.s("folder_sources_remove"), role: .destructive) {
                    if let target = removeTarget {
                        removeTarget = nil
                        Task { await remove(target) }
                    }
                }
                Button(L.s("cancel"), role: .cancel) { removeTarget = nil }
            } message: { Text(L.s("folder_sources_remove_confirm_body")) }
    }

    @ViewBuilder private var content: some View {
        if let error {
            PPStateMessage(text: error, symbol: "exclamationmark.triangle", actionTitle: L.s("try_again")) { Task { await load() } }
        } else if let albums {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    timePicker
                    if Self.notice(for: app.access) == .noAccess { noAccess }
                    if albums.isEmpty, folders.isEmpty, Self.notice(for: app.access) != .noAccess {
                        Text(L.s("bucket_empty")).font(PPFont.sans(15, relativeTo: .subheadline)).foregroundStyle(PPColor.ink40)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        if Self.offersChoices(Self.notice(for: app.access)) {
                            ForEach(albums) { album in card(album) }
                        }
                        ForEach(folders) { folder in folderCard(folder) }
                        addFolderCard
                    }
                    // 一个来源都没选：明确说清楚（空范围 = 不自动备份），不弹窗、不替用户补默认。
                    if Self.showsEmptySelectionHint(hasLoaded: hasLoaded, checked: checked) {
                        Text(L.s("bucket_no_selection")).font(PPFont.sans(15, relativeTo: .subheadline)).foregroundStyle(PPColor.ink40)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                            .accessibilityIdentifier("bucketNoSelection")
                    }
                }
                .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 14)
            }
        } else {
            PPStateMessage(text: L.s("bucket_loading"), loading: true)
        }
    }

    /// 页面按照片权限档多说的一句（10-29；#1811 起权限两态：完整 / 未完整）。
    enum AccessNotice: Equatable { case none, noAccess }

    /// 完整授权才把相册当成自动备份来源；有限授权和拒绝统一成「相册未完整授权」，同一套提示与出口。
    static func notice(for access: MediaAccess) -> AccessNotice {
        access == .full ? .none : .noAccess
    }

    /// 相册未完整授权时不给相册选择：相册不进自动范围，用户挑的几张只走「挑几张传」；文件夹照常。
    static func offersChoices(_ notice: AccessNotice) -> Bool { notice != .noAccess }

    /// 一个来源都没选：明确写「未选择任何来源」。空范围允许保存（= 不自动备份），不替用户补默认。
    /// 相册未完整授权（选择被隐藏）时同样要显示：此时页面上只有文件夹可选，不写清楚会像「已选好了」。
    static func showsEmptySelectionHint(hasLoaded: Bool, checked: Set<String>) -> Bool {
        hasLoaded && checked.isEmpty
    }

    /// 首次加载：没有存过的范围一律空——显式传 cameraAlbum 也不预选相机相册（#1811）；
    /// 相册选择隐藏（有限 / 拒绝授权）时只保留保存过的相册，不做任何默认预选。
    /// 首次加载也保留不可见的已保存相册，恢复权限后仍可选择；未勾选的新相册不自动加入。
    static func initialSelectionWithUnavailable(saved: Set<String>?, availableAlbums: Set<String>,
                                                cameraAlbum: String?, offersChoices: Bool) -> Set<String> {
        guard let saved else { return [] }
        let savedAlbums = saved.filter { !$0.hasPrefix("folder:") }
        guard offersChoices else { return savedAlbums }
        let visible = ScopePolicy.initialSelection(saved: saved, available: availableAlbums, cameraAlbum: cameraAlbum)
        let invisibleSaved = savedAlbums.filter { !availableAlbums.contains($0) }
        return visible.union(invisibleSaved)
    }

    /// 授权后的刷新不得覆盖未保存选择；权限不可见的已保存相册也不视为用户取消。
    static func selectionForReload(current: Set<String>, saved: Set<String>?, availableAlbums: Set<String>, availableFolders: Set<String>) -> Set<String> {
        current.filter { id in
            if id.hasPrefix("folder:") { return availableFolders.contains(id) }
            return availableAlbums.contains(id) || saved?.contains(id) == true
        }
    }

    /// 相册权限提示只针对相册；文件夹仍可添加和备份。首次点击才申请，拒绝后改去系统设置。
    private var noAccess: some View {
        let presentation = PhotoAccessPresentation.of(PhotoKitAuthorization().currentLevel())
        return VStack(alignment: .leading, spacing: 10) {
            Text(L.s("bucket_no_access_title")).font(PPFont.cardTitle).foregroundStyle(PPColor.act)
            Text(L.s("bucket_no_access_body")).font(PPFont.cardBody).foregroundStyle(PPColor.ink60)
                .fixedSize(horizontal: false, vertical: true)
            switch presentation.notice?.action {
            case .requestAccess:
                PPButton(title: L.s("bucket_request_access_action")) {
                    Task {
                        let granted = await app.backend.media.requestAccess()
                        if AppModel.decisionLanding(granted) == .registerAllowed {
                            _ = await app.backend.engine.sendAllowedPhotos()
                        }
                        app.refreshAccess()
                        await load()
                    }
                }
                .accessibilityIdentifier("bucketRequestAccess")
            case .openAppSettings:
                PPButton(title: L.s("bucket_no_access_action")) { app.openAppSettings() }
                    .accessibilityIdentifier("bucketOpenSettings")
            case nil:
                EmptyView()
            }
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

    /// 文件夹与相册使用同一选中外观；取消勾选只改待保存范围，重新授权和移除是独立动作。
    private func folderCard(_ source: FolderSourceInfo) -> some View {
        let id = FolderMediaSource.bucketId(sourceId: source.id)
        let on = checked.contains(id)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if on { checked.remove(id) } else { checked.insert(id) }
                Haptics.selection()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    PPColor.linen.aspectRatio(1.6, contentMode: .fit)
                        .overlay { Image(systemName: "folder.fill").font(.system(size: 40)).foregroundStyle(PPColor.ink40) }
                        .overlay(alignment: .topTrailing) { SelectBadge(selected: on).padding(8) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName).font(PPFont.sans(14.5, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(PPColor.ink).lineLimit(1)
                            .accessibilityIdentifier("folderSourceName")
                        Text(source.available ? L.s("folder_sources_status_ok") : L.s("folder_sources_status_wait"))
                            .font(PPFont.sans(12.5, relativeTo: .caption)).foregroundStyle(PPColor.ink40)
                    }
                    .padding(.init(top: 9, leading: 12, bottom: 8, trailing: 12))
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? [.isSelected] : [])
            HStack(spacing: 12) {
                if !source.available {
                    Button(L.s("folder_sources_reauth")) { reauthTarget = source }
                        .font(PPFont.sans(12.5, relativeTo: .caption))
                        .accessibilityIdentifier("folderSourceReauth")
                }
                Spacer()
                Button(L.s("folder_sources_remove")) { removeTarget = source }
                    .font(PPFont.sans(12.5, relativeTo: .caption)).foregroundStyle(PPColor.ink40)
                    .accessibilityIdentifier("folderSourceRemove")
            }
            .padding(.horizontal, 12).padding(.bottom, 9)
            .disabled(folderBusy)
        }
        .background(PPColor.paper, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(on ? PPColor.ink : PPColor.border, lineWidth: 2))
    }

    private var addFolderCard: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { showingAddPicker = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                PPColor.linen.aspectRatio(1.6, contentMode: .fit)
                    .overlay { Image(systemName: "plus").font(.system(size: 36, weight: .medium)).foregroundStyle(PPColor.ink40) }
                Text(L.s("folder_sources_add")).font(PPFont.sans(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(PPColor.ink).lineLimit(1)
                    .padding(.init(top: 9, leading: 12, bottom: 11, trailing: 12))
            }
            .background(PPColor.paper, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(PPColor.border, lineWidth: 2))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(folderBusy)
        .accessibilityIdentifier("folderSourceAdd")
    }

    private func addFolder(_ url: URL) async {
        let before = Set(folders.map(\.id))
        _ = await runFolder("folder-add", operation: {
            try await app.backend.engine.addFolderSource(at: url, displayName: url.lastPathComponent)
        }, apply: { updated in
            if let added = updated.first(where: { !before.contains($0.id) }) {
                checked.insert(FolderMediaSource.bucketId(sourceId: added.id))
            }
        })
    }

    private func reauthorize(_ target: FolderSourceInfo, at url: URL) async {
        _ = await runFolder("folder-reauth") { try await app.backend.engine.reauthorizeFolderSource(id: target.id, at: url) }
    }

    private func remove(_ target: FolderSourceInfo) async {
        _ = await runFolder("folder-remove", operation: { try app.backend.engine.removeFolderSource(id: target.id) }, apply: { _ in
            checked.remove(FolderMediaSource.bucketId(sourceId: target.id))
        })
    }

    @discardableResult
    private func runFolder(_ what: String, operation: () async throws -> Void,
                           apply: ([FolderSourceInfo]) -> Void = { _ in }) async -> Bool {
        guard !folderBusy else { return false }
        folderBusy = true
        defer { folderBusy = false }
        do {
            try await operation()
            AppLog.log("\(what): ok")
        } catch {
            AppLog.log("\(what): failed: \(error)")
            app.notice = UserNotice(message: L.s("folder_sources_add_failed"))
            return false
        }
        let updated = await app.backend.engine.folderSources()
        folders = updated
        apply(updated)
        app.refreshFolderCount()
        return true
    }

    /// 时间二选一（M月d日起的照片 / 含以前的照片）：系统分段控件，一行。
    private var timePicker: some View {
        Picker(L.s("backup_scope"), selection: $wantsAll) {
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
            let knownSources = Set((albums ?? []).map(\.id)).union(folders.map { FolderMediaSource.bucketId(sourceId: $0.id) })
            onDone(checked, knownSources, wantsAll)
        }
        .disabled(folderBusy)
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
            let folderList = await app.backend.engine.folderSources()
            let folderIds = Set(folderList.map { FolderMediaSource.bucketId(sourceId: $0.id) })
            if hasLoaded {
                checked = Self.selectionForReload(current: checked, saved: saved,
                                                  availableAlbums: Set(list.map(\.id)), availableFolders: folderIds)
            } else {
                let selectedAlbums = Self.initialSelectionWithUnavailable(saved: saved, availableAlbums: Set(list.map(\.id)),
                                                                          cameraAlbum: list.first(where: \.isCameraAlbum)?.id,
                                                                          offersChoices: Self.offersChoices(Self.notice(for: app.access)))
                let selectedFolders = ScopePolicy.initialFolderSelection(saved: saved, known: known, available: folderIds)
                checked = selectedAlbums.union(selectedFolders)
            }
            // 时间档只在首次进入时初始化；授权刷新不覆盖用户尚未保存的选择。
            if !hasLoaded {
                let since = try app.backend.media.savedSince()
                savedSince = since
                wantsAll = ScopePolicy.initialWantsAll(saved: since, partialAccess: app.access == .partial)
            }
            folders = folderList
            albums = list
            hasLoaded = true
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
