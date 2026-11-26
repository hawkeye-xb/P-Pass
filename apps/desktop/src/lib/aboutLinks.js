/**
 * #2065：桌面端「设置 → 关于」外链清单与打开封装（与 Android / iOS 四端对齐）。
 */
export function aboutLinks(locale = "en") {
  const isZh = String(locale).toLowerCase().startsWith("zh");
  const prefix = isZh
    ? "https://p-pass.hawkeye-xb.com/zh"
    : "https://p-pass.hawkeye-xb.com";
  return [
    {
      id: "website",
      labelKey: "ui.about_website",
      url: `${prefix}/`,
    },
    {
      id: "faq",
      labelKey: "ui.about_faq",
      url: `${prefix}/faq/`,
    },
    {
      id: "feedback-email",
      labelKey: "ui.about_feedback_email",
      value: "ppass@hawkeye-xb.com",
      url: "mailto:ppass@hawkeye-xb.com",
    },
    {
      id: "feedback-discussions",
      labelKey: "ui.about_feedback_discussions",
      value: "GitHub",
      url: "https://github.com/hawkeye-xb/P-Pass/discussions",
    },
    {
      id: "source",
      labelKey: "ui.about_source_code",
      valueKey: "ui.about_source_license",
      url: "https://github.com/hawkeye-xb/P-Pass",
    },
    {
      id: "privacy",
      labelKey: "ui.about_privacy",
      url: `${prefix}/privacy/`,
    },
  ];
}
