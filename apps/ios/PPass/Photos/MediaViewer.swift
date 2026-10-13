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
    @StateObject private var state: ViewerState
    @State private var toast: String?
    @State private var share: URL?
    @State private var dragY: CGFloat = 0
    @State private var busy = false
    /// 保存 / 分享的取回任务：关掉大图时取消，FFI 取回随之中止（#953）。
    @State private var work: Task<Void, Never>?
    /// 当前分享面板里那份原图；面板关闭后立即删（手机不留原图副本）。
    @State private var sharedFile: URL?

    init(session: ViewerSession, timeline: TimelineSource) {
        self.session = session
        self.timeline = timeline
        _state = StateObject(wrappedValue: ViewerState(index: session.start))
    }

    private var current: TimelineItem { session.items[min(max(state.index, 0), session.items.count - 1)] }

    var body: some View {
        NavigationStack {
            pager
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
                    Button { work = Task { await save() } } label: { Label(L.s("save_to_gallery"), systemImage: "square.and.arrow.down") }
                        .disabled(busy)
                    Spacer()
                    if busy { ProgressView().tint(PPColor.paper); Spacer() }
                    Button { work = Task { await prepareShare() } } label: { Label(L.s("share"), systemImage: "square.and.arrow.up") }
                        .disabled(busy)
                }
            }
            .toolbarBackground(PPColor.surfaceDark, for: .navigationBar, .bottomBar)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .tint(PPColor.paper)
            .ppToast($toast)
            .sheet(item: $share, onDismiss: {
                if let sharedFile { LiveTimeline.discardShared(sharedFile) }
                sharedFile = nil
            }) { url in ShareSheet(items: [url]) }
            .onDisappear { work?.cancel() }
        }
    }

    /// 翻页交给系统 `UIPageViewController`（照片 App 同款：跟手、半屏出两页、按速度与位移判定、回弹曲线都是系统的）。
    /// 下拉关闭是另一条竖向手势；放大状态下两者都让给缩放视图。
    private var pager: some View {
        PageViewer(count: session.items.count, state: state) { i in
            AnyView(PageSlot(state: state, index: i, item: session.items[i], timeline: timeline))
        }
        .offset(y: dragY)
        .opacity(1 - min(dragY / 400, 0.5))
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { v in
                    guard !state.zoomed, abs(v.translation.height) > abs(v.translation.width) else { return }
                    dragY = max(v.translation.height, 0)
                }
                .onEnded { v in
                    guard dragY > 0 else { return }
                    if dragY >= 96 || v.predictedEndTranslation.height > 400 { dismiss() } else {
                        withAnimation(.interpolatingSpring(stiffness: 220, damping: 26)) { dragY = 0 }
                    }
                }
        )
    }

    private func attribution(_ item: TimelineItem) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return L.f(item.isMine == true ? "attribution_mine" : "attribution_family", f.string(from: item.takenAt))
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let item = current
        // 已存过且那张还在相册里 → 不再存第二份（Android MOB-24）。
        if SavedToGallery.stillExists(hash: item.id) {
            toast = L.s("already_in_gallery")
            return
        }
        let url: URL
        do { url = try await timeline.original(item, progress: { _ in }) } catch {
            if error is CancellationError || Task.isCancelled { return }
            NSLog("[PPass] viewer save: original failed: %@", String(describing: error))
            toast = L.s("share_download_failed")
            Haptics.failure()
            return
        }
        // 存相册完成（成功或失败）后原图即删：照片库已有自己的一份，不在 tmp 里再留。
        defer { if !item.isVideo { LiveTimeline.discardShared(url) } }
        do {
            var placeholder: String?
            try await PHPhotoLibrary.shared().performChanges {
                let request = item.isVideo
                    ? PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    : PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                placeholder = request?.placeholderForCreatedAsset?.localIdentifier
            }
            if let placeholder { SavedToGallery.remember(hash: item.id, localIdentifier: placeholder) }
            toast = L.s("saved_to_gallery")
            Haptics.success()
        } catch {
            NSLog("[PPass] viewer save: photo library failed: %@", String(describing: error))
            toast = L.s("share_download_failed")
            Haptics.failure()
        }
    }

    private func prepareShare() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let url = try await timeline.original(current, progress: { _ in })
            if Task.isCancelled { if !current.isVideo { LiveTimeline.discardShared(url) }; return }
            sharedFile = current.isVideo ? nil : url // 视频是缓存目录里的复用文件，不删
            share = url
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            NSLog("[PPass] viewer share: original failed: %@", String(describing: error))
            toast = L.s("share_download_failed")
            Haptics.failure()
        }
    }
}

