# iOS TestFlight 外部测试：测试组、公开链接、Beta App Review（#940）

iOS 以 TestFlight 公开链接长期内测分发（不上架 App Store，见 #937）。本文是**在 App Store Connect 网页上要人工完成的步骤**
和要填的文字。构建上传走 CI（[RELEASING.md](../RELEASING.md) §4.2），90 天过期的提醒由
`.github/workflows/ios-testflight-expiry.yml` 每天检查，本文 §6 说明怎么处理提醒。

占位符约定：`<DEMO_VIDEO_URL>`（演示视频链接）、`<REVIEW_CONTACT_NAME>` / `<REVIEW_CONTACT_PHONE>` / `<REVIEW_CONTACT_EMAIL>`
（审核联系人）、`<FEEDBACK_EMAIL>`（测试反馈邮箱）、`<PRIVACY_POLICY_URL>`（隐私政策链接）、`<PUBLIC_LINK>`（TestFlight 公开链接）。
**仓库里不写任何个人联系方式**，这些值只在 App Store Connect 网页里填。

## 1. 前置条件

- App Store Connect 里已有 bundle id 为 `com.hawkeyexb.ppass` 的 App，且至少有一个状态为「可用」（VALID）的 build（#348 的上传流水线负责）。
- 账号角色至少 App Manager（建组、开公开链接、提交 Beta App Review 都需要）。
- 演示视频已录好并上传到可公开访问的地址（审核员无需登录即可看），得到 `<DEMO_VIDEO_URL>`。

## 2. 建外部测试组并开公开链接

