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
    @State private var photoError: String?
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
            ZoomableImage(image: image)
        } else if let photoError {
            VStack(spacing: 10) {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(PPColor.paperDim)
                Text(photoError).font(PPFont.caption).foregroundStyle(PPColor.paperDim).padding(.horizontal, 24)
            }
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
            // 同 Android：1024 取不到时退回网格里已缓存的 256，都没有才报失败（并写明原因）。
            do { image = try await timeline.thumbnail(item, large: true) } catch {
                NSLog("[PPass] viewer 1024 thumb failed: %@", String(describing: error))
                do { image = try await timeline.thumbnail(item, large: false) } catch {
                    NSLog("[PPass] viewer 256 thumb failed: %@", String(describing: error))
                    photoError = String(String(describing: error).prefix(160))
                }
            }
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

/// 捏合缩放 + 双击放大 / 还原（系统 `UIScrollView` 的缩放，和「照片」App 同一套手势）。
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = FitScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        scroll.addSubview(view)
        context.coordinator.imageView = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        scroll.setNeedsLayout()
    }

    /// 未缩放时让图片视图始终等于可视区（首次布局 / 旋转后才有真实尺寸，不能在 make/update 里一次性设）。
    final class FitScrollView: UIScrollView {
        override func layoutSubviews() {
            super.layoutSubviews()
            guard zoomScale == 1, let view = subviews.first else { return }
            view.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
