/**
 * Page copy for /zh/backup-without-nas/ — the entry page for people who search
 * "back up phone photos to my computer without NAS / without Docker".
 *
 * Facts only, and every one of them is traceable inside this repo: src/i18n/faq.ts
 * (the setup steps incl. the allow prompt, the status line on the phone, the
 * photos on the computer app, device support, the relay, the Wi-Fi default, the
 * ~5 GB warning, originals kept uncompressed), README, and src/consts.ts.
 * If a sentence cannot be sourced, it does not go on the page.
 *
 * `title` and `metaDescription` are the page's metadata; the visible copy
 * answers the same question in its own words. The two are allowed to differ —
 * do not "fix" one to match the other.
 *
 * Chinese only for now: the English page lands together with the English copy.
 */

export interface GuideLink {
  label: string;
  href: string;
}

export const GUIDE = {
  zh: {
    title: '不用 NAS、不用 Docker：把手机照片备份回自己家的电脑 — P-Pass',
    metaDescription:
      '手机照片自动备份到家里的电脑，存原图不压缩，不用注册账号、不使用云存储，开源。电脑支持 Apple 芯片 Mac 与 64 位 Windows，手机支持 Android 8.0 以上，iPhone 版通过 TestFlight 安装。',
    h1: '把手机照片备份回自己家的电脑',
    lead: [
      '家里有一台电脑，就能把手机照片备份到这台电脑上：手机连上 Wi-Fi 后，照片自动传进电脑。',
    ],
    steps: {
      title: '装两个 App，扫一次码',
      paras: [
        '在电脑上安装并打开 P-Pass，选择存放照片的文件夹，点「显示配对二维码」。在手机上安装 P-Pass，扫电脑上的二维码，或输入配对码。手机显示 6 位验证码，在电脑上输入后点「允许加入」。手机询问照片权限时，选择允许访问全部照片，再选择要备份的相册，以及是否也备份以前的照片。在手机 App 的「设置」里开启后台备份，不打开 App 也能备份新照片。',
      ],
    },
    after: {
      title: '打开后台备份之后，照片自己进电脑',
      paras: [
        '后台备份打开以后，白天在外面拍的照片，回到家连上 Wi-Fi 就开始往电脑上传，你不点任何按钮，也不插线，传完的就在电脑里了。',
        '传到电脑上的是原图，没有压缩，放在你选择的文件夹里，双击即可打开。想确认有没有传成功，手机首页一直写着已经备份了多少张、还剩多少张，电脑端也能看到同一批照片。',
      ],
    },
    fit: {
      title: '家里的电脑够不够用',
      paras: [
        '电脑可以是 Apple 芯片的 Mac（M1 及以后），也可以是 64 位 Windows 电脑。备份时电脑需要开着。电脑关着时照片留在手机里，开机连上后接着传，传过的不会重传。',
        '硬盘剩下不到约 5 GB 的时候，手机会提前提示你。',
        '手机可以是 Android 8.0 以上的任意牌子，也可以是 iOS 16 及以上的 iPhone；iPhone 版通过 TestFlight 安装，备份在打开 P-Pass 时进行，离开 App 后能否在后台接着传由 iOS 决定。',
      ],
    },
    money: {
      title: '要花多少钱，照片存在哪',
      paras: [
        '开源的，可以自建。能存多少取决于那块硬盘还剩多少空间。代码开源在 GitHub 上（AGPL-3.0）。',
        '照片存在你选的那台电脑上，我们没有存照片的服务器。能直连就直连；连不上时，加密过的数据会经一台中继转交，中继解不开内容，也不留存。',
      ],
    },
    more: {
      title: '还想细看的问题',
      links: [
        { label: '相册权限为什么要选全部', href: '/zh/faq/#photo-permission-all' },
        { label: '第一次备份要多久', href: '/zh/faq/#first-backup' },
        { label: '电脑空间满了会怎样', href: '/zh/faq/#disk-full' },
        { label: 'iPhone 怎么安装', href: '/zh/faq/#iphone-testflight' },
      ] satisfies GuideLink[],
    },
    /**
     * Same two steps the page describes above, written as instructions for
     * structured data. Kept here next to the prose so the two stay in sync.
     */
    howToSteps: [
      {
        name: '电脑上安装 P-Pass，选一个存放照片的文件夹',
        text: '运行安装包，打开 P-Pass，选择存放照片的文件夹，然后点「显示配对二维码」。',
      },
      {
        name: '手机安装 App，扫码或输入配对码',
        text: '在手机上安装 P-Pass，扫电脑上的二维码，或输入配对码。手机显示 6 位验证码，在电脑上输入后点「允许加入」，两台设备配对完成。',
      },
    ],
  },
} as const;
