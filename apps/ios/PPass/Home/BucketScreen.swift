import SwiftUI

/// 选相册（对位 Android BucketScreen.kt）：首次配对后与设置里重选共用。同 Android：说明一行 + **2 列封面卡片**
/// （封面 1.6:1 + 右上勾选角标 + 名称 /「新」+ 张数，选中描边变墨色）——也是「照片」App 相簿页的形态。
/// 新相册（不在上次已知集合里）默认不勾。底部：合计张数 + 唯一的主按钮「开始备份」。允许空集 = 一个都不备份。
/// 与 Android 的差别只有：标题用系统大标题导航栏；相册是异步读的，所以多了加载中 / 读取失败两种状态。
struct BucketScreen: View {
    let firstTime: Bool
    let onDone: (Set<String>, Set<String>) -> Void
    @EnvironmentObject var app: AppModel
    @State private var albums: [AlbumBucket]?
    @State private var checked: Set<String> = []
    @State private var known: Set<String> = []
    @State private var error: String?

    var body: some View {
        content
            .navigationTitle(L.s("bucket_title"))
            .ppNavBar()
            .ppScreen()
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom, spacing: 0) { if albums != nil, error == nil { footer } }
            .toolbar(firstTime ? .automatic : .hidden, for: .tabBar) // 选相册是一次完整任务，底部主按钮占位
            .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let error {
            PPStateMessage(text: error, symbol: "exclamationmark.triangle", actionTitle: L.s("try_again")) { Task { await load() } }
        } else if let albums {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L.s("bucket_hint")).font(PPFont.sans(14, relativeTo: .subheadline)).foregroundStyle(PPColor.ink40)
                        .fixedSize(horizontal: false, vertical: true)
                    if albums.isEmpty {
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

    /// 底部：合计张数 + 唯一的主按钮「开始备份」（Android 60 高 / 18 字）。paper 底 + 顶部分隔线：网格从下面滚过时仍可读。
    private var footer: some View {
        let total = (albums ?? []).filter { checked.contains($0.id) }.reduce(0) { $0 + $1.count }
        return VStack(spacing: 10) {
            Text(L.f("bucket_summary", total.formatted())).font(PPFont.sans(13.5, relativeTo: .footnote)).foregroundStyle(PPColor.ink60)
                .multilineTextAlignment(.center)
            PPButton(title: L.s("bucket_start"), height: 60, fontSize: 18) {
                onDone(checked, Set((albums ?? []).map(\.id)))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(PPColor.paper.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { PPDivider() }
    }

    private func load() async {
        error = nil
        do {
            let list = try await app.backend.media.albums()
            known = app.backend.media.knownAlbums()
            let saved = try app.backend.media.savedScope() // 读失败走下面的 catch（显示错误 + 重试），不当成「从未保存」
            // 新相册默认不勾：已保存范围照旧，只勾当前还存在的。
            checked = (saved ?? []).intersection(Set(list.map(\.id)))
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

/// 首次选完相册：「N 张照片，正在回家」+「开启后台备份 / 不开启后台备份」两个等高按钮（对位 Android `BackupStartedScreen`，#982）。
/// 后台备份默认关，由用户在这里选；iOS 的后台只能由系统挑时机，所以多一句不承诺的说明（#343：不写频率、不假装有后台）。
struct BackupStartedScreen: View {
    let count: Int64
    /// #975：点任一按钮时会先问一次通知授权——页面上先用一句话讲清用途（Android `notificationAskNote`）。
    var asksNotification = false
    /// 参数 = 用户是否选了「开启后台备份」。
    let onDone: (_ enableBackgroundBackup: Bool) -> Void

    /// 同 Android：safe-bg 整页底、内容竖直居中、标题衬线 34 safe 色（这一屏说的就是「已确认在回家」），无图标。
    /// iOS 多一句 background_backup_ios_note：iOS 后台只能由系统挑时机，必须说清楚（平台事实，Android 没有这层）。
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L.f("backup_started_title", count.formatted())).font(PPFont.serif(34, .regular, relativeTo: .largeTitle))
                        .foregroundStyle(PPColor.safe).fixedSize(horizontal: false, vertical: true)
                    Text(L.s("backup_started_body")).font(PPFont.sans(16)).foregroundStyle(PPColor.ink60).lineSpacing(5)
                        .padding(.top, 14)
                    Text(L.s("background_backup_ios_note")).font(PPFont.sans(15, relativeTo: .subheadline)).foregroundStyle(PPColor.ink40)
                        .lineSpacing(4).padding(.top, 12)
                    if asksNotification {
                        Text(L.s("onboarding_notification_note")).font(PPFont.sans(15, relativeTo: .subheadline)).foregroundStyle(PPColor.ink40)
                            .lineSpacing(4).padding(.top, 12)
                    }
                    VStack(spacing: 12) {
                        PPButton(title: L.s("background_backup_enable"), height: 60, fontSize: 18) { onDone(true) }
                        PPButton(title: L.s("background_backup_not_now"), kind: .quiet, height: 60, fontSize: 18) { onDone(false) }
                    }
                    .padding(.top, 28)
                }
                .padding(.horizontal, 30).padding(.bottom, 40)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .leading)
            }
        }
        .ppScreen(PPColor.safeBg)
    }
}
