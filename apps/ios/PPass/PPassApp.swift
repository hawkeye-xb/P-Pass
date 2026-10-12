import SwiftUI

// 占位屏：UI 壳在 #315（IOS-18）里接上。颜色已走 token（#344）。
@main
struct PPassApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                PPColor.paper.ignoresSafeArea()
                Text("P-Pass").foregroundStyle(PPColor.ink)
            }
            // 系统默认 tint 是蓝色：根上统一换成墨色，按钮/开关不会再冒出库色。
            .tint(PPColor.ink)
        }
    }
}
