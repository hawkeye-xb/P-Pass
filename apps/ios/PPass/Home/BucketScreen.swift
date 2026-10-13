import SwiftUI

/// 选相册（对位 Android BucketScreen.kt）：首次配对后与设置里重选共用。iOS 用系统分组列表：封面缩略图 +
/// 名称（系统没给名字 → 未命名）+ 「新」标记 + 张数 + 勾选标记（Android 是 2 列卡片）。新相册（不在上次已知集合里）
/// 默认不勾。底部：合计张数 + 唯一的主按钮「开始备份」。允许空集 = 一个都不备份（首页随后说「没有可备份的相册」）。
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
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom, spacing: 0) { if albums != nil, error == nil { footer } }
            .toolbar(firstTime ? .automatic : .hidden, for: .tabBar) // 选相册是一次完整任务，底部主按钮占位
            .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let error {
            PPStateMessage(text: error, symbol: "exclamationmark.triangle", actionTitle: L.s("try_again")) { Task { await load() } }
        } else if let albums {
            if albums.isEmpty {
                PPStateMessage(text: L.s("bucket_empty"), symbol: "photo.on.rectangle")
            } else {
                // 系统分组列表：每行 封面缩略图 + 名称（+「新」）+ 张数 + 系统勾选标记。
                List {
                    Section {
                        ForEach(albums) { album in row(album) }
                    } header: {
                        Text(L.s("bucket_hint")).font(.subheadline).textCase(nil).foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else {
            PPStateMessage(text: L.s("bucket_loading"), loading: true)
        }
    }

    private func row(_ album: AlbumBucket) -> some View {
        let on = checked.contains(album.id)
        return Button {
            if on { checked.remove(album.id) } else { checked.insert(album.id) }
            Haptics.selection()
        } label: {
            HStack(spacing: 12) {
                AlbumCover(album: album)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(album.name ?? L.s("bucket_unnamed")).font(.body).foregroundStyle(.primary)
                        if !known.isEmpty, !known.contains(album.id) {
                            Text(L.s("bucket_new")).font(.caption.bold()).foregroundStyle(PPTone.waiting)
                        }
                    }
                    Text(L.f("bucket_count", album.count)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// 底部：合计张数 + 唯一的主按钮「开始备份」，材质底（内容从下面滚过时仍可读）。
    private var footer: some View {
        let total = (albums ?? []).filter { checked.contains($0.id) }.reduce(0) { $0 + $1.count }
        return VStack(spacing: 10) {
            Text(L.f("bucket_summary", total.formatted())).font(.subheadline).foregroundStyle(.secondary)
            PPButton(title: L.s("bucket_start")) {
                onDone(checked, Set((albums ?? []).map(\.id)))
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private func load() async {
        error = nil
        do {
            let list = try await app.backend.media.albums()
            known = app.backend.media.knownAlbums()
            let saved = app.backend.media.savedScope()
            // 新相册默认不勾：已保存范围照旧，只勾当前还存在的。
            checked = (saved ?? []).intersection(Set(list.map(\.id)))
            albums = list
        } catch {
            self.error = String(describing: error)
        }
    }
}

private struct AlbumCover: View {
    let album: AlbumBucket
    @EnvironmentObject var app: AppModel
    @State private var image: UIImage?

    var body: some View {
        Color(uiColor: .secondarySystemFill)
            .frame(width: 56, height: 56)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: album.id) { image = await app.backend.media.cover(album, side: 200) }
    }
}

/// 首次选完相册：「N 张照片，正在回家」。Android 这里有「开启后台备份 / 不开启」两个等高按钮；
/// iOS 本轮只做前台备份（IOS-17：不许用文案假装有后台），所以只留一个「好」。
struct BackupStartedScreen: View {
    let count: Int64
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(PPTone.safe)
                    .accessibilityHidden(true)
                Text(L.f("backup_started_title", count.formatted())).font(.largeTitle.bold())
                Text(L.s("backup_started_body")).font(.body).foregroundStyle(.secondary)
                Text(L.s("idle_auto_hint")).font(.body).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PPButton(title: L.s("ok_got_it"), action: onDone).padding(24)
        }
    }
}
