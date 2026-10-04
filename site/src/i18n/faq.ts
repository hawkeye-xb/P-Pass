/**
 * FAQ page copy — bilingual, same level (en served at /faq/, zh at /zh/faq/).
 *
 * Every answer here must stay traceable to something in this repo: the
 * privacy policy / terms pages, README, docs/product/*, or app copy
 * (apps/android/.../strings.xml, apps/desktop). If a claim can't be sourced,
 * it doesn't belong on this page — a family FAQ that oversells is worse than
 * no FAQ at all.
 *
 * Tone: plain spoken sentences, same voice as the landing copy and the
 * "why photo backup for family" post. No marketing superlatives.
 */

import type { Lang } from './ui';

export interface FaqLink {
  label: string;
  href: string;
}

export interface FaqItem {
  q: string;
  /** Paragraphs of the answer, in order. */
  a: string[];
  /** Optional "go deeper" links rendered after the paragraphs. */
  more?: FaqLink[];
}

export interface FaqGroup {
  title: string;
  items: FaqItem[];
}

export const FAQ_TITLE: Record<Lang, string> = {
  en: 'Questions families ask',
  zh: '家人会问的问题',
};

export const FAQ_LEDE: Record<Lang, string> = {
  en: "The short answers to what people ask before, and after, they set P-Pass up. If yours isn't here, open an issue on GitHub.",
  zh: '装之前、装之后，大家最常问的那些事。这里没有的，到 GitHub 提 issue 问我们。',
};

