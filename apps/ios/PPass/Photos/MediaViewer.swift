import AVKit
import Photos
import SwiftUI

/// 查看器（对位 Android MediaViewer / VideoScreen）：深色底，左右滑翻页（页序 = 打开时的筛选结果快照）。
/// 照片页：左上返回、右上「宽×高」、归属行、可缩放的大图、底部两个等宽按钮「保存到相册 / 分享」——
/// 点了才按需取原图。视频页：先取原图（显示进度）再播放，失败说「视频没取到」。
struct MediaViewer: View {
    let session: ViewerSession
    let timeline: TimelineSource
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int

    init(session: ViewerSession, timeline: TimelineSource) {
        self.session = session
        self.timeline = timeline
        _index = State(initialValue: session.start)
    }

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(session.items.enumerated()), id: \.offset) { i, item in
                ViewerPage(item: item, timeline: timeline, close: { dismiss() }).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(PPColor.surfaceDark.ignoresSafeArea())
    }
}

private struct ViewerPage: View {
    let item: TimelineItem
    let timeline: TimelineSource
    let close: () -> Void
    @State private var image: UIImage?
    @State private var toast: String?
    @State private var share: URL?
    @State private var video: VideoState = .fetching(0)

    enum VideoState: Equatable { case fetching(Double), ready(URL), failed }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: close) {
                    Label(L.s("back"), systemImage: "chevron.left").font(PPFont.sans(17, .medium))
                        .frame(minHeight: 44)
                }
                Spacer()
                if let w = item.width, let h = item.height {
                    Text("\(w)×\(h)").font(PPFont.sans(15)).foregroundStyle(PPColor.paper.opacity(0.62))
                }
            }
            Text(attribution).font(PPFont.sans(15)).foregroundStyle(PPColor.paper.opacity(0.62))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if item.isVideo { videoBody } else { photoBody }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                pill(L.s("save_to_gallery")) { await save() }
                pill(L.s("share")) { await prepareShare() }
            }
            if let toast { Text(toast).font(PPFont.sans(15)).foregroundStyle(PPColor.paper) }
        }
        .padding(16)
        .foregroundStyle(PPColor.paper)
        .tint(PPColor.paper)
        .task(id: item.id) { await load() }
        .sheet(item: $share) { url in ShareSheet(items: [url]) }
    }

    private var attribution: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return L.f(item.isMine == false ? "attribution_family" : "attribution_mine", f.string(from: item.takenAt))
    }

    @ViewBuilder private var photoBody: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private var videoBody: some View {
        switch video {
        case .fetching(let p):
            VStack(spacing: 12) {
                ProgressView(value: p).frame(maxWidth: 220)
                Text(L.s("video_loading")).font(PPFont.body).foregroundStyle(PPColor.paper.opacity(0.8))
            }
        case .ready(let url):
            VideoPlayer(player: AVPlayer(url: url)).aspectRatio(4 / 3, contentMode: .fit)
        case .failed:
            Text(L.s("video_failed")).font(PPFont.body).foregroundStyle(PPColor.paper.opacity(0.8))
        }
    }

    /// 二选一的两个动作：同一组件、等宽、同高（tokens.json：二元选择同尺寸）。
    private func pill(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title).font(PPFont.sans(16, .bold)).frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(PPColor.ink).background(PPColor.paper, in: Capsule())
        }
        .buttonStyle(.plain)
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

    private func save() async {
        guard let url = try? await timeline.original(item, progress: { _ in }) else {
            toast = L.s("share_download_failed")
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
        } catch {
            toast = L.s("share_download_failed")
        }
    }

    private func prepareShare() async {
        if let url = try? await timeline.original(item, progress: { _ in }) { share = url } else {
            toast = L.s("share_download_failed")
        }
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
