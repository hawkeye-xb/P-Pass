/**
 * FAQ page copy — bilingual, same level (en served at /faq/, zh at /zh/faq/).
 *
 * Every answer here must stay traceable to something in this repo: the
 * privacy policy / terms pages, README, docs/product/*, or app copy. If a claim
 * can't be sourced, it doesn't belong on this page.
 *
 * Two of the five groups exist to explain what the app already says to people
 * (#671 review): the permission prompts, and the notices the phone shows when
 * it cannot back up. Those answers quote the string that is actually on screen.
 * Sources, per item:
 *   photo-permission-all  apps/android/.../values-zh/strings.xml: partial_access_body,
 *                         notif_media_partial_body, bucket_hint
 *   app-permissions       apps/android/app/src/main/AndroidManifest.xml
 *   waiting-conditions    state_waiting_battery, dog_battery_body
 *   pairing-lost          pairing_lost_body, notif_pairing_lost_body
 *   what-notifications    SystemFailureNotifier.kt (three definitive events), rule_notify_hint,
 *                       notif_transfer_title
 *   disk-full             state_waiting_desktop_full, desktop_low_space_hint
 * A new notice in the app is a candidate for a new entry here. The reverse is
 * not true: do not invent a notice the app never shows.
 *
 * Ordering (#671 review): FAQ_TOP lists the four that decide whether someone
 * installs at all — cost, where the photos go, the one permission that blocks
 * backups if it is answered wrong, and device support. They render as a short
 * "start here" list above the groups, so nobody has to read a category to find
 * them. The groups below are cut by task, not by feature: 费用与隐私 /
 * 安装与配对 / 备份与同步 / 照片与数据 / 状态、提示与故障.
 *
 * Tone (#671 review): neither chatty nor corporate. Category titles are plain
 * noun phrases, not "出事了" and not "常见问题解答之安装篇". Questions read the
 * way a person asks them; answers keep 你/你的 rather than 您, and avoid both
 * 「说实话」 and 「综上所述」.
 *
 * Two more rules, learned the hard way:
 *   1. `a[0]` is the answer. Detail, when there is any, goes after it. Some
 *      answers are one paragraph — do not pad them to match the others. A page
 *      where every answer has the same two-paragraph shape reads as generated,
 *      whatever the words say.
 *   2. No sentence that only thanks the reader, confesses honesty, or explains
 *      how the page is laid out.
 *
 * `id` is the permanent anchor of a question. It is part of the URL people
 * share, so rename the question freely but never rename an id. Nobody links to
 * these yet; the landing page and README should.
 */

import { TESTFLIGHT_URL } from '../consts';
import type { Lang } from './ui';

export interface FaqLink {
  label: string;
  href: string;
}

/** A block is a paragraph, or a list when the answer really is a list. */
export type FaqBlock = string | { list: string[] };

export interface FaqItem {
  /** Anchor id, kebab-case English, stable — see the note above. */
  id: string;
  q: string;
  /** Blocks of the answer, in order. `a[0]` is a paragraph and answers the question. */
  a: FaqBlock[];
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
  zh: '常见问题',
};

export const FAQ_LEDE: Record<Lang, string> = {
  en: 'The four asked most often, then the rest grouped by task.',
  zh: '四条最常被问到的，其余按用途分组。',
};

/** Search-result snippet for the FAQ page; the on-page lede above is too terse for that. */
export const FAQ_DESCRIPTION: Record<Lang, string> = {
  en: 'Answers to common questions about P-Pass: where your photos are stored, which phones and computers are supported, what permissions it needs, whether the computer has to stay on, and what happens if you change phones or the disk fails.',
  zh: 'P-Pass 常见问题：照片存在哪里、支持哪些手机和电脑、需要哪些权限、电脑要不要一直开着、换手机或硬盘坏了怎么办。',
};

export const FAQ_TOP_LABEL: Record<Lang, string> = {
  en: 'Start here',
  zh: '先看这几条',
};

/** Items rendered as the "start here" list, by id. Order matters. */
export const FAQ_TOP: string[] = ['cost', 'where-photos-go', 'photo-permission-all', 'supported-devices'];

export const FAQ_NAV_LABEL: Record<Lang, string> = {
  en: 'Sections',
  zh: '分类导航',
};

