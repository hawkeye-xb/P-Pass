import AVFoundation
import SwiftUI

/// 欢迎 → 扫码 / 手动输入配对串 → 配对状态（对位 Android Onboarding.kt + ScanScreen.kt + PairStatusScreen）。
/// 手动粘贴的配对串与二维码是**同一个字符串**，走同一条路（`AppModel` → PairingService.pair）。
/// 没有相机（模拟器）或没给相机权限时，扫码页直接说明并给出「手动输入」入口。
struct OnboardingFlow: View {
    enum Step: Equatable { case welcome, scan, manual, status(PairStep) }
    enum PairStep: Equatable { case waiting, refused(lapsed: Bool, note: String?), failed(String) }

    @EnvironmentObject var app: AppModel
    @State private var step: Step = .welcome
    @State private var pairTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch step {
            case .welcome: welcome
            case .scan: ScanScreen(onCode: submit, onManual: { step = .manual }, onClose: { step = .welcome })
            case .manual: ManualPairScreen(onSubmit: submit, onBack: { step = .welcome })
            case .status(let s): PairStatusScreen(step: s, onCancel: cancel, onRetry: { step = .scan })
            }
        }
        .onAppear(perform: applyRoute)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text(L.s("welcome_headline")).font(PPFont.serif(PPSize.headlineMax))
            Text(L.s("welcome_sub")).font(PPFont.body).foregroundStyle(PPColor.ink60)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["welcome_step1", "welcome_step2", "welcome_step3"], id: \.self) {
                    Text(L.s($0)).font(PPFont.body)
                }
            }
            .padding(.vertical, 8)
            Spacer()
            PPButton(title: L.s("welcome_scan"), height: 60) { step = .scan }
            Button(L.s("scan_manual_link")) { step = .manual }
                .font(PPFont.sans(17, .medium)).foregroundStyle(PPColor.ink60)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(24)
        .ppScreen()
    }

    private func submit(_ code: String) {
        step = .status(.waiting)
        pairTask = Task {
            let outcome = await app.backend.pairing.pair(code: code)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .joined(let firstTime): app.paired(firstTime: firstTime)
            case .refused(let key, let ownerSaidNo):
                step = .status(.refused(lapsed: !ownerSaidNo, note: key.flatMap { DiagText.resolve($0) }))
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
        case .manual: step = .manual
        case .pairWaiting: step = .status(.waiting)
        case .pairRefused: step = .status(.refused(lapsed: false, note: nil))
        case .pairLapsed: step = .status(.refused(lapsed: true, note: DiagText.resolve("err.pair_expired")))
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
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onBack) { Label(L.s("back"), systemImage: "chevron.left").font(PPFont.sans(17, .medium)) }
                .frame(minHeight: 44)
            Text(L.s("scan_manual_title")).font(PPFont.serif(32))
            Text(L.s("scan_manual_body")).font(PPFont.body).foregroundStyle(PPColor.ink60)
            TextField(L.s("scan_manual_placeholder"), text: $text, axis: .vertical)
                .font(.system(size: 16, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(14)
                .background(PPColor.linen, in: RoundedRectangle(cornerRadius: PPRadius.control))
                .overlay(RoundedRectangle(cornerRadius: PPRadius.control).stroke(invalid ? PPColor.act : PPColor.borderStrong))
                .accessibilityIdentifier("pairCodeField")
            if invalid { Text(L.s("scan_manual_invalid")).font(PPFont.sans(15)).foregroundStyle(PPColor.act) }
            Text(L.s("scan_manual_note")).font(PPFont.sans(15)).foregroundStyle(PPColor.ink40)
            Spacer()
            HStack(spacing: 12) {
                PPButton(title: L.s("scan_manual_paste"), kind: .secondary) {
                    if let s = UIPasteboard.general.string { text = s }
                }
                PPButton(title: L.s("scan_manual_submit")) {
                    if let code = PairCode.normalized(text) { onSubmit(code) } else { invalid = true }
                }
                .accessibilityIdentifier("pairSubmit")
            }
        }
        .padding(24)
        .ppScreen()
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
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            switch step {
            case .waiting:
                ProgressView().tint(PPColor.ink60)
                Text(L.s("pair_waiting_title")).font(PPFont.serif(34))
                Text(L.s("pair_waiting_body")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                Spacer()
                PPButton(title: L.s("cancel"), kind: .secondary, action: onCancel)
            case .refused(let lapsed, let note):
                Text(L.s(lapsed ? "pair_lapsed_title" : "pair_refused_title")).font(PPFont.serif(34)).foregroundStyle(PPColor.act)
                Text(L.s("pair_refused_body")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                if let note { Text(note).font(PPFont.sans(15)).foregroundStyle(PPColor.ink40) }
                Spacer()
                PPButton(title: L.s("scan_again"), action: onRetry)
            case .failed(let reason):
                Text(L.s("pair_failed_title")).font(PPFont.serif(34)).foregroundStyle(PPColor.act)
                Text(L.s("pair_failed_body")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                Text("(\(String(reason.prefix(160))))").font(PPFont.sans(13)).foregroundStyle(PPColor.ink40)
                Spacer()
                PPButton(title: L.s("scan_again"), action: onRetry)
            }
        }
        .padding(24)
        .ppScreen()
    }
}
