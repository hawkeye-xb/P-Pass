import AVKit
import PPassCore
import SwiftUI

struct MediaViewer: View {
    let session: ViewerSession
    let timeline: TimelineSource
    let media: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: ViewerState
    @State private var toast: String?
    @State private var share: URL?
    @State private var dragY: CGFloat = 0
    @State private var busy = false
    @State private var work: Task<Void, Never>?
    @State private var sharedFile: URL?

    init(session: ViewerSession, timeline: TimelineSource, media: MediaLibrary) {
        self.session = session
        self.timeline = timeline
        self.media = media
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
        let url: URL
        do { url = try await timeline.original(item, progress: { _ in }) } catch {
            if error is CancellationError || Task.isCancelled { return }
            AppLog.log("viewer save: original failed: \(error)")
            toast = L.s("share_download_failed")
            Haptics.failure()
            return
        }
        defer { if !item.isVideo { LiveTimeline.discardShared(url) } }
        do {
            let outcome = try await media.saveToGallery(fileURL: url, isVideo: item.isVideo, hash: item.id)
            switch outcome {
            case .alreadyExists:
                toast = L.s("already_in_gallery")
            case .saved:
                toast = L.s("saved_to_gallery")
                Haptics.success()
            }
        } catch {
            AppLog.log("viewer save: media library failed: \(error)")
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
            sharedFile = current.isVideo ? nil : url
            share = url
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            AppLog.log("viewer share: original failed: \(error)")
            toast = L.s("share_download_failed")
            Haptics.failure()
        }
    }
}

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

    func play() {
        guard task == nil else { return }
        if case .ready = phase { return }
        AppLog.log("viewer video play tapped")
        phase = .fetching(0)
        task = Task { await fetch() }
    }

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
            phase = .noRoom
        } catch {
            AppLog.log("viewer video failed: \(LiveTimeline.category(error))")
            phase = .failed
        }
    }
}

private struct ViewerPage: View {
    let item: TimelineItem
    let timeline: TimelineSource
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

    private func load() async {
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
