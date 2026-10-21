import AVFoundation
import PPassCore
import SwiftUI

/// 欢迎 → 扫码 / 手动输入配对串 → 配对状态（对位 Android Onboarding.kt + ScanScreen.kt + PairStatusScreen）。
/// 手动粘贴的配对串与二维码是**同一个字符串**，走同一条路（`AppModel` → PairingService.pair）。
/// 没有相机（模拟器）或没给相机权限时，扫码页直接说明并给出「手动输入」入口。
struct OnboardingFlow: View {
    enum Step: Equatable { case welcome, scan, manual, status(PairStep) }
    enum PairStep: Equatable { case waiting, refused(lapsed: Bool, note: String?), needsUpdate(OutdatedSide), failed(String) }

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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(PPColor.ink)
                    .accessibilityHidden(true)
                Text(L.s("welcome_headline")).font(PPFont.brand(40)).fixedSize(horizontal: false, vertical: true)
                Text(L.s("welcome_sub")).font(PPFont.body).foregroundStyle(PPColor.ink60)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(["welcome_step1", "welcome_step2", "welcome_step3"].enumerated()), id: \.offset) { i, key in
                        if i > 0 { PPDivider() }
                        Text(L.s(key)).font(PPFont.body).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .background(PPColor.linen, in: RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PPRadius.card, style: .continuous).stroke(PPColor.border, lineWidth: 1))
            }
            .padding(24)
        }
        .ppScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                PPButton(title: L.s("welcome_scan")) { step = .scan }
                Button(L.s("scan_manual_link")) { step = .manual }
                    .font(PPFont.bodyMedium)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(PPColor.paper.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { PPDivider() }
        }
    }

    private func submit(_ code: String) {
        step = .status(.waiting)
        pairTask = Task {
            let outcome = await app.backend.pairing.pair(code: code)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .joined(let firstTime): app.paired(firstTime: firstTime)
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
        case .manual: step = .manual
        case .pairWaiting: step = .status(.waiting)
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
                switch step {
                case .waiting:
                    ProgressView().controlSize(.large).padding(.bottom, 6)
                    message(title: L.s("pair_waiting_title"), body: L.s("pair_waiting_body"))
                case .refused(let lapsed, let note):
                    symbol("xmark.circle.fill", PPColor.act)
                    message(title: L.s(lapsed ? "pair_lapsed_title" : "pair_refused_title"), body: L.s("pair_refused_body"),
                            note: note)
                case .needsUpdate(let side):
                    // #1069：配对过程中发现版本不兼容——标题「需要更新」，正文说清是哪一端的 P-Pass。
                    symbol("arrow.down.circle.fill", PPColor.act)
                    message(title: L.s(side == .phone ? "update_needed_phone_title" : "update_needed_desktop_title"),
                            body: L.s(side == .phone ? "pair_needs_update_phone_body" : "pair_needs_update_desktop_body"))
                case .failed(let reason):
                    symbol("exclamationmark.triangle.fill", PPColor.act)
                    message(title: L.s("pair_failed_title"), body: L.s("pair_failed_body"),
                            note: "(\(String(reason.prefix(160))))")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .ppScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if case .waiting = step {
                    PPButton(title: L.s("cancel"), kind: .quiet, action: onCancel)
                } else {
                    PPButton(title: L.s("scan_again"), action: onRetry)
                }
            }
            .padding(24)
        }
    }

    private func symbol(_ name: String, _ tone: Color) -> some View {
        Image(systemName: name).font(.system(size: 56)).foregroundStyle(tone).accessibilityHidden(true)
    }

    private func message(title: String, body: String, note: String? = nil) -> some View {
        VStack(spacing: 10) {
            Text(title).font(PPFont.title2).multilineTextAlignment(.center)
            Text(body).font(PPFont.body).foregroundStyle(PPColor.ink60).multilineTextAlignment(.center)
            if let note { Text(note).font(PPFont.footnote).foregroundStyle(PPColor.ink40).multilineTextAlignment(.center) }
        }
    }
}