export const FAQ: Record<Lang, FaqGroup[]> = {
  en: [
    {
      id: 'cost-privacy',
      title: 'Cost and privacy',
      items: [
        {
          id: 'cost',
          q: 'Does it cost anything?',
          a: [
            'Open source, and you can host it yourself.',
            'Your photos sit on your own computer, so the only limit is the free space on that disk. The code is open source on GitHub under AGPL-3.0.',
          ],
        },
        {
          id: 'where-photos-go',
          q: 'Where do my photos go?',
          a: [
            'From your phone to your own computer. We do not run any server that stores them.',
            'When the two devices can reach each other directly, that is the whole path. When they cannot, the encrypted data is handed through a relay server, which only forwards it and can neither read nor keep it.',
            'Who provides the relay and what it can see is described in the Privacy Policy.',
          ],
          more: [{ label: 'Privacy Policy', href: '/privacy/' }],
        },
      ],
    },
    {
      id: 'install-pairing',
      title: 'Install and pairing',
      items: [
        {
          id: 'supported-devices',
          q: 'Will it run on my phone and computer?',
          a: [
            'The computer can be a Mac with an M-series chip or a PC running 64-bit Windows. The phone can be any Android phone on 8.0 or newer, or an iPhone on iOS 16 or newer.',
            'The iPhone app is installed through TestFlight, not the App Store. On an iPhone, backups run while P-Pass is open; whether iOS lets them continue in the background is up to the system.',
          ],
          more: [{ label: 'How to install on an iPhone', href: '/faq/#iphone-testflight' }],
        },
        {
          id: 'iphone-testflight',
          q: 'How do I install it on an iPhone?',
          a: [
            'Through TestFlight, Apple\'s own app for installing test versions.',
            {
              list: [
                'Install TestFlight from the App Store.',
                'On the iPhone, open the P-Pass public link in Safari and tap Accept, then Install. If the link was opened in WeChat, tap "···" at the top right and choose "Open in Safari" first. WeChat cannot install apps.',
                'In TestFlight, turn on automatic updates for P-Pass.',
              ],
            },
            'Each TestFlight build stops opening 90 days after it is published; it must be updated in TestFlight. Photos already on the computer are not deleted.',
          ],
          more: [{ label: 'P-Pass on TestFlight', href: TESTFLIGHT_URL }],
        },
        {
          id: 'setup',
          q: 'How long does setup take?',
          a: [
            'Two installs and one scan.',
            'Install and open P-Pass on the computer, choose a folder for the photos, then click "Show pairing QR". Install P-Pass on the phone, scan the code or enter the pairing code. The phone shows a 6-digit code. Enter it on the computer and click "Allow".',
          ],
          more: [
            {
              label: 'Getting-started guide',
              href: 'https://github.com/hawkeye-xb/P-Pass/blob/main/README.md',
            },
          ],
        },
        {
          id: 'app-permissions',
          q: 'What permissions does the app ask for, and why?',
          a: [
            'Photos and videos, photo location, camera, notifications, background running, network, and installing updates.',
            {
              list: [
                'Photos and videos: reading the albums you chose to back up.',
                'Photo location (Android only): reads the location stored in each photo; the phone\'s real-time location is not accessed.',
                'Camera: only for scanning the pairing QR code on the computer screen.',
                'Notifications: alerts when pairing is lost, photo permission changes, or background backup is stopped by the system. Requested when you turn on Notifications in Settings.',
                'Background running: keep transferring with the screen off, and pick up again after a restart.',
                'Battery whitelist (Android only): stops the system from halting background backup to save power.',
                'Installing updates (Android only): to install a new version from inside the app.',
              ],
            },
            'Contacts, microphone and SMS are not requested.',
          ],
        },
        {
          id: 'install-blocked',
          q: 'The system blocked the installer. Now what?',
          a: [
            'Apps not downloaded from an app store are blocked by the system: Gatekeeper on macOS, SmartScreen on Windows, the "unknown source" prompt on Android.',
            'The Windows installer is not code-signed, so SmartScreen shows "Windows protected your PC". Choose More info, then Run anyway.',
            'The steps for the other prompts, and how to check that the file is genuine, are in the repository docs.',
          ],
          more: [
            {
              label: 'Blocked by a security prompt',
              href: 'https://github.com/hawkeye-xb/P-Pass/blob/main/docs/troubleshooting/blocked-by-av.md',
            },
          ],
        },
      ],
    },
    {
      id: 'backup-sync',
      title: 'Backup and transfer',
      items: [
        {
          id: 'photo-permission-all',
          q: 'Why does the photo permission have to be "Allow all"?',
          a: [
            'With access limited to some photos, only the selected photos are backed up.',
            'In system settings, change photo access to "All". The albums to back up are set separately, under "Photos to back up" in the app.',
          ],
        },
        {
          id: 'first-backup',
          q: 'How long does the first backup take?',
          a: [
            "Depends on how many photos you have and how fast your home Wi-Fi is. The phone's home screen keeps showing how many are still waiting.",
            'You can close the computer or lose the network halfway. It picks up where it stopped and does not send anything twice.',
          ],
        },
        {
          id: 'mobile-data',
          q: 'Will it use my mobile data or drain the battery?',
          a: [
            'Backup is Wi-Fi-only by default; the mobile data switch is in settings, and it is off.',
            'Nothing runs while there is nothing to send. Some phone systems stop background work to save power; the app prompts you when a setting needs changing.',
          ],
        },
        {
          id: 'computer-on',
          q: 'Does the computer have to stay on?',
          a: [
            'It has to be on while it is backing up.',
            'While the computer is off, the photos stay on the phone. Once it is on and the two reconnect, the phone sends the rest.',
          ],
        },
        {
          id: 'how-do-i-know',
          q: 'How do I know a backup worked?',
          a: [
            'Backup status is shown in these five places.',
            {
              list: [
                'Phone home screen: one standing line, "Phone 1,234 · backed up 1,180 · waiting 54", plus the time of the last success.',
                "Photos on the phone: everything already on the computer is browsable there.",
                "Photos page in the computer app: the same library as a thumbnail wall.",
                'The photo folder on the computer: the original files are in it, and they open with a double-click.',
                'Activity in the computer app: who backed up what, and when.',
              ],
            },
          ],
        },
      ],
    },
    {
      id: 'photos-data',
      title: 'Photos and data',
      items: [
        {
          id: 'phone-delete',
          q: 'If I delete a photo on my phone, is the copy gone too?',
          a: [
            'No, it stays. Backup only ever adds.',
            'To remove photos from the computer, delete the originals on the phone first, then delete them in the photo folder. If you delete only on the computer, photos still on the phone are sent again at the next backup.',
          ],
        },
        {
          id: 'family-visibility',
          q: 'Can my family see the photos on my phone?',
          a: [
            'Yes. Phones paired to the same computer share one library, and everyone can see what the others backed up.',
          ],
        },
        {
          id: 'where-on-mac',
          q: 'Where are the photos kept on the computer?',
          a: [
            'In the folder you chose, as ordinary original files that open with a double-click.',
            "The app's Photos page browses the same library as thumbnails. Inside the folder each phone gets its own directory, named after a device id.",
          ],
        },
        {
          id: 'new-phone',
          q: 'I got a new phone, or lost mine. Are the photos safe?',
          a: [
            'The photos are backed up on the computer.',
            'Pair the new phone by scanning the code again. Photos already backed up are not sent again. To put photos back on a phone, save them to the gallery or share them from the Photos page.',
          ],
        },
        {
          id: 'disk-dies',
          q: 'What if the computer or its disk dies?',
          a: [
            'The backup lives on the one computer you chose. There is no second copy.',
            'The photos are ordinary files. Copy the photo folder to an external drive or another computer and you have a second copy.',
          ],
          more: [{ label: 'Terms of Use', href: '/terms/' }],
        },
      ],
    },
    {
      id: 'notices-trouble',
      title: 'Notices and problems',
      items: [
        {
          id: 'waiting-conditions',
          q: 'The phone shows "Waiting for backup conditions". What does that mean?',
          a: [
            'The conditions for automatic backup are not met yet. Backup starts automatically once they are.',
            'By default those are Wi-Fi and a battery that is not low. The system can also stop background work to save power; the app asks about the battery setting when that happens.',
          ],
        },
        {
          id: 'what-notifications',
          q: 'Which notifications does the app send?',
          a: [
            'Notifications are sent only when something needs your attention: pairing lost, photo permission changed, or background backup stopped by the system. A successful backup sends none, and neither does a single failed photo.',
            'These notifications are controlled by the Notifications switch in Settings, which is off by default on a new install. While photos are transferring, the notification bar shows a "Backing up photos" notice.',
          ],
        },
        {
          id: 'pairing-lost',
          q: 'The phone says the pairing is gone. Now what?',
          a: [
            'The photos are still on the phone. Scan the QR code on the computer again and backup continues.',
            'It usually means the computer removed this phone. You can check under Family & devices on the computer.',
          ],
        },
        {
          id: 'disk-full',
          q: 'What happens when the computer runs out of space?',
          a: [
            'Backup pauses, and photos already stored are not deleted. The phone\'s home screen says the computer\'s disk is full.',
            'Backup continues automatically once there is space. The phone warns early, when the computer has less than about 5 GB left.',
          ],
        },
        {
          id: 'stop-using',
          q: 'How do I disconnect a phone or stop backing up?',
          a: [
            'Uninstall the app on the phone and quit P-Pass on the computer. Nothing backs up after that.',
            'To cut off a single phone, remove it under Family & devices on the computer. The photos already on the computer stay where they are: they are ordinary files, and whether to delete them is your call.',
          ],
        },
        {
          id: 'contact',
          q: 'Where do I ask about anything else?',
          a: ['Email ppass@hawkeye-xb.com, or open an issue on GitHub. Either way we will follow up.'],
          more: [
            { label: 'ppass@hawkeye-xb.com', href: 'mailto:ppass@hawkeye-xb.com' },
            { label: 'GitHub Issues', href: 'https://github.com/hawkeye-xb/P-Pass/issues' },
          ],
        },
      ],
    },
  ],

  zh: [
    {
      id: 'cost-privacy',
      title: '费用与隐私',
      items: [
        {
          id: 'cost',
          q: '需要付费吗？',
          a: [
            '开源的，可以自建。',
            '照片存在你自己电脑的硬盘上，能存多少取决于那块硬盘还剩多少空间。代码开源在 GitHub 上（AGPL-3.0）。',
          ],
        },
        {
          id: 'where-photos-go',
          q: '照片会传到哪里？',
          a: [
            '只从你的手机传到你自己的电脑。我们没有存储照片的服务器。',
            '两台设备能直接连上就直接传；连不上时，加密过的数据会经一台中继服务器转交。中继只负责转交，解不开内容，也不留存。',
            '中继服务由谁提供、能看到什么信息，写在隐私政策里。',
          ],
          more: [{ label: '隐私政策', href: '/zh/privacy/' }],
        },
      ],
    },
    {
      id: 'install-pairing',
      title: '安装与配对',
      items: [
        {
          id: 'supported-devices',
          q: '我的手机和电脑能装吗？',
          a: [
            '电脑可以是 M1 及以后的 Mac，也可以是 64 位 Windows 电脑。手机可以是 Android 8.0 以上的任意牌子，也可以是 iOS 16 及以上的 iPhone。',
            'iPhone 版通过 TestFlight 安装，不在 App Store 里。iPhone 上的备份在打开 P-Pass 时进行，离开 App 后能否在后台接着传由 iOS 决定。',
          ],
          more: [{ label: 'iPhone 怎么安装', href: '/zh/faq/#iphone-testflight' }],
        },
        {
          id: 'iphone-testflight',
          q: 'iPhone 怎么安装？',
          a: [
            '通过 TestFlight 安装。TestFlight 是 Apple 官方用来分发测试版 App 的应用。',
            {
              list: [
                '在 App Store 安装 TestFlight。',
                '在 iPhone 的 Safari 里打开 P-Pass 的公开链接，点「接受」，再点「安装」。在微信里打开的链接，先点右上角「···」，选「在 Safari 中打开」，微信内无法安装。',
                '在 TestFlight 里为 P-Pass 打开自动更新。',
              ],
            },
            '每个 TestFlight 版本自发布起 90 天后无法再打开，需要在 TestFlight 里更新。已经备份到电脑上的照片不会被删除。',
          ],
          more: [{ label: '在 TestFlight 中打开 P-Pass', href: TESTFLIGHT_URL }],
        },
        {
          id: 'setup',
          q: '安装麻烦吗？',
          a: [
            '装两个 App，扫一次码。',
            '在电脑上安装并打开 P-Pass，选择存放照片的文件夹，点「显示配对二维码」。在手机上安装 P-Pass，扫码或输入配对码。手机显示 6 位验证码，在电脑上输入后点「允许加入」。',
          ],
          more: [
            {
              label: '上手指南',
              href: 'https://github.com/hawkeye-xb/P-Pass/blob/main/README.zh.md',
            },
          ],
        },
        {
          id: 'app-permissions',
          q: 'App 申请了哪些权限，分别做什么？',
          a: [
            '照片和视频、照片位置信息、相机、通知、后台运行、网络，以及安装更新包。',
            {
              list: [
                '照片和视频：读取你要备份的相册。',
                '照片位置信息（仅 Android）：读取照片里的拍摄位置，不获取手机的实时位置。',
                '相机：只用来扫电脑屏幕上的配对二维码。',
                '通知：配对失效、照片权限变化、后台备份被系统停止时提醒你。在设置里打开「通知」时申请。',
                '后台运行：熄屏时继续传，手机重启后自动接着来。',
                '电池白名单（仅 Android）：避免系统为省电停止后台备份。',
                '安装更新包（仅 Android）：应用内更新时安装新版本。',
              ],
            },
            '通讯录、麦克风和短信都不申请。',
          ],
        },
        {
          id: 'install-blocked',
          q: '安装时被系统拦截怎么办？',
          a: [
            '不是从应用商店下载的安装包会被系统拦截：macOS 是 Gatekeeper，Windows 是 SmartScreen，Android 是「未知来源」提示。',
            'Windows 安装包未做代码签名，SmartScreen 会显示「Windows 已保护你的电脑」。点「更多信息」，再点「仍要运行」。',
            '其他提示的放行步骤，以及如何核对安装包是否为官方发布，都写在仓库文档里。',
          ],
          more: [
            {
              label: '被安全弹窗拦住怎么办',
              href: 'https://github.com/hawkeye-xb/P-Pass/blob/main/docs/troubleshooting/blocked-by-av.md',
            },
          ],
        },
      ],
    },
    {
      id: 'backup-sync',
      title: '备份与同步',
      items: [
        {
          id: 'photo-permission-all',
          q: '相册权限为什么要选「全部」？',
          a: [
            '只允许部分照片时，只有选中的照片会备份。',
            '在系统设置里把照片权限改为「全部」。备份哪些相册，在 App 的「备份哪些照片」里单独设置。',
          ],
        },
        {
          id: 'first-backup',
          q: '首次备份需要多久？',
          a: [
            '取决于相册里有多少张照片、家里 Wi-Fi 有多快。手机首页会一直显示还剩多少张没传完。',
            '中途关电脑或断网都不用重来。重新连上会接着传，已经传过的不会重传。',
          ],
        },
        {
          id: 'mobile-data',
          q: '会消耗手机流量或电量吗？',
          a: [
            '默认只在 Wi-Fi 下自动备份，流量备份的开关在设置里，默认是关的。',
            '没有照片要传时不运行。部分手机系统会为省电停止后台任务，需要设置时 App 会提示。',
          ],
          more: [
            {
              label: '按手机品牌设置后台运行',
              href: 'https://github.com/hawkeye-xb/P-Pass/blob/main/docs/troubleshooting/android-background.md',
            },
          ],
        },
        {
          id: 'computer-on',
          q: '电脑需要一直开着吗？',
          a: [
            '备份进行时需要开着。',
            '电脑关着时，照片留在手机里。电脑开机、两边连上后，手机会补传没传完的照片。',
          ],
        },
        {
          id: 'how-do-i-know',
          q: '怎么确认备份成功？',
          a: [
            '备份是否成功，可在这五处查看。',
            {
              list: [
                '手机首页：常驻一行「手机 1,234 张 · 已备份 1,180 · 待备份 54」，以及最后一次成功的时间。',
                '手机上的「照片」页：已经备份到电脑的照片都在这里，能翻能看。',
                '电脑端 App 的「照片」页：同一个照片库的缩略图墙。',
                '电脑上存放照片的文件夹：原文件就在里面，双击即可打开。',
                '电脑端的「活动记录」：谁在什么时候备份了什么。',
              ],
            },
          ],
        },
      ],
    },
    {
      id: 'photos-data',
      title: '照片与数据',
      items: [
        {
          id: 'phone-delete',
          q: '手机上删了照片，电脑上那份还在吗？',
          a: [
            '还在。备份只会增加文件，手机上的删除不会同步过来。',
            '要清掉电脑上的照片，先删手机上的原图，再删电脑文件夹里的。只在电脑上删除时，手机上还有的照片会在下次备份时重新传回来。',
          ],
        },
        {
          id: 'family-visibility',
          q: '家人能看到我手机里的照片吗？',
          a: [
            '能。连到同一台电脑的手机共用一个照片库，互相都看得到。',
          ],
        },
        {
          id: 'where-on-mac',
          q: '照片在电脑上存放在哪里？',
          a: [
            '在你选择的文件夹里，是普通的原文件，双击即可打开。',
            '电脑端 App 的「照片」页也能翻看缩略图。文件夹里按手机分开存放，目录名是设备编号。',
          ],
        },
        {
          id: 'new-phone',
          q: '换手机或手机丢了怎么办？',
          a: [
            '照片已备份在电脑上。',
            '新手机重新扫码配对，已备份的照片不会重传。要放回手机相册，在「照片」页把照片存回相册或分享出去。',
          ],
        },
        {
          id: 'disk-dies',
          q: '电脑或硬盘坏了怎么办？',
          a: [
            '这份备份只在你选的那台电脑上，没有第二份。',
            '照片是普通文件。把存放照片的文件夹拷到移动硬盘或另一台电脑，就有了第二份。',
          ],
          more: [{ label: '使用条款', href: '/zh/terms/' }],
        },
      ],
    },
    {
      id: 'notices-trouble',
      title: '状态、提示与故障',
      items: [
        {
          id: 'waiting-conditions',
          q: '手机显示「等待备份条件满足」，是什么意思？',
          a: [
            '还没满足自动备份的条件。满足后会自动开始。',
            '默认条件是连上 Wi-Fi、电量不低。系统为省电停掉后台任务时也会停，App 会在需要设置的时候提示你。',
          ],
          more: [
            {
              label: '按手机品牌设置后台运行',
              href: 'https://github.com/hawkeye-xb/P-Pass/blob/main/docs/troubleshooting/android-background.md',
            },
          ],
        },
        {
          id: 'what-notifications',
          q: 'App 会发哪些通知？',
          a: [
            '需要你处理时才发通知：配对失效、照片权限变化、后台备份被系统停止。备份成功不发通知，单张照片备份失败也不发。',
            '这些通知由设置里的「通知」开关控制，新安装默认关闭。传输时通知栏会显示一条「正在备份照片」。',
          ],
        },
        {
          id: 'pairing-lost',
          q: '手机提示「配对已失效」怎么办？',
          a: [
            '照片还在手机上。重新扫描电脑上的二维码，备份会继续。',
            '通常是电脑上移除了这台手机。在电脑的「家人与设备」里可以确认。',
          ],
        },
        {
          id: 'disk-full',
          q: '电脑空间满了会怎样？',
          a: [
            '备份暂停，已存的照片不会被删除。手机首页会提示电脑磁盘已满。',
            '腾出空间后备份自动继续。电脑剩余空间不到约 5 GB 时，手机会提前提示。',
          ],
        },
        {
          id: 'stop-using',
          q: '怎么断开某台手机，或停止备份？',
          a: [
            '手机卸载 App、电脑退出 P-Pass，之后就不再自动备份了。',
            '只想单独断开某台手机，在电脑的「家人与设备」里把它移除。已经备份到电脑上的照片不会被带走：它们就是你电脑上的普通文件，删不删由你决定。',
          ],
        },
        {
          id: 'contact',
          q: '其他问题在哪里提问？',
          a: ['发邮件到 ppass@hawkeye-xb.com，或到 GitHub 提 issue，我们都会跟进。'],
          more: [
            { label: 'ppass@hawkeye-xb.com', href: 'mailto:ppass@hawkeye-xb.com' },
            { label: 'GitHub Issues', href: 'https://github.com/hawkeye-xb/P-Pass/issues' },
          ],
        },
      ],
    },
  ],
};