以下全部在 [App Store Connect](https://appstoreconnect.apple.com) 网页操作；界面文案以 Apple 当前页面为准。

1. 「我的 App」→ 选 P-Pass → 顶部 **TestFlight** 标签。
2. 左侧栏 **外部测试**（External Testing）旁点 **+** → **新建群组**（New Group）。
3. 组名填 `P-Pass Public Beta`，点创建。
4. 进入该组，在 **构建版本**（Builds）区点 **+**，选要给外部测试用的 build（见 §3：首次需要先过 Beta App Review）。
5. 在 **公开链接**（Public Link）区点 **启用公开链接**（Enable Public Link）。
6. **测试员人数上限**（Tester Limit）：设为 `10000`，即外部测试允许的最大人数（以 [Apple 文档](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/) 为准；Apple 调整上限时同步改本文）。公开链接可以单独设更小的上限，满额后链接自动失效。
7. 不要给公开链接加额外的筛选条件，保持默认，让任何持有链接的人都能加入。
8. 复制页面上的公开链接（形如 `https://testflight.apple.com/join/…`），记为 `<PUBLIC_LINK>`，交给官网文案流程使用。
9. 之后每次上传新 build，进入该组 **构建版本** 把新 build 加进来（或在 TestFlight 总览里给该组启用「自动分发」，以页面实际选项为准），否则测试用户拿不到新版。

## 3. 首次 Beta App Review：要填的信息

外部测试的**第一个 build**（以及之后每个新的「版本号」train）需要 Apple 的 Beta App Review；同一版本号下之后的 build 通常不用重审。
在 TestFlight → **测试信息**（Test Information）里填，并在加 build 到外部组时提交审核：

| 项目 | 填什么 |
| --- | --- |
| Beta App 描述（Beta App Description） | §5 的 What to Test 之前先写一段 App 介绍：P-Pass 把手机照片自动备份到你自己家里的电脑，不用云存储、不用账号。 |
| 反馈邮箱（Feedback Email） | `<FEEDBACK_EMAIL>` |
| 营销网址 / 隐私政策网址 | 官网地址；隐私政策填 `<PRIVACY_POLICY_URL>`（外部测试要求提供） |
| 审核联系人（姓、名、电话、邮箱） | `<REVIEW_CONTACT_NAME>` / `<REVIEW_CONTACT_PHONE>` / `<REVIEW_CONTACT_EMAIL>` |
| 登录信息（Sign-in required） | **不勾选**：App 没有账号体系 |
| 审核备注（Review Notes） | §4 的草稿（中英都贴，英文在前） |
| What to Test（本版测试内容） | §5 |
| 出口合规 | Info.plist 已声明 `ITSAppUsesNonExemptEncryption=NO`（只用 TLS / QUIC 标准加密），无需每次作答 |

## 4. 审核说明草稿（Review Notes）

背景：P-Pass 必须和一台运行 P-Pass 的电脑配对后才能使用，审核员手里没有这台电脑。按 Apple 对「依赖外部硬件或服务的 App」的通行做法：
在审核备注里讲清楚依赖关系，并提供演示视频链接让审核员看到完整核心流程。联系信息只用占位符，提交时在网页里填真实值。

### English

```text
P-Pass backs up the photos on your iPhone to your own computer at home. There is no cloud service and no account.

IMPORTANT - this app needs a companion computer:
To use the app, the iPhone must be paired with a computer running the P-Pass desktop app (macOS). The reviewer does not have this computer, so we provide a demo video that shows the complete core flow on real devices:
<DEMO_VIDEO_URL>

Core flow shown in the video:
1. The desktop app shows a pairing QR code.
2. On the iPhone, open P-Pass and tap Pair. Allow Camera access (used only to scan this QR code) and Local Network access (used to reach the paired computer).
3. After scanning, the phone and the computer are paired. No sign-in is needed.
4. Allow Photos access. The app starts backing up the photo library to the computer. Progress and the "backed up" count are shown on the Home screen.
5. Photos already on the computer can be browsed on the phone, and a photo can be saved back to the phone.

Without a paired computer the app opens normally and shows the pairing screen; the camera is requested only when the user taps Pair.

Permissions: Camera (scan the pairing QR code), Local Network (talk to the paired computer), Photos (read the library to back it up; add to save a photo back).
Encryption: standard TLS/QUIC transport only (ITSAppUsesNonExemptEncryption = NO).
No account, no sign-in, no in-app purchase, no third-party analytics or advertising.

Contact for any question during review: <REVIEW_CONTACT_NAME>, <REVIEW_CONTACT_EMAIL>, <REVIEW_CONTACT_PHONE>
```

### 中文

```text
P-Pass 把 iPhone 里的照片自动备份到你家里自己的电脑，没有云服务，也没有账号。

重要：本 App 需要配对一台电脑才能使用。
使用前，iPhone 必须与一台运行 P-Pass 桌面版（macOS）的电脑配对。审核员手里没有这台电脑，所以我们提供了真机演示视频，完整展示核心流程：
<DEMO_VIDEO_URL>

视频里展示的核心流程：
1. 桌面版显示配对二维码。
2. 在 iPhone 上打开 P-Pass，点「配对」。允许相机权限（只用来扫这个二维码）和本地网络权限（用来连接已配对的电脑）。
3. 扫码后手机与电脑完成配对，全程无需登录。
4. 允许照片权限，App 开始把相册备份到电脑，首页显示进度和「已备份」数量。
5. 电脑上已有的照片可以在手机上浏览，也可以把某张照片存回手机。

没有配对电脑时，App 可正常打开并停在配对页；只有点「配对」时才会请求相机。

权限说明：相机（扫配对二维码）、本地网络（与已配对电脑通信）、照片（读取相册做备份；写入用于把照片存回手机）。
加密：只用标准 TLS / QUIC 传输加密（ITSAppUsesNonExemptEncryption = NO）。
无账号、无登录、无内购、无第三方统计与广告。

审核期间如有疑问请联系：<REVIEW_CONTACT_NAME>，<REVIEW_CONTACT_EMAIL>，<REVIEW_CONTACT_PHONE>
```

演示视频要求：真机录屏，一镜到底覆盖上面 1-5 步；不出现个人照片、真实姓名、家庭网络名等隐私内容；链接无需登录即可播放，且在审核期内持续有效。

## 5. 测试信息（What to Test）

填在每个 build 的 What to Test（上限 4000 字符），中英并列。每个版本可以改成本次重点。

```text
[English]
Thanks for testing P-Pass. It backs up your iPhone photos to your own computer at home - no cloud, no account.
You need the P-Pass desktop app (macOS) running on a computer on the same network to try it.
Please try:
1. Pair the phone with your computer by scanning the QR code shown in the desktop app.
2. Let the backup run; check that the progress and "backed up" count on the Home screen look right.
3. Browse photos that are on the computer, and save one back to the phone.
4. Close the app, reopen it, and check that it reconnects and resumes.
Please report anything odd (crashes, stuck progress, wrong counts, confusing text) to <FEEDBACK_EMAIL>, or use the TestFlight feedback option (screenshot + share).

[中文]
感谢测试 P-Pass。它把 iPhone 照片自动备份到你家里自己的电脑，没有云、没有账号。
试用需要一台在同一网络里运行 P-Pass 桌面版（macOS）的电脑。
请重点试：
1. 扫描桌面版显示的二维码，把手机与电脑配对。
2. 让备份跑起来，看首页的进度和「已备份」数量是否正确。
3. 浏览电脑上的照片，并把其中一张存回手机。
4. 退出 App 再打开，看是否能自动重连并继续。
遇到任何异常（闪退、进度卡住、数量不对、文案看不懂）请发到 <FEEDBACK_EMAIL>，或用 TestFlight 自带的反馈（截图后分享）。
```

## 6. 90 天过期与定时提醒

- TestFlight 构建自上传起 90 天过期，过期后外部测试用户打不开 App。
- `.github/workflows/ios-testflight-expiry.yml` 每天（UTC 02:17）查最新 VALID build 的上传时间；超过 75 天没有新 build 就开一个标题为「[IOS] TestFlight 构建临近过期，需要重新上传」的 issue（已有同标题未关闭 issue 则不重复开）。只提醒，不自动上传。没有 ASC secrets 时 workflow 跳过并在 summary 标注。
- 收到提醒后：
  1. 选一个未占用的测试版本号 `vX.Y.Z-test.N`（或 `-beta.N`），运行 `gh workflow run ci-ios.yml --ref <分支> -f testflight_version=vX.Y.Z-test.N`。
  2. job 成功后在 App Store Connect → TestFlight 确认新 build 为可用，并在外部测试组「构建版本」里加上新 build。新的版本号 train 可能需要重新过 Beta App Review（§3）。
  3. 关闭提醒 issue。

## 7. 用户侧安装说明（中英，供官网文案流程取用）

### 中文

1. 在 iPhone 上从 App Store 安装 **TestFlight**（苹果官方 App）。
2. 在 iPhone 上打开公开链接 `<PUBLIC_LINK>`，点「接受」，再点「安装」。
3. 在 TestFlight 里点 P-Pass，打开「**自动更新**」开关（App 页的「自动更新」），之后新版本会自动装好。
4. 还需要在电脑上装 P-Pass 桌面版，并按 App 里的提示扫码配对。

关于 90 天：TestFlight 的每个测试版本自上传起 90 天过期，过期后 App 打不开。我们会在过期前持续上传新版本；你开启了自动更新，就会在新版本发布后自动换上，不会碰到过期。如果长期没打开 TestFlight、新版本没来得及更新，打开 TestFlight 点「更新」即可。

### English

1. Install **TestFlight** (Apple's own app) from the App Store on your iPhone.
2. Open the public link `<PUBLIC_LINK>` on your iPhone, tap Accept, then Install.
3. In TestFlight, open P-Pass and turn on **Automatic Updates**, so new builds install by themselves.
4. You also need the P-Pass desktop app on your computer; follow the in-app steps to scan the QR code and pair.

About the 90 days: every TestFlight build expires 90 days after it is uploaded, and an expired build will not open. We keep uploading new builds before the old one expires; with Automatic Updates on, the new build replaces the old one without you doing anything. If you have not opened TestFlight for a long time and an update is pending, open TestFlight and tap Update.

## 8. 必须由人在网页上完成的事

- 创建外部测试组、启用公开链接、设置人数上限（§2）。
- 填写测试信息与审核备注、提交首次 Beta App Review，并等待 Apple 审核结果（§3、§4）。
- 录制并托管演示视频，得到 `<DEMO_VIDEO_URL>`。
- 之后每个新版本号 train 若被要求重审，同样在网页提交。
