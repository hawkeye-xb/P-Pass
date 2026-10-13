import SwiftUI

/// 选相册（对位 Android BucketScreen.kt）：首次配对后与设置里重选共用。2 列卡片：封面 + 右上角勾选 +
/// 名称（系统没给名字 → 未命名）+ 「新」标记 + 张数；选中时 2pt 墨色描边。新相册（不在上次已知集合里）
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.s("bucket_title")).font(PPFont.serif(30))
                Text(L.s("bucket_hint")).font(PPFont.body).foregroundStyle(PPColor.ink60)
            }
            .padding(16)
            content
            footer
        }
        .ppScreen()
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let error {
            PPStateMessage(text: error, actionTitle: L.s("try_again")) { Task { await load() } }
        } else if let albums {
            if albums.isEmpty {
                PPStateMessage(text: L.s("bucket_empty"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(albums) { album in card(album) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
        } else {
            PPStateMessage(text: L.s("bucket_loading"), loading: true)
        }
    }

    private func card(_ album: AlbumBucket) -> some View {
        let on = checked.contains(album.id)
        return Button {
            if on { checked.remove(album.id) } else { checked.insert(album.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                AlbumCover(album: album)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(on ? PPColor.paper : PPColor.paper.opacity(0))
                            .frame(width: 26, height: 26)
                            .background(on ? PPColor.ink : PPColor.paper.opacity(0.85), in: Circle())
                            .overlay(Circle().stroke(PPColor.borderStrong, lineWidth: on ? 0 : 1))
                            .padding(8)
                    }
                HStack(spacing: 6) {
                    Text(album.name ?? L.s("bucket_unnamed")).font(PPFont.sans(17, .medium)).lineLimit(1)
                    if !known.isEmpty, !known.contains(album.id) {
                        Text(L.s("bucket_new")).font(PPFont.sans(13, .bold)).foregroundStyle(PPColor.waiting)
                    }
                }
                Text(L.f("bucket_count", album.count)).font(PPFont.sans(15)).foregroundStyle(PPColor.ink40)
            }
            .padding(10)
            .background(PPColor.linen, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(on ? PPColor.ink : PPColor.border, lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        let total = (albums ?? []).filter { checked.contains($0.id) }.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 10) {
            Text(L.f("bucket_summary", total.formatted())).font(PPFont.sans(15)).foregroundStyle(PPColor.ink60)
            PPButton(title: L.s("bucket_start")) {
                onDone(checked, Set((albums ?? []).map(\.id)))
            }
        }
        .padding(16)
        .background(PPColor.paper)
        .overlay(alignment: .top) { Rectangle().fill(PPColor.divider).frame(height: 1) }
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
        Color.clear
            .aspectRatio(1.6, contentMode: .fit)
            .background(PPColor.canvas)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .task(id: album.id) { image = await app.backend.media.cover(album, side: 200) }
    }
}

/// 首次选完相册：「N 张照片，正在回家」。Android 这里有「开启后台备份 / 不开启」两个等高按钮；
/// iOS 本轮只做前台备份（IOS-17：不许用文案假装有后台），所以只留一个「好」。
struct BackupStartedScreen: View {
    let count: Int64
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text(L.f("backup_started_title", count.formatted())).font(PPFont.serif(PPSize.headlineMax))
            Text(L.s("backup_started_body")).font(PPFont.body).foregroundStyle(PPColor.ink60)
            Text(L.s("idle_auto_hint")).font(PPFont.body).foregroundStyle(PPColor.ink60)
            Spacer()
            PPButton(title: L.s("ok_got_it"), height: 60, action: onDone)
        }
        .padding(24)
        .ppScreen()
    }
}
