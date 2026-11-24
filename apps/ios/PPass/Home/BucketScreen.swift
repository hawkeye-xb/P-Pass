import SwiftUI
import PPassCore
import PPassMedia

/// 统一备份范围：相册与文件夹卡片共用选中表现、同一时间档和同一个保存动作。
/// 添加文件夹只登记授权并标成待保存；取消勾选保留授权，移除需单独确认且不删原素材。
/// 首次（从未保存过）不预选任何来源；时间默认「从今天起」；新相册默认不勾。允许空集 = 一个都不备份。
/// 相册未完整授权时只显示「保存过的相册」供取消，不给新增相册。
/// 底部只有主按钮：首次「开始备份」，编辑「保存」。不显示合计张数与大小（iOS 没有公开的大小接口）。
/// 与 Android 的差别只有：标题用系统大标题导航栏；相册是异步读的，所以多了加载中 / 读取失败两种状态。
/// 未完整权限提示与来源卡片对齐 Android（actBg 权限卡、双列等高、菜单收动作、区分失败文案）。
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
            // 移除确认用带文件夹名的 .alert（与 Android AlertDialog 同语义）。
            .alert(L.f("folder_sources_remove_confirm_title", removeTarget?.displayName ?? ""), isPresented: Binding(
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
                        ForEach(Self.visibleAlbums(albums, checked: checked, photoAccess: app.access)) { album in card(album) }
                        ForEach(folders) { folder in folderCard(folder) }
                        addFolderCard
                    }
                }
                .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 14)
            }
        } else {
            PPStateMessage(text: L.s("bucket_loading"), loading: true)
        }
    }

    /// 页面按照片权限档多说的一句（权限两态：完整 / 未完整）。
    enum AccessNotice: Equatable { case none, noAccess }

    /// 完整授权才把相册当成自动备份来源；有限授权和拒绝统一成「相册未完整授权」，同一套提示与出口。
    static func notice(for access: MediaAccess) -> AccessNotice {
        access == .full ? .none : .noAccess
    }

    static func noticeTitleKey(for access: MediaAccess) -> String? {
        notice(for: access) == .noAccess ? "scope_album_no_access_title" : nil
    }

    /// 相册卡片显示哪些：完整授权显示全部；相册未完整授权只显示「当前编辑态里选中的相册」
    /// （已保存的 + 本次未保存勾选的）。已保存但当前列表里没有的相册仍留在 checked（不静默丢范围），
    /// 但无法逐个展示/取消。
    static func visibleAlbums(_ albums: [AlbumBucket], checked: Set<String>, photoAccess: MediaAccess) -> [AlbumBucket] {
        guard photoAccess != .full else { return albums }
        return albums.filter { checked.contains($0.id) }
    }

    /// 首次加载：没有存过的范围一律空——显式传 cameraAlbum 也不预选相机相册；
    /// 已保存的相册全部保留（含当前列表里不可见的），权限恢复后重新可见，不会因权限切换静默丢掉已存范围。
    static func initialSelectionWithUnavailable(saved: Set<String>?, availableAlbums: Set<String>,
                                                cameraAlbum: String?) -> Set<String> {
        guard let saved else { return [] }
        let visible = ScopePolicy.initialSelection(saved: saved, available: availableAlbums, cameraAlbum: cameraAlbum)
        let invisibleSaved = saved.filter { !$0.hasPrefix("folder:") && !availableAlbums.contains($0) }
        return visible.union(invisibleSaved)
    }

    /// 授权后的刷新不得覆盖未保存选择，也绝不静默改变已保存范围：
    /// - 目录：仍可用就保留；
    /// - 已保存的相册：保留在当前 checked 里（none / albums 为空时也不丢，full 恢复后重新可见）；
    ///   用户已主动取消的（不在 current 里）不会被刷新加回；
    /// - 本次未保存勾选的相册：partial 时列表里能展示就保留，none（albums 为空、无法展示）时从编辑态移除。
    /// 只改编辑态，不写持久 scope：用户点保存后才改变持久范围。
    static func selectionForReload(current: Set<String>, saved: Set<String>?, availableAlbums: Set<String>,
                                   availableFolders: Set<String>, photoAccess: MediaAccess) -> Set<String> {
        current.filter { id in
            if id.hasPrefix("folder:") { return availableFolders.contains(id) }
            if saved?.contains(id) == true { return true }
            if photoAccess == .full { return true }
            return availableAlbums.contains(id)
        }
    }

    /// 相册权限提示只针对相册；文件夹仍可添加和备份。首次点击才申请，拒绝后改去系统设置。
    /// 与首页权限卡、Android `AlbumNoAccessNotice` 同一套：actBg 圆角 16 卡、ink 标题、
    /// ink40 正文、40pt 紧凑描边次级按钮。
    private var noAccess: some View {
        let presentation = PhotoAccessPresentation.of(PhotoKitAuthorization().currentLevel())
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L.s("scope_album_no_access_title"))
                .font(PPFont.sans(15, .semibold, relativeTo: .subheadline))
                .foregroundStyle(PPColor.ink)
            Text(L.s("scope_album_no_access_body"))
                .font(PPFont.sans(13, relativeTo: .footnote))
                .foregroundStyle(PPColor.ink40)
                .fixedSize(horizontal: false, vertical: true)
            switch presentation.notice?.action {
            case .requestAccess:
                noticeActionButton(L.s("scope_album_no_access_action")) {
                    Task {
                        let granted = await app.backend.media.requestAccess()
                        AppLog.log("scope: photo access after prompt=\(granted)")
                        app.refreshAccess()
                        await load()
                    }
                }
                .accessibilityIdentifier("bucketRequestAccess")
                .padding(.top, 4)
            case .openAppSettings:
                noticeActionButton(L.s("auto_backup_blocked_action")) { app.openAppSettings() }
                    .accessibilityIdentifier("bucketOpenSettings")
                    .padding(.top, 4)
            case nil:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.actBg, in: shape)
    }

    /// 权限卡里的紧凑次级按钮（Android OutlinedButton：40 高、圆角 14、act 40% 描边、act 字色）。
    private func noticeActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(PPFont.sans(15, .bold, relativeTo: .subheadline))
                .foregroundStyle(PPColor.act)
                .padding(.horizontal, 20)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(PPColor.act.opacity(0.4), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 封面左下角的来源类型角标（相册 / 文件夹），读屏读出类型词（对齐 Android SourceCard 的 kind 图标）。
    private func kindBadge(symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(PPFont.icon(13, .semibold))
            .foregroundStyle(PPColor.ink)
            .padding(6)
            .background(PPColor.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(8)
            .accessibilityLabel(label)
    }

    /// Android BucketCard：圆角 16、选中 paper 底 2pt ink 描边 / 未选 linen 底 1pt border 描边；
    /// 文字区内边距 12/9/12/11；封面左下角标相册类型。
    private func card(_ album: AlbumBucket) -> some View {
        let on = checked.contains(album.id)
        return Button {
            if on { checked.remove(album.id) } else { checked.insert(album.id) }
            Haptics.selection()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                AlbumCover(album: album)
                    .overlay(alignment: .topTrailing) { SelectBadge(selected: on).padding(8) }
                    .overlay(alignment: .bottomLeading) { kindBadge(symbol: "photo.on.rectangle", label: L.s("source_kind_album")) }
                VStack(alignment: .leading, spacing: 2) {
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
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .modifier(SourceCardChrome(selected: on))
    }

    /// 文件夹与相册使用同一选中外观与同一张卡高度；重新授权 / 移除收进标题行右侧的菜单
    /// （对齐 Android SourceCard 的 overflow menu）。
    private func folderCard(_ source: FolderSourceInfo) -> some View {
        let id = FolderMediaSource.bucketId(sourceId: source.id)
        let on = checked.contains(id)
        return ZStack(alignment: .bottomTrailing) {
            Button {
                if on { checked.remove(id) } else { checked.insert(id) }
                Haptics.selection()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    PPColor.linen.aspectRatio(1.6, contentMode: .fit)
                        .overlay { Image(systemName: "folder.fill").font(PPFont.icon(40)).foregroundStyle(PPColor.ink40) }
                        .overlay(alignment: .topTrailing) { SelectBadge(selected: on).padding(8) }
                        .overlay(alignment: .bottomLeading) { kindBadge(symbol: "folder", label: L.s("source_kind_folder")) }
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName).font(PPFont.sans(14.5, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(PPColor.ink).lineLimit(1)
                                .accessibilityIdentifier("folderSourceName")
                            Text(source.available
                                 ? L.f("bucket_count", source.count)
                                 : L.s("folder_sources_status_wait"))
                                .font(PPFont.sans(12.5, relativeTo: .caption)).foregroundStyle(PPColor.ink40)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 44) // 给右下角菜单留出触控区，标题不被压住
                    }
                    .padding(.init(top: 9, leading: 12, bottom: 11, trailing: 12))
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? [.isSelected] : [])

            Menu {
                if !source.available {
                    Button(L.s("folder_sources_reauth")) { reauthTarget = source }
                        .accessibilityIdentifier("folderSourceReauth")
                }
                Button(L.s("folder_sources_remove"), role: .destructive) { removeTarget = source }
                    .accessibilityIdentifier("folderSourceRemove")
            } label: {
                Image(systemName: "ellipsis")
                    .font(PPFont.icon(15, .semibold))
                    .foregroundStyle(PPColor.ink60)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L.s("source_more_actions"))
            .accessibilityIdentifier("folderSourceMore")
            .padding(.trailing, 4)
            .padding(.bottom, 6)
        }
        .disabled(folderBusy)
        .modifier(SourceCardChrome(selected: on))
    }

    /// 「添加文件夹」与来源卡同网格同尺寸：未选 linen 底 + 1pt border 描边，封面与底部信息区高度一致。
    private var addFolderCard: some View {
        Button { showingAddPicker = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                PPColor.linen.aspectRatio(1.6, contentMode: .fit)
                    .overlay { Image(systemName: "plus").font(PPFont.icon(36, .medium)).foregroundStyle(PPColor.ink40) }
                Text(L.s("folder_sources_add")).font(PPFont.sans(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(PPColor.ink).lineLimit(1)
                    .padding(.init(top: 9, leading: 12, bottom: 11, trailing: 12))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(folderBusy)
        .accessibilityIdentifier("folderSourceAdd")
        .modifier(SourceCardChrome(selected: false))
    }

    private func addFolder(_ url: URL) async {
        let before = Set(folders.map(\.id))
        _ = await runFolder("folder-add", failureKey: "folder_sources_add_failed", operation: {
            try await app.backend.engine.addFolderSource(at: url, displayName: url.lastPathComponent)
        }, apply: { updated in
            if let added = updated.first(where: { !before.contains($0.id) }) {
                checked.insert(FolderMediaSource.bucketId(sourceId: added.id))
            }
        })
    }

    private func reauthorize(_ target: FolderSourceInfo, at url: URL) async {
        _ = await runFolder("folder-reauth", failureKey: "folder_sources_reauth_failed") {
            try await app.backend.engine.reauthorizeFolderSource(id: target.id, at: url)
        }
    }

    private func remove(_ target: FolderSourceInfo) async {
        _ = await runFolder("folder-remove", failureKey: "folder_sources_remove_failed",
                            operation: { try app.backend.engine.removeFolderSource(id: target.id) }, apply: { _ in
            checked.remove(FolderMediaSource.bucketId(sourceId: target.id))
        })
    }

    /// 失败提示按操作区分（添加 / 重新授权 / 移除）。
    @discardableResult
    private func runFolder(_ what: String, failureKey: String, operation: () async throws -> Void,
                           apply: ([FolderSourceInfo]) -> Void = { _ in }) async -> Bool {
        guard !folderBusy else { return false }
        folderBusy = true
        defer { folderBusy = false }
        do {
            try await operation()
            AppLog.log("\(what): ok")
        } catch {
            AppLog.log("\(what): failed: \(error)")
            app.notice = UserNotice(message: L.s(failureKey))
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

    /// 「某天起的照片」那一档的选项文字，一律写日期（同 Android `scopeSinceOptionLabel`）：保存过某天 → 那一天；
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
            guard !Task.isCancelled else { return }
            app.refreshAccess() // 读相册时可能刚弹过系统照片权限框（时间档初值看这一档，所以要在下面之前）
            known = app.backend.media.knownAlbums()
            let saved = try app.backend.media.savedScope() // 读失败走下面的 catch（显示错误 + 重试），不当成「从未保存」
            let folderList = await app.backend.engine.folderSources()
            guard !Task.isCancelled else { return }
            let folderIds = Set(folderList.map { FolderMediaSource.bucketId(sourceId: $0.id) })
            if hasLoaded {
                // 已保存来源保留在编辑态（含当前不可见的）；本次未保存勾选只在能展示时保留；不写持久 scope。
                checked = Self.selectionForReload(current: checked, saved: saved, availableAlbums: Set(list.map(\.id)),
                                                  availableFolders: folderIds, photoAccess: app.access)
            } else {
                let selectedAlbums = Self.initialSelectionWithUnavailable(saved: saved, availableAlbums: Set(list.map(\.id)),
                                                                          cameraAlbum: list.first(where: \.isCameraAlbum)?.id)
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
            guard !Task.isCancelled else { return }
            AppLog.log("scope: load failed: \(error)")
            self.error = L.s("command_failed")
        }
    }
}

/// 双列来源卡的统一外壳（对齐 Android SourceCard）：圆角 16；选中 paper 底 + 2pt ink 描边，
/// 未选 linen 底 + 1pt border 描边。视觉值由计算属性给出，单测逐项钉住。
struct SourceCardChrome: ViewModifier {
    let selected: Bool

    /// 圆角 16（对齐 Android SourceCard 的 RoundedCornerShape(16.dp)）。
    var cornerRadius: CGFloat { 16 }
    /// 选中 paper / 未选 linen（对齐 Android SourceCard 的 sourceCardColors）。
    var backgroundColor: Color { selected ? PPColor.paper : PPColor.linen }
    /// 选中 ink / 未选 border（对齐 Android SourceCard 的 border）。
    var borderColor: Color { selected ? PPColor.ink : PPColor.border }
    /// 选中 2pt / 未选 1pt。
    var borderLineWidth: CGFloat { selected ? 2 : 1 }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(backgroundColor, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderLineWidth))
    }
}

/// 右上勾选角标（Android SelectBadge）：22 圆；选中 = ink 底 paper 勾，未选 = paper-dim 底 + 1.5 border-strong 圈。
/// 视觉值由计算属性给出，单测逐项钉住。
struct SelectBadge: View {
    let selected: Bool

    /// 直径 22（对齐 Android SelectBadge 的 size(24.dp) 内圆）。
    var diameter: CGFloat { 22 }
    /// 选中 ink / 未选 paper-dim。
    var fillColor: Color { selected ? PPColor.ink : PPColor.paperDim }
    /// 未选态的描边色。
    var unselectedBorderColor: Color { PPColor.borderStrong }
    /// 未选态的描边宽度。
    var unselectedBorderWidth: CGFloat { 1.5 }

    var body: some View {
        ZStack {
            Circle().fill(fillColor)
            if selected {
                Image(systemName: "checkmark").font(PPFont.icon(11, .bold)).foregroundStyle(PPColor.paper)
            } else {
                Circle().strokeBorder(unselectedBorderColor, lineWidth: unselectedBorderWidth)
            }
        }
        .frame(width: diameter, height: diameter)
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
            .task(id: "\(album.id)|\(album.coverAssetId ?? "")") {
                let loaded = await app.backend.media.cover(album, side: 120)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}
