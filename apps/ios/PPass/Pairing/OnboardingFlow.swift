import AVFoundation
import PPassCore
import SwiftUI

/// 欢迎 → 扫码 / 手动输入配对串 → 配对状态（对位 Android Onboarding.kt + ScanScreen.kt + PairStatusScreen）。
/// 手动粘贴的配对串与二维码是**同一个字符串**，走同一条路（`AppModel` → PairingService.pair）。
/// 没有相机（模拟器）或没给相机权限时，扫码页直接说明并给出「手动输入」入口。
struct OnboardingFlow: View {
    /// `manual(fromScan:)`：手动输入从哪儿进来就退回哪儿（Android ScanScreen `leaveManual`：扫码页点进来 → 回扫码页，
    /// 欢迎页直接进来 → 回欢迎页）。
    enum Step: Equatable { case welcome, scan, manual(fromScan: Bool), status(PairStep) }
    enum PairStep: Equatable {
        case waiting
        /// #1118：提交成功之后才有的验证码页（电脑名 + 6 位数字 + 电脑标识）。扫码后不经任何询问直接到这里（中间只有发请求的等待）。
        case code(PairCodeShown)
        case refused(lapsed: Bool, note: String?), needsUpdate(OutdatedSide), failed(String)
    }

    @EnvironmentObject var app: AppModel
    @State private var step: Step = .welcome
    @State private var pairTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch step {
            case .welcome: welcome
            case .scan: ScanScreen(onCode: submit, onManual: { step = .manual(fromScan: true) }, onClose: { step = .welcome })
            case .manual(let fromScan): ManualPairScreen(onSubmit: submit, onBack: { step = Self.manualBackTarget(fromScan: fromScan) })
            case .status(let s): PairStatusScreen(step: s, onCancel: cancel, onRetry: { step = .scan })
            }
        }
        .onAppear(perform: applyRoute)
    }

    /// 同 Android WelcomeScreen：顶部字标「P-PASS」，标题衬线 36 压在下半屏，三步是三行 ink-40 小字（不成卡），
    /// 主按钮 64 高 / 19 字，下面「手动输入」14 粗体 ink-60。无插图。
    /// 手动输入页「返回」去哪（Android `leaveManual`）。
    static func manualBackTarget(fromScan: Bool) -> Step { fromScan ? .scan : .welcome }

    private var welcome: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "P-PASS").font(PPFont.sans(14, .bold, relativeTo: .subheadline)).kerning(2.5)
                        .foregroundStyle(PPColor.ink60).accessibilityHidden(true)
                    Spacer(minLength: 32)
                    Text(L.s("welcome_headline")).font(PPFont.serif(36, .regular, relativeTo: .largeTitle))
                        .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    Text(L.s("welcome_sub")).font(PPFont.body).foregroundStyle(PPColor.ink60).lineSpacing(6).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(["welcome_step1", "welcome_step2", "welcome_step3"], id: \.self) { key in
                            Text(L.s(key)).font(PPFont.sans(15, relativeTo: .subheadline)).foregroundStyle(PPColor.ink40).lineSpacing(5)
                        }
                    }
                    .padding(.top, 20)
                    PPButton(title: L.s("welcome_scan"), height: 64, fontSize: 19) { step = .scan }.padding(.top, 40)
                    Button(L.s("scan_manual_link")) { step = .manual(fromScan: false) }
                        .font(PPFont.sans(14, .bold, relativeTo: .subheadline)).foregroundStyle(PPColor.ink60)
                        .frame(maxWidth: .infinity, minHeight: 44).padding(.top, 8)
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .leading)
            }
        }
        .ppScreen()
    }

    private func submit(_ code: String) {
        step = .status(.waiting)
        let onCode: PairCodeSink = { shown in
            await MainActor.run { step = .status(.code(shown)) }
            #if DEBUG
            E2EPairCode.record(shown)
            #endif
        }
        pairTask = Task {
            let outcome = await app.backend.pairing.pair(code: code, onCode: onCode)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .joined(let firstTime, let settingSaveFailed): app.paired(firstTime: firstTime, settingSaveFailed: settingSaveFailed)
            case .refused(let note, let ownerSaidNo):
                step = .status(.refused(lapsed: !ownerSaidNo, note: note?.text))
            case .needsUpdate(let side): step = .status(.needsUpdate(side))
            case .failed(let reason): step = .status(.failed(reason))
            }
        }
    }

    private func cancel() {
        pairTask?.cancel()
        Task { await app.backend.pairing.cancel() }
        step = .welcome
    }

    private func applyRoute() {
        switch LaunchRoute.current {
        case .scan: step = .scan
        case .manual: step = .manual(fromScan: false)
        case .pairWaiting: step = .status(.waiting)
        case .pairCode:
            step = .status(.code(PairCodeShown(code: "482916", desktop: PairDesktopInfo(name: "Home-Computer", fingerprint: "AB12 CD34"),
                                               phoneNode: "")))
        case .pairRefused: step = .status(.refused(lapsed: false, note: nil))
        case .pairLapsed: step = .status(.refused(lapsed: true, note: PairNote.expired.text))
        case .pairFailed: step = .status(.failed("demo: unreachable"))
        default: break
        }
    }
}

