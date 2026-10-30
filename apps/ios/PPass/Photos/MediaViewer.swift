import AVKit
import Photos
import PPassCore
import SwiftUI

/// 查看器（对位 Android MediaViewer / VideoScreen；iOS 形态对齐「照片」App）：系统背景色，左右滑翻页
/// （页序 = 打开时的筛选结果快照）。导航栏：左上关闭、标题 = 归属行、副标题 = 「宽×高」；
/// 底部系统工具栏：保存到相册 / 分享（点了才按需取原图）。视频页：只显示封面和标着文件大小的播放按钮，
/// 点了才取原图（显示进度）、取完才播放；失败说「视频没取到」。保存结果用材质 toast 提示。
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
            AppLog.log("viewer save: original failed: \(error)")
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
            AppLog.log("viewer save: photo library failed: \(error)")
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
            AppLog.log("viewer share: original failed: \(error)")
            toast = L.s("share_download_failed")
            Haptics.failure()
        }
    }
}

/// 视频页的取回与播放（对位 Android `VideoPlayback`）：建出来只有封面，用户点了播放（[play]）才取原图。
/// 取回前的大小 / 空间检查和超过声明大小即中止都在 `LiveTimeline.original` 里，保存 / 分享视频同样经过。
@MainActor
final class VideoPlaybackModel: ObservableObject {
    enum Phase: Equatable { case cover, fetching(Double), ready(URL), noRoom, failed }

    @Published private(set) var phase: Phase = .cover
    private let item: TimelineItem
    private let timeline: TimelineSource
    private var task: Task<Void, Never>?

    init(item: TimelineItem, timeline: TimelineSource) {
        self.item = item
        self.timeline = timeline
    }

    /// 用户点了播放。正在取或已就绪时忽略重复点击。
    func play() {
        guard task == nil else { return }
        if case .ready = phase { return }
        AppLog.log("viewer video play tapped")
        phase = .fetching(0)
        task = Task { await fetch() }
    }

    /// 翻走 / 关闭：取消还在进行的取回，回到封面。
    func stop() {
        task?.cancel()
        task = nil
        if case .fetching = phase { phase = .cover }
    }

    private func fetch() async {
        defer { task = nil }
        do {
            let url = try await timeline.original(item) { p in
                Task { @MainActor [weak self] in
                    guard let self, case .fetching = self.phase else { return }
                    self.phase = .fetching(p)
                }
            }
            try Task.checkCancellation()
            phase = .ready(url)
            AppLog.log("viewer video fetched, playing")
        } catch is CancellationError {
            if case .fetching = phase { phase = .cover }
        } catch LiveTimeline.Failure.noRoom {
            phase = .noRoom // 原因已由 original() 记进日志
        } catch {
            AppLog.log("viewer video failed: \(LiveTimeline.category(error))")
            phase = .failed
        }
    }
}

private struct ViewerPage: View {
    let item: TimelineItem
    let timeline: TimelineSource
    /// 翻离视频页时取消还在进行的取回（Android 同：页面离开即取消）。
    var active = true
    var onZoom: (Bool) -> Void = { _ in }
    @State private var image: UIImage?
    @State private var photoError: String?
    @State private var photoRejected = false
    @StateObject private var video: VideoPlaybackModel

    init(item: TimelineItem, timeline: TimelineSource, active: Bool = true, onZoom: @escaping (Bool) -> Void = { _ in }) {
        self.item = item
        self.timeline = timeline
        self.active = active
        self.onZoom = onZoom
        _video = StateObject(wrappedValue: VideoPlaybackModel(item: item, timeline: timeline))
    }

    var body: some View {
        Group {
            if item.isVideo { videoBody } else { photoBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) { await load() }
        .onChange(of: active) { now in if !now { video.stop() } }
    }

    @ViewBuilder private var photoBody: some View {
        if let image {
            ZoomableImage(image: image, onZoom: onZoom)
        } else if photoError != nil {
            // 原始错误只进日志（load() 里已记），界面只说人话（tokens.json rules：报错不出现代码）。
            VStack(spacing: 10) {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(PPColor.paperDim)
                Text(L.s(photoRejected ? "preview_unavailable" : "photos_unreachable")).font(PPFont.body).foregroundStyle(PPColor.paperDim).padding(.horizontal, 24)
            }
        } else {
            ProgressView().tint(PPColor.paperDim)
        }
    }

    @ViewBuilder private var videoBody: some View {
        switch video.phase {
        case .fetching(let p):
            VStack(spacing: 12) {
                PPProgressBar(value: p, total: 1, tint: PPColor.paper, track: PPColor.paperDim.opacity(0.3)).frame(maxWidth: 220)
                Text(L.f("video_loading", Int(p * 100))).font(PPFont.body).foregroundStyle(PPColor.paperDim)
            }
        case .ready(let url):
            InlineVideo(url: url)
        case .cover, .noRoom, .failed:
            VideoCover(image: image, bytes: item.bytes, notice: coverNotice, onPlay: video.play)
        }
    }

    private var coverNotice: String? {
        switch video.phase {
        case .noRoom: return L.s("video_no_space")
        case .failed: return L.s("video_failed")
        default: return nil
        }
    }

    /// 照片取预览，视频取封面——都是电脑生成的缩略图，不取原片。
    private func load() async {
        // 同 Android：1024 取不到时退回网格里已缓存的 256，都没有才报失败（并写明原因）。
        do { image = try await timeline.thumbnail(item, large: true) } catch {
            AppLog.log("viewer 1024 thumb failed: \(LiveTimeline.category(error))")
            do { image = try await timeline.thumbnail(item, large: false) } catch {
                AppLog.log("viewer 256 thumb failed: \(LiveTimeline.category(error))")
                photoRejected = error is DesktopThumb.Rejection
                photoError = String(String(describing: error).prefix(160))
            }
        }
    }
}

/// 视频页的初始样子（对位 Android `VideoCover`）：封面 + 居中的播放按钮，按钮上是原片大小。没点之前只有这些。
private struct VideoCover: View {
    let image: UIImage?
    let bytes: Int64?
    let notice: String?
    let onPlay: () -> Void

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            }
            VStack(spacing: 12) {
                Button(action: onPlay) {
                    Label(L.f("video_play_size", ByteCountFormatter.string(fromByteCount: max(bytes ?? 0, 0), countStyle: .file)),
                          systemImage: "play.fill")
                        .frame(minHeight: PPSize.tapMin)
                }
                .buttonStyle(PPChipButtonStyle())
                if let notice {
                    Text(notice).font(PPFont.body).foregroundStyle(PPColor.paper).multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(PPColor.surfaceDark.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 24)
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
/// 记录在存储根里的文件（`SavedToGalleryStore`，#1152）：不进备份，断开配对时由断开清单清掉。
enum SavedToGallery {
    private static let store: SavedToGalleryStore? = {
        guard let root = try? LiveBackend.resolveRoot(logger: NoopLogger()) else { return nil }
        return SavedToGalleryStore(directory: root.url)
    }()

    static func remember(hash: String, localIdentifier: String) {
        try? store?.remember(hash: hash, localIdentifier: localIdentifier)
    }

    static func stillExists(hash: String) -> Bool {
        guard let id = store?.localIdentifier(for: hash) else { return false }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count > 0
    }
}
