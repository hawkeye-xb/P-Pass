/**
 * Page copy for /zh/backup-without-nas/ — the entry page for people who search
 * "back up phone photos to my computer without NAS / without Docker".
 *
 * Facts only, and every one of them is traceable inside this repo: src/i18n/faq.ts
 * (the setup steps incl. the allow prompt, the status line on the phone, the
 * photos on the computer app, device support, the relay, the Wi-Fi default, the
 * 5 GB warning, originals kept uncompressed), README, and src/consts.ts.
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
      '用家里那台电脑当相册：手机照片在同一个 Wi-Fi 下自动备份到电脑，存原图不压缩，不用注册账号、不上传云端，开源。支持 Apple 芯片 Mac 与 Android 8.0 以上。',
    h1: '把手机照片备份回自己家的电脑',
    lead: [
      '家里有一台电脑，就能把手机照片备份回去：手机上的照片，回到家连上同一个 Wi-Fi，就自己备份进电脑里。手机要 Android 8.0 以上，不分牌子。',
    ],
    steps: {
      title: '装两个 App，扫一次码',
      paras: [
        '电脑上先装好 P-Pass，跟着向导挑一个放照片的文件夹，屏幕上会出现一个二维码。手机装好 App 之后扫这个码，电脑上点一下允许，两边就配上了。往后手机和电脑在同一个 Wi-Fi 下，新拍的照片会自己传过来。',
      ],
    },
    after: {
      title: '装完之后，照片自己进电脑',
      paras: [
        '白天在外面拍的照片，回到家连上 Wi-Fi 就开始往电脑上传，你不点任何按钮，也不插线，传完的就在电脑里了。',
        '传到电脑上的是原图，没有压缩，就放在你当初挑的那个文件夹里，双击就能打开。想确认有没有传成功，手机首页上一直写着已经备份了多少张、还剩多少张，电脑端也能看到同一批照片。',
      ],
    },
    fit: {
      title: '家里的电脑够不够用',
      paras: [
        '电脑要 Apple 芯片的 Mac（M1 及以后）。备份进行的时候电脑得开着，其余时间它自己待着就行；电脑关着时照片留在手机里，开机连上会接着传，传过的不会重传。',
        '硬盘剩下不到 5 GB 的时候，手机会提前提示你。',
        'iPhone 版和 Windows 版都还没有发布。',
      ],
    },
    money: {
      title: '要花多少钱，照片存在哪',
      paras: [
        '不用付费，没有订阅，也没有容量费。能存多少取决于那块硬盘还剩多少空间。代码开源在 GitHub 上（AGPL-3.0）。',
        '照片存在你选的那台电脑上，我们没有存照片的服务器。能直连就直连；连不上时，加密过的数据会经一台中继转交，中继解不开内容，也不留存。',
      ],
    },
    more: {
      title: '还想细看的问题',
      links: [
        { label: '相册权限为什么要选全部', href: '/zh/faq/#photo-permission-all' },
        { label: '第一次备份要多久', href: '/zh/faq/#first-backup' },
        { label: '电脑空间满了会怎样', href: '/zh/faq/#disk-full' },
      ] satisfies GuideLink[],
    },
    /**
     * Same two steps the page describes above, written as instructions for
     * structured data. Kept here next to the prose so the two stay in sync.
     */
    howToSteps: [
      {
        name: '电脑上安装 P-Pass，选一个存放照片的文件夹',
        text: '运行安装包，跟着向导走完，挑一个用来存照片的文件夹；向导结束时电脑屏幕上会出现一个二维码。',
      },
      {
        name: '手机安装 App，扫描电脑上的二维码',
        text: '手机装好 P-Pass 之后扫这个二维码，电脑上点一下允许，两台设备就配对了。',
      },
    ],
  },
} as const;