private struct ViewerPage: View {
    let item: TimelineItem
    let timeline: TimelineSource
    /// 当前页才取视频原图：邻页只预备缩略图，左右滑一下不会静默下载整段视频（Android 同）。
    var active = true
    var onZoom: (Bool) -> Void = { _ in }
    @State private var image: UIImage?
    @State private var photoError: String?
    @State private var video: VideoState

    enum VideoState: Equatable { case fetching(Double), ready(URL), failed }

    init(item: TimelineItem, timeline: TimelineSource, active: Bool = true, onZoom: @escaping (Bool) -> Void = { _ in }) {
        self.item = item
        self.timeline = timeline
        self.active = active
        self.onZoom = onZoom
        // 已缓存的视频直接就绪：滑回来不再从 0 开始、进度条不会再跳。
        _video = State(initialValue: timeline.cachedOriginal(item).map(VideoState.ready) ?? .fetching(0))
    }

    var body: some View {
        Group {
            if item.isVideo { videoBody } else { photoBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(item.id)-\(active)") { await load() }
    }

    @ViewBuilder private var photoBody: some View {
        if let image {
            ZoomableImage(image: image, onZoom: onZoom)
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
                Text(L.f("video_loading", Int(p * 100))).font(PPFont.body).foregroundStyle(PPColor.paperDim)
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
            guard active else { return }
            if case .ready = video { return }
            do {
                let url = try await timeline.original(item) { p in Task { @MainActor in video = .fetching(p) } }
                video = .ready(url)
            } catch is CancellationError {
                return // 划走 / 关闭：任务被取消，不当作失败
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
            .onAppear { if player == nil { player = AVPlayer(url: url) }; player?.play() }
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
    var onZoom: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onZoom: onZoom) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = FitScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.isScrollEnabled = false
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
        let onZoom: (Bool) -> Void
        init(onZoom: @escaping (Bool) -> Void) { self.onZoom = onZoom }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.01
            // 未放大时关掉内部平移：否则 UIScrollView 的手势会吞掉横向拖动，外层翻页就跟不上手指。
            scrollView.isScrollEnabled = zoomed
            onZoom(zoomed)
        }
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

final class ViewerState: ObservableObject {
    @Published var index: Int
    @Published var zoomed = false
    init(index: Int) { self.index = index }
}

/// 一页：只有当前页算「活跃」（视频只在活跃页取原图）。
private struct PageSlot: View {
    @ObservedObject var state: ViewerState
    let index: Int
    let item: TimelineItem
    let timeline: TimelineSource

    var body: some View {
        ViewerPage(item: item, timeline: timeline, active: state.index == index,
                   onZoom: { if state.index == index { state.zoomed = $0 } })
    }
}

private final class IndexedHost: UIHostingController<AnyView> {
    var pageIndex = 0
}

private struct PageViewer: UIViewControllerRepresentable {
    let count: Int
    @ObservedObject var state: ViewerState
    let page: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let vc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                      options: [.interPageSpacing: 20])
        vc.dataSource = context.coordinator
        vc.delegate = context.coordinator
        vc.view.backgroundColor = .clear
        context.coordinator.pager = vc
        vc.setViewControllers([context.coordinator.controller(state.index)], direction: .forward, animated: false)
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // 放大时关掉系统翻页的横向滚动，手势归缩放视图。
        for case let scroll as UIScrollView in vc.view.subviews { scroll.isScrollEnabled = !state.zoomed }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageViewer
        weak var pager: UIPageViewController?
        /// 页控制器按序号复用：每次滑动都新建会丢掉页内状态（视频进度 / 缩放），表现为「滑回来又从头加载」。
        private var hosts: [Int: IndexedHost] = [:]
        init(_ parent: PageViewer) { self.parent = parent }

        func controller(_ i: Int) -> UIViewController {
            if let hit = hosts[i] { return hit }
            let host = IndexedHost(rootView: parent.page(i))
            host.pageIndex = i
            host.view.backgroundColor = .clear
            hosts[i] = host
            return host
        }

        func trim(around i: Int) {
            for key in hosts.keys where abs(key - i) > 2 { hosts[key] = nil }
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? IndexedHost)?.pageIndex, i > 0 else { return nil }
            return controller(i - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? IndexedHost)?.pageIndex, i < parent.count - 1 else { return nil }
            return controller(i + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let i = (pvc.viewControllers?.first as? IndexedHost)?.pageIndex else { return }
            parent.state.zoomed = false
            parent.state.index = i
            trim(around: i)
        }
    }
}

/// 「保存到相册」去重：记下 内容哈希 → 相册里那张的 localIdentifier；再点保存时若那张还在就不再存。
enum SavedToGallery {
    private static let key = "ppass.saved_to_gallery"

    static func remember(hash: String, localIdentifier: String) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map[hash] = localIdentifier
        UserDefaults.standard.set(map, forKey: key)
    }

    static func stillExists(hash: String) -> Bool {
        guard let id = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[hash] else { return false }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count > 0
    }
}
