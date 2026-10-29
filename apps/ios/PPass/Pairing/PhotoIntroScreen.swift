import SwiftUI

/// 系统照片权限框之前的一屏说明（#1259，对位 Android 同名屏）：照片去哪、给权限不等于全传、随时能停。
/// 只在系统还没问过照片权限时出现（`AppModel.paired` 判定）；已授权的老用户看不到。不提通知（#1262）。
/// 版式同欢迎页：衬线标题压在下半屏，四条是 ink-60 正文，底部一个主按钮。
struct PhotoIntroScreen: View {
    /// 配对成功后一定有；兜底用「这台电脑」的通用说法。
    let desktopName: String?
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 32)
                    Text(L.s("photo_intro_title")).font(PPFont.serif(32, .regular, relativeTo: .largeTitle))
                        .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.lines(desktopName: desktopName), id: \.self) { line in
                            Text(line).font(PPFont.sans(16, relativeTo: .body)).foregroundStyle(PPColor.ink60).lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 20)
                    PPButton(title: L.s("photo_intro_continue"), height: 60, fontSize: 18, action: onContinue)
                        .padding(.top, 36)
                        .accessibilityIdentifier("photoIntroContinue")
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .leading)
            }
        }
        .ppScreen()
    }

    /// 四条说明，顺序即卡里定稿的顺序。电脑名缺失时用 `storage_device_default`（「这台电脑」）。
    static func lines(desktopName: String?) -> [String] {
        [L.f("photo_intro_where", desktopName ?? L.s("storage_device_default")),
         L.s("photo_intro_full"), L.s("photo_intro_choose"), L.s("photo_intro_stop")]
    }
}
