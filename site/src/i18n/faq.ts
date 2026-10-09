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
 *   waiting-conditions    state_waiting_battery, idle_auto_hint, dog_battery_body
 *   pairing-lost          pairing_lost_body, notif_pairing_lost_body
 *   what-notifications    rule_notify_hint, onboarding_notification_note, notif_channel_backup_failed
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
  en: 'Answers to common questions about P-Pass: where your photos are stored, which phones and computers are supported, what permissions it needs, and whether the computer has to stay on.',
  zh: 'P-Pass 常见问题：照片存在哪里、支持哪些手机和电脑、需要哪些权限、电脑要不要一直开着、换手机或硬盘坏了怎么办。',
};

export const FAQ_TOP_LABEL: Record<Lang, string> = {
  en: 'You might want to know these first',
  zh: '也许你想先了解这几条',
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
            'Backing up at home costs nothing.',
            'Your photos sit on your own computer, so the only limit is the free space on that disk. The code is open source on GitHub under AGPL-3.0.',
          ],
        },
        {
          id: 'where-photos-go',
          q: 'Where do my photos go?',
          a: [
            'From your phone to your own computer. We do not run any server that stores them.',
            'When the two devices can reach each other directly, that is the whole path. When they cannot, the encrypted data is handed through a relay server, which only forwards it and can neither read nor keep it.',
            'That relay and the address lookup are run by number 0, the maintainers of the open-source library iroh. This path is only used when a direct connection fails.',
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
            'The computer needs a Mac with an M-series chip. The phone needs Android 8.0 or newer, any brand.',
            'The iPhone app and the Windows app are not published.',
          ],
        },
        {
          id: 'setup',
          q: 'How long does setup take?',
          a: [
            'Two installs and one scan, and no technical knowledge.',
            'Install the app on the computer. The wizard asks which folder should hold your photos, then shows a QR code. Install the app on the phone, scan the code, tap Allow on the computer. That is the whole thing.',
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
            'Photos and videos, camera, notifications, background running, network, and installing updates.',
            {
              list: [
                'Photos and videos: reading the albums you chose to back up.',
                'Camera: only for scanning the pairing QR code on the computer screen.',
                'Notifications: pairing lost, photo permission revoked, background backup stopped by the system, or a backup that failed.',
                'Background running: keep transferring with the screen off, and pick up again after a restart.',
                'Battery whitelist: stop the system from killing background work to save power.',
                'Installing updates: to install a new version from inside the app.',
              ],
            },
            'Contacts, location, microphone and SMS are not requested.',
          ],
        },
        {
          id: 'install-blocked',
          q: 'The system blocked the installer. Now what?',
          a: [
            'That is normal for an app downloaded outside the app stores: Gatekeeper on macOS, the "unknown source" prompt on Android.',
            'The steps to allow it are in the repository docs.',
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
            'With "Selected photos" the app cannot read the rest, and those never get backed up.',
            'Change it to Allow all in system settings. Which albums get backed up is set separately, in the album list inside P-Pass.',
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
            'Nothing runs while there is nothing to send. HarmonyOS, Samsung and some other systems kill background work to save power; the app asks about the battery setting when that happens.',
          ],
        },
        {
          id: 'computer-on',
          q: 'Does the computer have to stay on?',
          a: [
            'It has to be on while it is backing up.',
            'With the computer off, the photos stay on your phone untouched. Once the computer comes back and the two reconnect, the phone sends whatever is still missing.',
          ],
        },
        {
          id: 'how-do-i-know',
          q: 'How do I know a backup worked?',
          a: [
            'Several places show it; no single number has to be trusted on its own.',
            {
              list: [
                'Phone home screen: one standing line, "Phone 1,234 · backed up 1,180 · waiting 54", plus the time of the last success.',
                "Photos on the phone: everything already on the computer is browsable there.",
                "Photos page in the computer app: the same library as a thumbnail wall.",
                'The folder on the computer: the original files are in it, and they open from Finder.',
                'Activity in the computer app: who backed up what, and when.',
              ],
            },
            'A failure sends a notification that names the files and where it stopped. Success is silent.',
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
            'To clear photos off the computer, open the folder and delete them there. If you move or delete files in that folder, P-Pass records it and does not quietly put them back.',
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
            'In the folder you picked. They are ordinary files, and they open by double-clicking.',
            "The app's Photos page browses the same library as thumbnails. Inside the folder each phone gets its own directory, named after a device id.",
          ],
        },
        {
          id: 'new-phone',
          q: 'I got a new phone, or lost mine. Are the photos safe?',
          a: [
            'They are on the computer, so they do not go anywhere with the phone.',
            'Pair the new phone by scanning the code once. Nothing already backed up is uploaded a second time. To get a photo back onto a phone, the Photos page can save it to the gallery or share it.',
          ],
        },
        {
          id: 'disk-dies',
          q: 'What if the computer or its disk dies?',
          a: [
            'The backup lives on the one computer you chose. There is no second copy.',
            'Nothing is locked up, though: copy that folder to an external drive or another machine and you have a second copy.',
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
          q: 'The phone says it is "waiting for backup conditions". What does that mean?',
          a: [
            'The automatic conditions are not met yet. It starts on its own once they are; you do not have to do anything.',
            'By default those are Wi-Fi and a battery that is not low. The system can also stop background work to save power; the app asks about the battery setting when that happens.',
          ],
        },
        {
          id: 'what-notifications',
          q: 'What notifications will I get?',
          a: [
            'Four kinds only: pairing lost, photo permission revoked, background backup stopped by the system, and a backup that failed. A successful backup is silent.',
            'The notification permission is used for those four and nothing else. You can switch them off in settings.',
          ],
        },
        {
          id: 'pairing-lost',
          q: 'The phone says the pairing is gone. Now what?',
          a: [
            'Nothing was lost; the photos are still on the phone. Scan the QR code on the computer again and backup continues.',
            'It usually means the computer removed this phone; Family & devices on the computer shows whether it is still paired.',
          ],
        },
        {
          id: 'disk-full',
          q: 'What happens when the computer runs out of space?',
          a: [
            'Backup pauses and waits, and nothing already stored is deleted. The phone says the storage computer is full.',
            'Backup continues on its own once there is space again. The phone warns early, once the computer has less than 5 GB left.',
          ],
        },
        {
          id: 'stop-using',
          q: 'What do I do if I stop using it?',
          a: [
            'Uninstall the app on the phone and quit P-Pass on the computer. Nothing backs up after that.',
            'To cut off a single phone, remove it under Family & devices on the computer. The photos already on the computer stay where they are: they are ordinary files, and whether to delete them is your call.',
          ],
        },
        {
          id: 'contact',
          q: 'Where do I ask about anything else?',
          a: ['Open an issue on GitHub and we will follow up.'],
          more: [{ label: 'GitHub Issues', href: 'https://github.com/hawkeye-xb/P-Pass/issues' }],
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
            '开源的，可以自建，不收钱。',
            '照片存在你自己电脑的硬盘上，能存多少取决于那块硬盘还剩多少空间。代码开源在 GitHub 上（AGPL-3.0）。',
          ],
        },
        {
          id: 'where-photos-go',
          q: '照片会传到哪里？',
          a: [
            '只从你的手机传到你自己的电脑。我们没有存储照片的服务器。',
            '两台设备能直接连上就直接传；连不上时，加密过的数据会经一台中继服务器转交。中继只负责转交，解不开内容，也不留存。',
            '中继和设备发现服务目前由开源网络库 iroh 的维护方 number 0 提供。这条路只在直连失败时才用得上。',
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
            '电脑要 M1 及以后的 Mac，手机要 Android 8.0 以上，不分牌子。',
            'iPhone 版和 Windows 版没有发布，下载不到。',
          ],
        },
        {
          id: 'setup',
          q: '安装麻烦吗？',
          a: [
            '装两个 App、扫一次码，不需要懂技术。',
            '先在电脑上装好 App，向导会让你选一个存照片的文件夹，然后屏幕上出现二维码。手机上装好 App 扫一下，电脑上点「允许」，就完成了。',
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
            '照片和视频、相机、通知、后台运行、网络，以及安装更新包。',
            {
              list: [
                '照片和视频：读取你要备份的相册。',
                '相机：只用来扫电脑屏幕上的配对二维码。',
                '通知：配对失效、相册权限被收回、后台备份被系统停掉、备份失败时提醒你。',
                '后台运行：熄屏时继续传，手机重启后自动接着来。',
                '电池白名单：避免系统为省电把备份掐掉。',
                '安装更新包：应用内更新时安装新版本。',
              ],
            },
            '通讯录、位置、麦克风和短信都不申请。',
          ],
        },
        {
          id: 'install-blocked',
          q: '安装时被系统拦截怎么办？',
          a: [
            '这是正常现象，不在应用商店里下载的 App 都会遇到：macOS 上是 Gatekeeper 拦截，Android 上是「未知来源」提示。',
            '两边的放行步骤都写在仓库文档里。',
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
            '只给「部分照片」的话，没被选中的照片 App 读不到，也就不会备份。',
            '到系统设置里把照片权限改成「全部」即可。备份范围由 App 里「备份哪些相册」单独控制，两者互不影响。',
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
            '没有照片要传的时候它不工作。鸿蒙、三星这类系统会为省电停掉后台任务；App 会在需要设置的时候提示你。',
          ],
        },
        {
          id: 'computer-on',
          q: '电脑需要一直开着吗？',
          a: [
            '备份进行时需要开着。',
            '电脑关着的时候，照片原样留在手机里，不会丢。等电脑开机、两边连上，手机会把没传完的补上。',
          ],
        },
        {
          id: 'how-do-i-know',
          q: '怎么确认备份成功？',
          a: [
            '几个地方都能看到，不用只信一个数字。',
            {
              list: [
                '手机首页：常驻一行「手机 1,234 张 · 已备份 1,180 · 待备份 54」，以及最后一次成功的时间。',
                '手机上的「照片」页：已经备份到电脑的照片都在这里，能翻能看。',
                '电脑端 App 的「照片」页：同一个照片库的缩略图墙。',
                '电脑上那个文件夹：原文件就在里面，Finder 里双击就能打开。',
                '电脑端的「活动记录」：谁在什么时候备份了什么。',
              ],
            },
            '失败会单独发通知，点开能看到是哪几张、卡在哪；成功不发通知。',
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
            '要清掉电脑上的照片，直接打开那个文件夹删除即可。你在文件夹里挪走或删掉文件，程序会照实记一笔，不会偷偷传回来。',
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
            '就在你当初选的那个文件夹里。它们是普通的原文件，双击就能打开。',
            '电脑端 App 的「照片」页也能翻看缩略图。文件夹里按手机分开存放，目录名是设备编号。',
          ],
        },
        {
          id: 'new-phone',
          q: '换手机或手机丢了怎么办？',
          a: [
            '照片都在电脑上，不会跟着手机丢。',
            '新手机重新扫一次码配对，已经备份过的不会重传。要拿回手机相册，在「照片」页把照片存回相册或分享出去就可以了。',
          ],
        },
        {
          id: 'disk-dies',
          q: '电脑或硬盘坏了怎么办？',
          a: [
            '这份备份只在你选的那台电脑上，没有第二份。',
            '文件本身不锁死：把那个文件夹整个拷到移动硬盘或另一台电脑，就是第二份。',
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
          q: '手机显示「正在等待备份条件满足」，是什么意思？',
          a: [
            '意思是暂时还没满足自动备份的条件，满足后会自动开始，不用你操作。',
            '默认条件是连上 Wi-Fi、电量不低。系统为省电停掉后台任务时也会停，App 会在需要设置的时候提示你。',
          ],
        },
        {
          id: 'what-notifications',
          q: 'App 会给我发什么通知？',
          a: [
            '只有四类：配对失效、相册权限被收回、后台备份被系统停掉，以及备份失败。备份成功不发通知。',
            '通知权限只服务于这四类，不推别的。在设置里可以关掉。',
          ],
        },
        {
          id: 'pairing-lost',
          q: '手机提示「配对已失效」怎么办？',
          a: [
            '照片一张没丢，都还在手机上。重新扫一次电脑上的二维码就会继续备份。',
            '通常是电脑端把这台手机移除了；电脑端「家人与设备」里能看到这台手机还在不在。',
          ],
        },
        {
          id: 'disk-full',
          q: '电脑空间满了会怎样？',
          a: [
            '备份会停下来等着，已经存好的照片不会被删。手机首页会显示存储电脑的空间满了。',
            '腾出空间之后备份会自己继续。电脑剩余空间不到 5 GB 时，手机端会提前提示。',
          ],
        },
        {
          id: 'stop-using',
          q: '停止使用要做什么？',
          a: [
            '手机卸载 App、电脑退出 P-Pass，之后就不再自动备份了。',
            '只想单独断开某台手机，在电脑的「家人与设备」里把它移除。已经备份到电脑上的照片不会被带走：它们就是你电脑上的普通文件，删不删由你决定。',
          ],
        },
        {
          id: 'contact',
          q: '其他问题在哪里提问？',
          a: ['到 GitHub 提 issue，我们会跟进。'],
          more: [{ label: 'GitHub Issues', href: 'https://github.com/hawkeye-xb/P-Pass/issues' }],
        },
      ],
    },
  ],
};