struct ManualPairScreen: View {
    let onSubmit: (String) -> Void
    let onBack: () -> Void
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("", text: $text, prompt: Text(L.s("scan_manual_placeholder")).foregroundColor(PPColor.ink40), axis: .vertical)
                        .font(PPFont.mono)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .lineLimit(3...8)
                        .accessibilityIdentifier("pairCodeField")
                } header: {
                    Text(L.s("scan_manual_body")).font(PPFont.subheadline).textCase(nil).foregroundStyle(PPColor.ink60)
                        .padding(.bottom, 4)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if invalid {
                            Label(L.s("scan_manual_invalid"), systemImage: "exclamationmark.circle.fill").font(PPFont.footnote).foregroundStyle(PPColor.act)
                        }
                        Text(L.s("scan_manual_note")).font(PPFont.footnote).foregroundStyle(PPColor.ink40)
                    }
                }
            }
            .ppList()
            .navigationTitle(L.s("scan_manual_title"))
            .ppNavBar()
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onBack) { Label(L.s("back"), systemImage: "chevron.left") }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    PPButton(title: L.s("scan_manual_paste"), kind: .quiet) {
                        if let s = UIPasteboard.general.string { text = s }
                    }
                    PPButton(title: L.s("scan_manual_submit")) {
                        if let code = PairCode.normalized(text) { onSubmit(code) } else { invalid = true; Haptics.failure() }
                    }
                    .accessibilityIdentifier("pairSubmit")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(PPColor.paper.ignoresSafeArea(edges: .bottom))
                .overlay(alignment: .top) { PPDivider() }
            }
        }
        .onAppear {
            // 自动化（模拟器端到端）：环境变量直接给配对串，等同于用户粘贴后点「连接」。
            if let code = ProcessInfo.processInfo.environment["PPASS_PAIR_CODE"], !code.isEmpty {
                text = code
                if let c = PairCode.normalized(code) { onSubmit(c) }
            }
        }
    }
}

