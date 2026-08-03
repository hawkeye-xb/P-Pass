# Blocked by AV / SmartScreen — 被拦截了怎么办

> Where: Windows installs of P-Pass blocked by Defender / SmartScreen / third-party AV.
> Screenshot placeholders marked `[截图: …]` are filled by a human (H task) — this
> file is a doc skeleton, not a finished page.
> 定位：Windows 上安装 P-Pass 时被 Defender / SmartScreen / 杀软拦下的处理指引。
> 截图占位：`[截图: 位置]` 标记处由人类（H 任务）补图——本文件是文档骨架，不是成品。

---

## Official stance — read this first / 官方态度（先读这一段）

P-Pass is open source: source on GitHub, reproducible builds, and every
release artifact ships with **SHA-256 + SLSA attestation** (linked from the
release page). Being blocked by AV does not mean the software is bad — it
means the **signature has no reputation yet**, a stage every new software
goes through.

P-Pass 是开源软件：源码在 GitHub，构建可复现，每个发布产物都带
**SHA-256 + SLSA attestation**（下载页链接）。被杀软拦下 ≠ 软件有问题，
而是**新签名没有信誉**——所有新软件都会经历这个阶段。

### Verify in three steps — trust no one's word / 验证三步走（不用信任何人的话）

1. **Check the SHA-256** — the hash on the release page must equal the hash
   of the file you downloaded:
   对照 SHA-256：下载页给出的哈希，与本地文件算出的哈希一致：
   ```powershell
   # Windows — replace <file> with the artifact you downloaded (e.g. the .dmg/.zip/.exe)
   certutil -hashfile <file> SHA256
   ```
   ```bash
   # macOS / Linux
   shasum -a 256 <file>
   ```
2. **Verify the attestation** — the GitHub Release provenance proves this
   file was really built by P-Pass's official CI, not modified by anyone:
   查 attestation：GitHub Release 的 provenance 证明这个文件确实由
   P-Pass 官方 CI 构建，不是别人改过的：
   ```bash
   # Needs the GitHub CLI (https://cli.github.com); works on any OS.
   gh attestation verify <file> -R hawkeye-xb/P-Pass
   # Expected: "Verified signature from ..." / 期望输出包含 Verified
   ```
   No GitHub CLI? Download the `.attestation` file from the release assets
   and inspect it, or skip to step 3 — the source is public either way.
   没有 gh CLI？从 Release 资产下载 `.attestation` 文件人工查验，或直接跳到
   第 3 步——源码本来就是公开的。
3. **Source is inspectable** — the whole project is open source and the
   build pipeline lives in `.github/workflows/`; if you don't trust us,
   compile it yourself.
   源码可查：整个项目开源，构建流程在 `.github/workflows/` 里，
   不信任大可以自己编译。

> Found a real problem? Open an issue — every report is taken seriously.
> 如果你在我们的软件里真的发现了问题，欢迎提 issue——我们认真对待每一个报告。

---

## Scenario 1: SmartScreen "Windows protected your PC" / 场景一：SmartScreen 蓝屏提示

[截图: SmartScreen 蓝屏提示]

- **What happened**: the new software's signature reputation is not built
  yet (common early in a release; SmartScreen does this to every new
  publisher, even with a valid signature).
  发生了什么：新软件的签名信誉还没建立（发布初期常见，SmartScreen 对
  所有新发行商都这样，哪怕签名有效）。
- **What to do**: click 「More info / 更多信息」→ 「Run anyway / 仍要运行」.
  怎么办：点「更多信息」→「仍要运行」。
- **Why it's safe**: see the three-step verification above — once it passes,
  run with confidence.
  为什么安全：见上方"官方态度"三步验证——验证通过即可放心运行。

[截图: 点击"更多信息"后出现的"仍要运行"按钮]

---

## Scenario 2: Windows Defender deletes/quarantines / 场景二：Defender 直接删除/隔离

[截图: Defender 隔离通知]

- **What happened**: Defender's cloud scan quarantines files with no
  reputation first. Usually clears on its own within 24–72h as more users
  install and reputation builds.
  发生了什么：Defender 的云查杀对无信誉文件会先隔离。通常 24~72 小时
  内随着更多用户安装，信誉建立后自动消失。
- **What to do** / 怎么办：
  1. Windows Security → Protection history → find P-Pass → 「Restore / 还原」.
     Windows 安全中心 → 保护历史记录 → 找到 P-Pass → 「还原」。
  2. If it gets re-quarantined, add an exclusion:
     Windows Security → Virus & threat protection → Manage settings →
     Exclusions → Add a folder.
     还原后如果再次被隔离，把文件加入排除项：Windows 安全中心 →
     病毒和威胁防护 → 管理设置 → 排除项 → 添加文件夹。
  3. Long term: submit a false-positive report to Microsoft (usually
     processed in 1–2 business days).
     长期方案：向 Microsoft 提交误报申诉（提交后 1~2 个工作日处理）。
- **Help us**: if you confirm it's a false positive, send us Defender's
  「Detection name」 and a diagnostic bundle (「Export diagnostics」 in
  P-Pass settings) and we'll file the appeal centrally.
  请帮我们一个忙：如果确认是误报，把 Defender 的「检测名称」和
  诊断包（P-Pass 设置里「导出诊断包」）发给我们，我们统一提交申诉。

---

## Scenario 3: Third-party AV (360 / Huorong / Kaspersky / …) / 场景三：第三方杀软

[截图: 第三方杀软拦截弹窗（占位，品牌各不同）]

- **What happened**: each AV has its own reputation database, behaviour
  similar to Defender.
  发生了什么：各家杀软有自己的信誉库，行为与 Defender 类似。
- **What to do**: choose 「Trust / 信任 / Whitelist / 添加到白名单 /
  Allow / 允许」 in the popup, or add P-Pass's install folder to the
  AV's whitelist in its settings.
  怎么办：在弹窗里选择「信任 / 添加到白名单 / 允许」，或在杀软设置里
  把 P-Pass 的安装目录加入白名单。
- **Keeps getting blocked**: send us the AV name + detection name (issue or
  diagnostic bundle) and we'll file the false-positive appeal with that
  vendor.
  如果反复被拦：把杀软名称 + 检测名称发给我们（issue 或诊断包），
  我们会去对应厂商提交误报申诉。

---

## FAQ / 常见问题

**Q: "Publisher unknown" / 提示"发布者未知"？**
A: The executable's signature isn't recognized yet (early release). Trust it
once the SHA-256 matches; the prompt disappears once the formal signing
certificate lands (H-02 credentials).
说明可执行文件的签名信息还没被系统识别（发布早期）。验证 SHA-256
一致后即可信任；正式签名证书落地（H-02 凭据）后此提示消失。

**Q: Should I uninstall? / 我该卸载吗？**
A: Do the three-step verification first. If it passes, keep it; if the hash
does NOT match, uninstall immediately and tell us — the file you got is not
what we published.
先做"官方态度"里的三步验证。验证通过就不用；验证对不上（哈希不一致），
立刻卸载并告诉我们——那说明你拿到的文件不是我们发布的。

**Q: Why not sort this out before release? / 为什么不在发布前就把这些搞定？**
A: Reputation is built over time; no new software can skip it. What we can
do is make verification as transparent as possible — that's what this page
is for.
信誉是时间积累的，没有任何新软件能跳过。我们能做的是把"验证"这件事
做到最透明——这正是这个页面存在的意义。
