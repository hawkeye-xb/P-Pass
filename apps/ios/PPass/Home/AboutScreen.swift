import SwiftUI

struct AboutLinkItem: Identifiable, Equatable {
    let id: String
    let labelKey: String
    let value: String?
    let url: URL
}

enum AboutLinks {
    static func isChinese(preferredLanguages: [String] = Locale.preferredLanguages) -> Bool {
        guard let first = preferredLanguages.first?.lowercased() else { return false }
        return first.hasPrefix("zh")
    }

    static func items(
        preferredLanguages: [String] = Locale.preferredLanguages,
        bundle: Bundle = .main
    ) -> [AboutLinkItem] {
        items(isChinese: isChinese(preferredLanguages: preferredLanguages), bundle: bundle)
    }

    static func items(isChinese: Bool, bundle: Bundle = .main) -> [AboutLinkItem] {
        let prefix = isChinese ? "https://p-pass.hawkeye-xb.com/zh" : "https://p-pass.hawkeye-xb.com"
        return [
            AboutLinkItem(
                id: "website",
                labelKey: "about_website",
                value: nil,
                url: URL(string: "\(prefix)/")!
            ),
            AboutLinkItem(
                id: "faq",
                labelKey: "about_faq",
                value: nil,
                url: URL(string: "\(prefix)/faq/")!
            ),
            AboutLinkItem(
                id: "feedback_email",
                labelKey: "about_feedback_email",
                value: "ppass@hawkeye-xb.com",
                url: URL(string: "mailto:ppass@hawkeye-xb.com")!
            ),
            AboutLinkItem(
                id: "feedback_discussions",
                labelKey: "about_feedback_discussions",
                value: "GitHub",
                url: URL(string: "https://github.com/hawkeye-xb/P-Pass/discussions")!
            ),
            AboutLinkItem(
                id: "source",
                labelKey: "about_source_code",
                value: L.s("about_source_license", bundle: bundle),
                url: URL(string: "https://github.com/hawkeye-xb/P-Pass")!
            ),
            AboutLinkItem(
                id: "privacy",
                labelKey: "about_privacy",
                value: nil,
                url: URL(string: "\(prefix)/privacy/")!
            ),
        ]
    }
}

struct AboutScreen: View {
    @Environment(\.openURL) private var openURL
    let bundle: Bundle
    let preferredLanguages: [String]?
    let versionLine: String

    init(
        bundle: Bundle = .main,
        preferredLanguages: [String]? = nil,
        versionLine: String = AppVersion.current.displayLine
    ) {
        self.bundle = bundle
        self.preferredLanguages = preferredLanguages
        self.versionLine = versionLine
    }

    private var links: [AboutLinkItem] {
        let langs = preferredLanguages ?? (
            bundle.preferredLocalizations.isEmpty
                ? Locale.preferredLanguages
                : bundle.preferredLocalizations
        )
        return AboutLinks.items(preferredLanguages: langs, bundle: bundle)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image("LaunchLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: PPRadius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: PPRadius.control, style: .continuous)
                                .strokeBorder(PPColor.border, lineWidth: 1)
                        )
                        .accessibilityHidden(true)
                    Text(verbatim: "P-Pass")
                        .font(PPFont.title3)
                        .foregroundStyle(PPColor.ink)
                        .accessibilityIdentifier("aboutAppName")
                    Text(versionLine)
                        .font(PPFont.sans(PPUI.TextSize.rowValue, relativeTo: .subheadline))
                        .foregroundStyle(PPColor.ink40)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("aboutVersion")
                    Text(L.s("about_tagline", bundle: bundle))
                        .font(PPFont.body)
                        .foregroundStyle(PPColor.ink60)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("aboutTagline")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .ppTinted(PPUI.Surface.settingsCard)

            Section {
                ForEach(links) { item in
                    Button {
                        AppLog.log("about: open url=\(item.url.absoluteString)")
                        openURL(item.url)
                    } label: {
                        LabeledContent {
                            HStack(spacing: 6) {
                                if let value = item.value {
                                    Text(value)
                                        .font(PPFont.sans(PPUI.TextSize.rowValue, relativeTo: .subheadline))
                                        .foregroundStyle(PPColor.ink40)
                                        .multilineTextAlignment(.trailing)
                                }
                                Image(systemName: "arrow.up.right")
                                    .font(PPFont.iconBadge)
                                    .foregroundStyle(PPColor.ink40)
                                    .accessibilityHidden(true)
                            }
                        } label: {
                            Text(L.s(item.labelKey, bundle: bundle))
                                .font(PPFont.sans(PPUI.TextSize.rowLabel))
                                .foregroundStyle(PPColor.ink)
                        }
                        .frame(minHeight: PPUI.Layout.rowMinHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("aboutLink_\(item.id)")
                }
            }
            .ppTinted(PPUI.Surface.settingsCard)
        }
        .listStyle(.insetGrouped)
        .ppList()
        .ppCardSpacing()
        .ppNavBar()
        .navigationTitle(L.s("about_label", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
    }
}
