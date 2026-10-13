import AVKit
import Photos
import SwiftUI

/// 查看器（对位 Android MediaViewer / VideoScreen；iOS 形态对齐「照片」App）：系统背景色，左右滑翻页
/// （页序 = 打开时的筛选结果快照）。导航栏：左上关闭、标题 = 归属行、副标题 = 「宽×高」；
/// 底部系统工具栏：保存到相册 / 分享（点了才按需取原图）。视频页：先取原图（显示进度）再播放，
/// 失败说「视频没取到」。保存结果用材质 toast 提示。
struct MediaViewer: View {
    let session: ViewerSession
    let timeline: TimelineSource
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var toast: String?
    @State private var share: URL?

    init(session: ViewerSession, timeline: TimelineSource) {
        self.session = session
        self.timeline = timeline
        _index = State(initialValue: session.start)
    }

    private var current: TimelineItem { session.items[min(max(index, 0), session.items.count - 1)] }

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(session.items.enumerated()), id: \.offset) { i, item in
                    ViewerPage(item: item, timeline: timeline).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(PPColor.surfaceDark.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label(L.s("back"), systemImage: "chevron.left") }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(attribution(current)).font(PPFont.subheadlineBold).foregroundStyle(PPColor.paper)
                        if let w = current.width, let h = current.height {
                            Text("\(w)×\(h)").font(PPFont.caption).foregroundStyle(PPColor.paperDim)
                        }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { Task { await save() } } label: { Label(L.s("save_to_gallery"), systemImage: "square.and.arrow.down") }
                    Spacer()
                    Button { Task { await prepareShare() } } label: { Label(L.s("share"), systemImage: "square.and.arrow.up") }
                }
            }
            .toolbarBackground(PPColor.surfaceDark, for: .navigationBar, .bottomBar)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .tint(PPColor.paper)
            .ppToast($toast)
            .sheet(item: $share) { url in ShareSheet(items: [url]) }
        }
    }

    private func attribution(_ item: TimelineItem) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return L.f(item.isMine == false ? "attribution_family" : "attribution_mine", f.string(from: item.takenAt))
    }

    private func save() async {
        let item = current
        guard let url = try? await timeline.original(item, progress: { _ in }) else {
            toast = L.s("share_download_failed")
            Haptics.failure()
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if item.isVideo {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            toast = L.s("saved_to_gallery")
            Haptics.success()
        } catch {
            toast = L.s("share_download_failed")
            Haptics.failure()
        }
    }

    private func prepareShare() async {
        if let url = try? await timeline.original(current, progress: { _ in }) { share = url } else {
            toast = L.s("share_download_failed")
            Haptics.failure()
        }
    }
}

private struct ViewerPage: View {
    let item: TimelineItem
    let timeline: TimelineSource
    @State private var image: UIImage?
    @State private var video: VideoState = .fetching(0)

    enum VideoState: Equatable { case fetching(Double), ready(URL), failed }

    var body: some View {
        Group {
            if item.isVideo { videoBody } else { photoBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) { await load() }
    }

    @ViewBuilder private var photoBody: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            ProgressView().tint(PPColor.paperDim)
        }
    }

    @ViewBuilder private var videoBody: some View {
        switch video {
        case .fetching(let p):
            VStack(spacing: 12) {
                PPProgressBar(value: p, total: 1, tint: PPColor.paper, track: PPColor.paperDim.opacity(0.3)).frame(maxWidth: 220)
                Text(L.s("video_loading")).font(PPFont.body).foregroundStyle(PPColor.paperDim)
            }
        case .ready(let url):
            InlineVideo(url: url)
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "video.slash").font(.largeTitle).foregroundStyle(PPColor.paperDim)
                Text(L.s("video_failed")).font(PPFont.body).foregroundStyle(PPColor.paperDim)
            }
        }
    }

    private func load() async {
        if item.isVideo {
            do {
                let url = try await timeline.original(item) { p in Task { @MainActor in video = .fetching(p) } }
                video = .ready(url)
            } catch { video = .failed }
        } else {
            image = try? await timeline.thumbnail(item, large: true)
        }
    }
}

/// 系统播放器；播放器实例只建一次（直接在 body 里 `AVPlayer(url:)` 会在每次刷新时重建）。
private struct InlineVideo: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(4 / 3, contentMode: .fit)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