struct PairStatusScreen: View {
    let step: OnboardingFlow.PairStep
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // 同 Android PairStatusScreen：只有标题 + 正文，不加状态图标；等待时保留系统转圈（原生的进行中指示）。
                switch step {
                case .waiting:
                    ProgressView().controlSize(.large).padding(.bottom, 6)
                    message(title: L.s("pair_waiting_title"), body: L.s("pair_waiting_body"))
                case .code(let shown):
                    PairCodeView(shown: shown)
                case .refused(let lapsed, let note):
                    message(title: L.s(lapsed ? "pair_lapsed_title" : "pair_refused_title"), body: L.s("pair_refused_body"),
                            note: note)
                case .needsUpdate(let side):
                    // #1069：配对过程中发现版本不兼容——标题「需要更新」，正文说清是哪一端的 P-Pass。
                    message(title: L.s("pair_needs_update_title"),
                            body: L.s(side == .phone ? "state_waiting_phone_outdated" : "state_waiting_desktop_outdated"))
                case .failed(let reason):
                    message(title: L.s("pair_failed_title"), body: L.s("pair_failed_body"),
                            note: "(\(String(reason.prefix(160))))")
                }
            }
            .padding(34)
            .frame(maxWidth: .infinity)
        }
        .ppScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 同 Android：两种状态都是描边次级按钮（58 高 / 18 字），这一屏没有主动作。
            Group {
                if step.isWaiting {
                    PPButton(title: L.s("cancel"), kind: .quiet, height: 58, fontSize: 18, action: onCancel)
                } else {
                    PPButton(title: L.s("scan_again"), kind: .quiet, height: 58, fontSize: 18, action: onRetry)
                }
            }
            .padding(.horizontal, 34).padding(.bottom, 24)
        }
    }

    private func message(title: String, body: String, note: String? = nil) -> some View {
        VStack(spacing: 14) {
            Text(title).font(PPFont.serif(30, .regular, relativeTo: .title)).multilineTextAlignment(.center)
            Text(body).font(PPFont.body).foregroundStyle(PPColor.ink40).lineSpacing(5).multilineTextAlignment(.center)
            if let note { Text(note).font(PPFont.footnote).foregroundStyle(PPColor.ink40).multilineTextAlignment(.center) }
        }
    }
}

extension OnboardingFlow.PairStep {
    /// 还在等的两种（发请求中 / 显示验证码中）：底部是「取消」，其余是「重新扫码」。
    var isWaiting: Bool {
        switch self {
        case .waiting, .code: return true
        default: return false
        }
    }
}

/// 验证码页（对位 Android PairCodeScreen），从上到下、主次由强到弱：「正在连接」小标签 → 电脑名 → 6 位验证码（3 + 3）→
/// 说明 → 电脑标识。字号只用 PPFont 语义样式（随系统字号缩放）：验证码 pairCode > 电脑名 title3 > 说明 body > 标识 monoSmall，
/// 电脑名封顶在 AX4（`nameCap`，系统 dynamicTypeSize 上限）：title3 涨得比 largeTitle 快，不封顶的话 AX5 会反超验证码。
/// 与 Android 的主次一致；两端字号差异登记在 tokens.json platforms.ios。
struct PairCodeView: View {
    let shown: PairCodeShown
    static let nameCap = DynamicTypeSize.accessibility4

    var body: some View {
        VStack(spacing: 10) {
            Text(L.s("pair_connecting_label")).font(PPFont.captionBold).foregroundStyle(PPColor.ink40)
            Text(shown.desktop.name).font(PPFont.title3).dynamicTypeSize(...Self.nameCap).foregroundStyle(PPColor.ink).multilineTextAlignment(.center)
                .accessibilityIdentifier("pairDesktopName")
            Text(PairCodeFormat.grouped(shown.code))
                .font(PPFont.pairCode).foregroundStyle(PPColor.ink)
                .minimumScaleFactor(0.6).lineLimit(1)
                .padding(.vertical, 12)
                .accessibilityLabel(shown.code.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("pairCodeValue")
            Text(L.s("pair_code_body")).font(PPFont.body).foregroundStyle(PPColor.ink60).lineSpacing(5).multilineTextAlignment(.center)
            Text(L.f("pair_desktop_identity", shown.desktop.fingerprint)).font(PPFont.monoSmall).foregroundStyle(PPColor.ink40)
                .padding(.top, 6)
                .accessibilityIdentifier("pairFingerprint")
        }
    }
}