export const FAQ: Record<Lang, FaqGroup[]> = {
  en: [
    {
      title: 'Getting started',
      items: [
        {
          q: 'How is this different from iCloud or Google Photos?',
          a: [
            'Your photos travel from your phone straight to the computer at home — no account, no cloud storage, no storage subscription. The copy lives on a disk you already own, so the only limit is that disk.',
            'As photo backup, the promise is the same one you expect from any of them: it keeps a second copy, automatically. What differs is where that copy sits, and who can see it.',
          ],
        },
        {
          q: 'What do I need to run it?',
          a: [
            'Computer: a Mac with Apple silicon. Phone: Android 8.0 or newer.',
            'The iPhone app is not out yet — iOS restricts background work differently, so it gets built and explained on its own rather than shipped as a worse Android clone. The Windows desktop app is in development and not published yet.',
          ],
        },
        {
          q: 'How long does setup take?',
          a: [
            'About ten minutes, and no technical knowledge: install the Mac app, pick the folder where your photos should live, install the phone app, scan the QR code on the computer screen, and tap "Allow" on the computer. After that there is nothing to keep doing.',
          ],
        },
        {
          q: 'Is it free?',
          a: [
            'Yes — backing up at home is free, with no account, no subscription and no storage cap beyond your own disk. The code is open source under AGPL-3.0 on GitHub, so you can also build it yourself.',
          ],
        },
      ],
    },
    {
      title: 'How backup works',
      items: [
        {
          q: 'Does it back up on its own? Do I have to leave the app open?',
          a: [
            "No. The phone backs up in the background when it's charging and connected to Wi-Fi, even with the screen off; opening the app just nudges a catch-up run.",
            'While the computer is off, the photos simply stay on your phone, unchanged. Once it is on again and the two devices reconnect, the phone continues with whatever is still missing.',
          ],
        },
        {
          q: 'Will it quietly use my mobile data or drain my battery?',
          a: [
            'Backup is Wi-Fi-only by default, and the setting can be turned off if you want it to use mobile data. Transfers run only while there is something to send, and stop when there is not.',
            'One thing worth knowing: HarmonyOS, Samsung and some other systems stop background work to save power. P-Pass needs to be allowed in the system battery settings — the app walks you through it at the moment it matters, and stays quiet otherwise.',
          ],
        },
        {
          q: 'Does backup delete or compress the photos on my phone?',
          a: [
            'Neither. Backup copies: photos and videos are stored as the original files on your computer, uncompressed and unconverted, and open straight from the folder. What is on your phone stays exactly as it was.',
          ],
        },
        {
          q: 'Which photos get backed up? Can I back up only some of them?',
          a: [
            'You choose. After pairing, P-Pass asks which albums to include; anything you leave unchecked is never read (WeChat images, for example). You can change the selection at any time.',
          ],
        },
        {
          q: 'Can my family see the photos on my phone?',
          a: [
            'Yes. Everyone paired to the same computer shares one family library and can browse what the others have backed up — that is what "a family album that lives at home" means. Per-device visibility controls are not built yet.',
          ],
        },
      ],
    },
    {
      title: 'Privacy & security',
      items: [
        {
          q: 'Do my photos go through your servers?',
          a: [
            'No. Photos and videos only travel between your own phone and your own computer. We run no servers that store user photos, and we have no way to see them.',
            "When the two devices can't reach each other directly, the encrypted data is forwarded through a relay — currently the relay and device-discovery services operated by number 0, the maintainers of the open-source networking library iroh. Those services see your devices' IP addresses and public keys; they can't see photo content, and they don't store the data they forward.",
          ],
          more: [{ label: 'Privacy Policy', href: '/privacy/' }],
        },
        {
          q: 'How is encryption done?',
          a: [
            'End to end. Photos leave the phone already encrypted and are decrypted on your own computer, so every hop in between only ever handles ciphertext.',
          ],
        },
        {
          q: 'What can you see about how I use it?',
          a: [
            'This version reports no usage data and has no automatic crash reporting; the anonymous analytics in the code is off by default. We only see a diagnostic bundle if you export one and send it to us yourself, and exported bundles are scrubbed automatically. The website itself has no analytics scripts or cookies.',
          ],
          more: [{ label: 'Privacy Policy', href: '/privacy/' }],
        },
      ],
    },
    {
      title: 'Your data & recovery',
      items: [
        {
          q: 'What happens if my computer or its disk dies?',
          a: [
            "Honestly: today the backup lands on the one computer you chose, with no automatic second copy — backing up to a second computer is not built yet. So during the beta, keep at least one other backup of photos that matter.",
            "Nothing is locked up, though. The originals in the library are ordinary files: copying that folder to an external drive or another machine is a second copy, and the index can be rebuilt from the originals at any time.",
          ],
          more: [{ label: 'Terms of Use', href: '/terms/' }],
        },
        {
          q: 'How do I know a backup worked? What if it fails?',
          a: [
            'The phone home screen keeps a standing line — "Phone 1,234 · backed up 1,180 · waiting 54" — plus the time of the last successful backup. Success stays quiet; a failure notifies you, and tapping it shows which files and why.',
            'On the computer, "Family & devices" shows each phone\'s state, and "Activity" shows who backed up what and when.',
          ],
        },
        {
          q: 'I got a new phone, or lost mine. How do I get the photos back?',
          a: [
            'The originals are on the computer and open straight from the folder. On a phone, photos in the library can be saved to the system gallery, shared, or opened in another app. A new phone just scans the pairing code again — anything already backed up is not transferred twice.',
          ],
        },
      ],
    },
    {
      title: 'Troubleshooting',
      items: [
        {
          q: 'Something went wrong. Where do I ask?',
          a: [
            'The most common first-run issue is the operating system blocking the app (Gatekeeper on macOS, "unknown source" installs on Android). The exact steps are in the repository docs. Anything else: open an issue on GitHub and we will look.',
          ],
          more: [
            {
              label: 'Blocked by a security prompt',
              href: 'https://github.com/hawkeye-xb/P-Pass/blob/main/docs/troubleshooting/blocked-by-av.md',
            },
            { label: 'GitHub Issues', href: 'https://github.com/hawkeye-xb/P-Pass/issues' },
          ],
        },
      ],
    },
  ],

  zh: [
    {
      title: '上手',
      items: [
        {
          q: '和 iCloud、Google 相册这类云相册有什么区别？',
          a: [
            '照片从你手机直接走到家里那台电脑的硬盘上——不注册账号，不上传云端，也没有容量订阅。存多少，取决于你自己那块硬盘。',
            '作为备份工具，它给的承诺和那些产品一样：自动帮你留一份。区别只在那一份放在哪、谁能看见。',
          ],
        },
        {
          q: '需要什么设备？',
          a: [
            '电脑端目前是 Apple 芯片的 Mac；手机端是 Android 8.0 及以上。',
            'iPhone 版还没出——iOS 对后台任务的限制不一样，会单独做、单独说清楚，而不是拿 Android 版硬顶一个更差的体验。Windows 桌面版还在开发中，暂时没有发布。',
          ],
        },
        {
          q: '装起来麻烦吗？',
          a: [
            '不需要技术背景，十分钟左右：Mac 上装好 App，跟着向导选一个存放照片的文件夹；手机装上 App，扫电脑屏幕上的二维码；电脑上点一下「允许」。之后就没什么要管的了。',
          ],
        },
        {
          q: '免费吗？',
          a: [
            '免费。家里两端的备份不收钱，没有账号、没有订阅，也没有容量上限（上限就是你自己的硬盘）。代码以 AGPL-3.0 开源放在 GitHub 上，也可以自己编译。',
          ],
        },
      ],
    },
    {
      title: '备份是怎么发生的',
      items: [
        {
          q: '手机会自己备份吗？要一直开着 App 吗？',
          a: [
            '不用开 App。手机插着电、连着 Wi-Fi 时在后台自动备份，熄屏也照跑；打开 App 只是顺带补跑一次。',
            '电脑关机期间，照片原样留在手机里，什么都不影响。等电脑开机、两端重新连上，手机会接着把还没传完的补上。',
          ],
        },
        {
          q: '会不会偷偷用我的流量、耗我的电？',
          a: [
            '默认只在「仅 Wi-Fi 时备份」，想用流量可以在设置里关掉这项。备份只在有东西要传的时候跑，传完就停。',
            '有一点要提醒：鸿蒙、三星这些系统会为了省电掐掉后台任务，需要把 P-Pass 加进系统的电池优化白名单——App 会在该处理的时候引导你，平时不打扰。',
          ],
        },
        {
          q: '备份会删掉或压缩手机上的照片吗？',
          a: [
            '都不会。备份是复制：照片和视频以原始文件存在电脑上，不压缩、不转格式，在你选的文件夹里直接就能打开。手机上的照片原样不动。',
          ],
        },
        {
          q: '备份哪些照片？能只备份一部分吗？',
          a: [
            '由你选。配对之后会让你挑要备份的相册，没勾的相册不会被读（比如微信收到的图片）。之后随时能改。',
          ],
        },
        {
          q: '家人能看到我手机里的照片吗？',
          a: [
            '会。配到同一台电脑上的家人共享同一个照片库，彼此备份进来的照片都能看到——这就是「放在家里的家庭相册」的意思。按设备单独设置可见性还没有做。',
          ],
        },
      ],
    },
    {
      title: '隐私与安全',
      items: [
        {
          q: '我的照片会经过你们的服务器吗？',
          a: [
            '不会。照片和视频只在你自己的手机和电脑之间传，我们没有存放用户照片的服务器，也看不到里面是什么。',
            '两台设备直连不上时，加密后的数据会经一个中继转发——目前用的是开源网络库 iroh 的维护方 number 0 运营的中继与设备发现服务。这些服务能看到你设备的 IP 地址和公钥，看不到照片内容，也不保存转发过的数据。',
          ],
          more: [{ label: '隐私政策', href: '/zh/privacy/' }],
        },
        {
          q: '加密是怎么做的？',
          a: [
            '端到端加密：照片从手机出来就已经是密文，到你自己的电脑上才解开。中间经过的每一环，拿到的都只是密文。',
          ],
        },
        {
          q: '你们能看到我用了什么、存了多少吗？',
          a: [
            '当前版本不上报任何使用数据，也没有自动崩溃上报；代码里的匿名统计默认关闭。只有你主动导出诊断包并发给我们，我们才会看到里面已经脱敏的内容。官网本身也没有统计脚本和 Cookie。',
          ],
          more: [{ label: '隐私政策', href: '/zh/privacy/' }],
        },
      ],
    },
    {
      title: '数据安全与找回',
      items: [
        {
          q: '电脑坏了、硬盘坏了怎么办？',
          a: [
            '说实话：现在备份只落在你选的那一台电脑上，没有第二份自动冗余——备份到第二台电脑还没做。所以 beta 期间，重要的照片建议再留一份别的备份。',
            '好在东西不锁死。库里的原图就是普通文件，把整个文件夹拷到移动硬盘或另一台设备就是第二份；索引即使丢了，也能从原图重建。',
          ],
          more: [{ label: '使用条款', href: '/zh/terms/' }],
        },
        {
          q: '怎么知道备份成功了？失败了会怎样？',
          a: [
            '手机首页常驻一行「手机 1,234 张 · 已备份 1,180 · 待备份 54」和最后一次成功时间。成功不打扰你；失败会通知，点进去能看到是哪几张、为什么。',
            '电脑端「家人与设备」能看到每台手机的状态，「活动记录」里能看到谁在什么时候备份了什么。',
          ],
        },
        {
          q: '换手机、手机丢了，照片怎么回来？',
          a: [
            '原件在电脑上，直接打开文件夹就能用。手机端可以把库里的照片「保存到相册」、分享出去，或用其他 App 打开。换新手机重新扫一次码配对就行，已经备份过的不会重传。',
          ],
        },
      ],
    },
    {
      title: '遇到问题',
      items: [
        {
          q: '出问题了去哪问？',
          a: [
            '最常见的是系统拦安装包（macOS 的 Gatekeeper、Android 的「未知来源」）。具体步骤写在仓库文档里。其他问题到 GitHub 提 issue，我们会看。',
          ],
          more: [
            {
              label: '被安全弹窗拦住怎么办',
              href: 'https://github.com/hawkeye-xb/P-Pass/blob/main/docs/troubleshooting/blocked-by-av.md',
            },
            { label: 'GitHub Issues', href: 'https://github.com/hawkeye-xb/P-Pass/issues' },
          ],
        },
      ],
    },
  ],
};
