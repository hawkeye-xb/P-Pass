/**
 * FAQ page copy — bilingual, same level (en served at /faq/, zh at /zh/faq/).
 *
 * Every answer here must stay traceable to something in this repo: the
 * privacy policy / terms pages, README, docs/product/*, or app copy
 * (apps/android/.../strings.xml, apps/desktop). If a claim can't be sourced,
 * it doesn't belong on this page — a family FAQ that oversells is worse than
 * no FAQ at all.
 *
 * Voice: spoken sentences, same as the landing copy and the "why photo backup
 * for family" post. No marketing superlatives. Two more rules, because this is
 * a page people scan and leave (#671):
 *   1. `a[0]` is the one-line answer. Detail goes in `a[1..]`; nobody has to
 *      read past the first line to get an answer.
 *   2. No em dashes (—— / " — "). They are the fingerprint of text translated
 *      out of English, and this page is read in Chinese first for most of our
 *      visitors.
 *
 * `id` is the permanent anchor of a question. It is part of the URL people
 * share, so rename the question freely but never rename an id.
 */

import type { Lang } from './ui';

export interface FaqLink {
  label: string;
  href: string;
}

export interface FaqItem {
  /** Anchor id, kebab-case English, stable — see the note above. */
  id: string;
  q: string;
  /** Paragraphs of the answer, in order. `a[0]` is the one-line answer. */
  a: string[];
  /** Optional "go deeper" links rendered after the paragraphs. */
  more?: FaqLink[];
}

export interface FaqGroup {
  /** Anchor id of the section heading. */
  id: string;
  title: string;
  items: FaqItem[];
}

export const FAQ_TITLE: Record<Lang, string> = {
  en: 'Questions families ask',
  zh: '家人会问的问题',
};

export const FAQ_LEDE: Record<Lang, string> = {
  en: "Every answer starts with the short version; most people only need two or three of them. If yours isn't here, open an issue on GitHub.",
  zh: '每条的第一句就是结论，想细看再往下。多数人只会用到其中两三条。这里没有的，到 GitHub 提 issue 问我们。',
};

export const FAQ_TOC_LABEL: Record<Lang, string> = {
  en: 'Jump straight to a question',
  zh: '直接跳到你要看的那条',
};

export const FAQ: Record<Lang, FaqGroup[]> = {
  en: [
    {
      id: 'before-install',
      title: 'Before you install',
      items: [
        {
          id: 'vs-cloud',
          q: 'How is this different from iCloud or Google Photos?',
          a: [
            'Those two keep your photos on their servers and charge you for the space. P-Pass keeps them on the computer in your home, and charges nothing.',
            'Day to day they do the same job: your photos get backed up without you touching anything. The difference is whose disk they land on and who can open it. That folder is yours, so you can look inside whenever you like.',
          ],
        },
        {
          id: 'devices',
          q: 'What do I need to run it?',
          a: [
            'A Mac with Apple silicon, and an Android phone on 8.0 or newer. Any Android brand will do.',
            'The iPhone app is not out yet, and the Windows desktop app is still in development. Neither has a download today.',
          ],
        },
        {
          id: 'setup',
          q: 'How long does setup take?',
          a: [
            'About ten minutes, and no technical knowledge.',
            'Install the Mac app and pick the folder your photos should live in. Install the phone app and scan the QR code shown on the computer screen. Tap "Allow" on the computer. There is nothing to keep doing after that.',
          ],
        },
        {
          id: 'free',
          q: 'Is it free?',
          a: [
            'Yes. No account, no subscription, and no cap other than the free space on your own disk.',
            'The code is open source under AGPL-3.0 on GitHub, so you can also build it yourself.',
          ],
        },
      ],
    },
    {
      id: 'day-to-day',
      title: 'Day to day',
      items: [
        {
          id: 'automatic',
          q: 'Does it back up on its own? Do I have to leave the app open?',
          a: [
            'It backs up on its own, with the app closed. The phone does it in the background while charging on Wi-Fi, screen off.',
            'Opening the app just nudges a catch-up run. While the computer is off, the photos simply stay on your phone; once it is back on and the two reconnect, the phone picks up what is still missing.',
          ],
        },
        {
          id: 'mobile-data',
          q: 'Will it quietly use my mobile data or drain my battery?',
          a: [
            'No. Backup is Wi-Fi-only out of the box, and mobile data is something you would have to turn on yourself.',
            'Transfers run only while there is something to send, and stop when there is not. One thing worth knowing: HarmonyOS, Samsung and some other systems stop background work to save power, so P-Pass has to be allowed in the battery settings. The app asks at the moment it matters, and stays quiet otherwise.',
          ],
        },
        {
          id: 'deletes-photos',
          q: 'Does backup delete or compress the photos on my phone?',
          a: [
            'Neither. What is on your phone stays exactly as it was.',
            'Backup only copies. Photos and videos are written into the folder you picked as the original files, uncompressed and unconverted, and they open straight from there.',
          ],
        },
        {
          id: 'which-albums',
          q: 'Which photos get backed up? Can I back up only some of them?',
          a: [
            'You pick the albums, and anything you leave unchecked is never read.',
            'The app asks right after pairing, for example whether to include the folder WeChat saves images into, and you can change the selection later.',
          ],
        },
        {
          id: 'family-visibility',
          q: 'Can my family see the photos on my phone?',
          a: [
            'Yes. Everyone paired to the same computer shares one library and can browse what the others have backed up.',
            'That is what "a family album that lives at home" means. Per-device visibility controls are not built yet.',
          ],
        },
      ],
    },
    {
      id: 'privacy',
      title: 'Privacy',
      items: [
        {
          id: 'servers',
          q: 'Do my photos go through your servers?',
          a: [
            'No. Photos travel only between your own phone and your own computer, and we run no servers that store them.',
            "When the two devices can't reach each other directly, the encrypted data is forwarded through a relay. Right now that is the relay and device-discovery services run by number 0, the maintainers of the open-source networking library iroh. Those services see your devices' IP addresses and public keys. They cannot see photo content, and they do not keep what they forward.",
          ],
          more: [{ label: 'Privacy Policy', href: '/privacy/' }],
        },
        {
          id: 'encryption',
          q: 'How is encryption done?',
          a: [
            'End to end. Photos leave the phone already encrypted and are decrypted on your own computer, so every hop in between only ever handles ciphertext.',
          ],
        },
        {
          id: 'usage-data',
          q: 'What can you see about how I use it?',
          a: [
            'This version reports no usage data and has no automatic crash reporting; the anonymous analytics in the code is off by default.',
            'We see something only if you export a diagnostic bundle and send it to us yourself, and exported bundles are scrubbed automatically. The website itself has no analytics scripts or cookies.',
          ],
          more: [{ label: 'Privacy Policy', href: '/privacy/' }],
        },
      ],
    },
    {
      id: 'troubleshooting',
      title: 'When something goes wrong',
      items: [
        {
          id: 'disk-dies',
          q: 'What happens if my computer or its disk dies?',
          a: [
            "Straight answer: the backup lands on the one computer you chose, and there is no automatic second copy yet. During the beta, keep another backup of the photos that matter.",
            'Nothing is locked up, though. The originals in the library are ordinary files: copy that folder to an external drive or another machine and you have a second copy, and the index can be rebuilt from the originals at any time.',
          ],
          more: [{ label: 'Terms of Use', href: '/terms/' }],
        },
        {
          id: 'how-do-i-know',
          q: 'How do I know a backup worked? What if it fails?',
          a: [
            'The phone home screen keeps one standing line: "Phone 1,234 · backed up 1,180 · waiting 54", plus the time of the last success.',
            'Success stays quiet. A failure notifies you, and tapping it shows which files and why. On the computer, "Family & devices" shows each phone\'s state, and "Activity" shows who backed up what and when.',
          ],
        },
        {
          id: 'new-phone',
          q: 'I got a new phone, or lost mine. How do I get the photos back?',
          a: [
            'The originals are on the computer and open straight from the folder.',
            'On a phone, photos in the library can be saved back to the gallery, shared, or opened in another app. A new phone just scans the pairing code again, and anything already backed up is not transferred twice.',
          ],
        },
        {
          id: 'install-blocked',
          q: 'Something went wrong. Where do I ask?',
          a: [
            'The most common first-run problem is the system blocking the installer: Gatekeeper on macOS, "unknown source" on Android. The steps to allow it are in the repository docs.',
            'Anything else: open an issue on GitHub and we will look.',
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
      id: 'before-install',
      title: '装之前',
      items: [
        {
          id: 'vs-cloud',
          q: '和 iCloud、Google 相册这类云相册有什么区别？',
          a: [
            '它们把照片存在自己的服务器上，按容量收月费；P-Pass 存在你家那台电脑上，不收钱。',
            '平时用起来是一样的：照片不用管，自己就备份好了。区别只在那份备份落在谁的硬盘上、谁能打开看。文件夹就在你电脑上，随时可以自己翻开。',
          ],
        },
        {
          id: 'devices',
          q: '需要什么设备？',
          a: [
            '一台 Apple 芯片的 Mac，加一台 Android 8.0 以上的手机。安卓不分牌子，华为、小米、三星都行。',
            'iPhone 版还没做出来，Windows 版还在开发中，这两个现在都没有下载。',
          ],
        },
        {
          id: 'setup',
          q: '装起来麻烦吗？',
          a: [
            '十分钟，不需要懂技术。',
            'Mac 上装好 App，跟着向导选一个存照片的文件夹；手机装上 App，扫一下电脑屏幕上的二维码；最后在电脑上点「允许」。之后就没什么要管的了。',
          ],
        },
        {
          id: 'free',
          q: '免费吗？',
          a: [
            '免费。不用注册，没有订阅，上限就是你那块硬盘还剩多少空间。',
            '代码以 AGPL-3.0 开源放在 GitHub 上，想自己编译也行。',
          ],
        },
      ],
    },
    {
      id: 'day-to-day',
      title: '平时怎么用',
      items: [
        {
          id: 'automatic',
          q: '手机会自己备份吗？要一直开着 App 吗？',
          a: [
            '会，App 不用开。插上电、连上 Wi-Fi 就在后台备份，熄屏也照跑。',
            '打开 App 只是顺手催一下还没传完的。电脑关着的时候，照片就留在手机里，什么都不影响；等电脑开机、两边重新连上，手机会接着上次的进度补。',
          ],
        },
        {
          id: 'mobile-data',
          q: '会不会偷偷用我的流量、耗我的电？',
          a: [
            '不会。默认只在 Wi-Fi 下备份，用流量得你自己去打开。',
            '备份只在有东西要传的时候跑，传完就停。另外鸿蒙、三星这些系统会为了省电掐掉后台任务，需要把 P-Pass 加进电池优化的白名单。App 会在该设置的时候提示你，平时不打扰。',
          ],
        },
        {
          id: 'deletes-photos',
          q: '备份会删掉或压缩手机上的照片吗？',
          a: [
            '都不会，手机上的照片原样不动。',
            '备份只做复制：照片和视频以原始文件写进你选的那个文件夹，不压缩、不转格式，在文件夹里直接就能打开。',
          ],
        },
        {
          id: 'which-albums',
          q: '备份哪些照片？能只备份一部分吗？',
          a: [
            '由你挑，没勾的相册不会被读。',
            '配对之后会让你选要备份哪些相册，比如微信保存图片的那个文件夹就可以不勾。以后想改随时能改。',
          ],
        },
        {
          id: 'family-visibility',
          q: '家人能看到我手机里的照片吗？',
          a: [
            '能。配到同一台电脑上的家人共用一个照片库，互相备份进来的照片都能看到。',
            '这就是「放在家里的家庭相册」的意思。想按设备单独设置谁能看、谁不能看，还没做。',
          ],
        },
      ],
    },
    {
      id: 'privacy',
      title: '隐私',
      items: [
        {
          id: 'servers',
          q: '我的照片会经过你们的服务器吗？',
          a: [
            '不会。照片只在你自己的手机和电脑之间走，我们没有存照片的服务器。',
            '两台设备直连不上时，加密后的数据会经一个中继转发。目前用的是开源网络库 iroh 的维护方 number 0 提供的中继和设备发现服务：它们能看到你设备的 IP 地址和公钥，看不到照片内容，也不保存转发过的数据。',
          ],
          more: [{ label: '隐私政策', href: '/zh/privacy/' }],
        },
        {
          id: 'encryption',
          q: '加密是怎么做的？',
          a: [
            '端到端。照片从手机出来就已经是密文，到你自己电脑上才解开，中间经过的每一环拿到的都只是密文。',
          ],
        },
        {
          id: 'usage-data',
          q: '你们能看到我用了什么、存了多少吗？',
          a: [
            '现在这个版本不上报任何使用数据，也没有自动崩溃上报，代码里的匿名统计默认是关的。',
            '只有你主动导出诊断包发给我们，我们才看得到内容，而且导出的时候已经自动脱敏。官网本身也没有统计脚本和 Cookie。',
          ],
          more: [{ label: '隐私政策', href: '/zh/privacy/' }],
        },
      ],
    },
    {
      id: 'troubleshooting',
      title: '出问题了',
      items: [
        {
          id: 'disk-dies',
          q: '电脑坏了、硬盘坏了怎么办？',
          a: [
            '说实话：现在只有你选的那一台电脑上有这份备份，第二份自动备份还没做。beta 期间，重要的照片请另外再留一份。',
            '好在东西不锁死。库里的原图就是普通文件，把整个文件夹拷到移动硬盘或另一台电脑就是第二份；索引丢了也能从原图重建。',
          ],
          more: [{ label: '使用条款', href: '/zh/terms/' }],
        },
        {
          id: 'how-do-i-know',
          q: '怎么知道备份成功了？失败了会怎样？',
          a: [
            '手机首页常驻一行「手机 1,234 张 · 已备份 1,180 · 待备份 54」，还有最后一次成功的时间。',
            '成功不打扰你；失败会通知，点进去能看到是哪几张、为什么。电脑端「家人与设备」里能看到每台手机的状态，「活动记录」里能看到谁在什么时候备份了什么。',
          ],
        },
        {
          id: 'new-phone',
          q: '换手机、手机丢了，照片怎么回来？',
          a: [
            '原件都在电脑上，打开文件夹就能用。',
            '手机端可以把库里的照片保存回相册、分享出去，或者用别的 App 打开。换新手机重新扫一次码配对就行，已经备份过的不会重传。',
          ],
        },
        {
          id: 'install-blocked',
          q: '出问题了去哪问？',
          a: [
            '最常见的是系统拦安装包：macOS 上叫 Gatekeeper，Android 上叫「未知来源」。放行步骤写在仓库文档里。',
            '其他问题到 GitHub 提 issue，我们会看。',
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
