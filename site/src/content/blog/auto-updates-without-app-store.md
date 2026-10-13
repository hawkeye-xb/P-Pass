---
title: 不上应用商店，macOS 和 Android 怎么做自动更新：Tauri updater 与 APK 自更新
description: "五条规则：不走应用商店，用 GitHub Releases、Tauri updater 和 APK 自更新给 macOS 与 Android 做自动更新：按平台分版本号、清单兼容、多源回退、minisign 验签、发版门禁。"
date: 2026-10-13
tags: [工程, 发布, 自动更新, CI]
lang: zh
draft: true
---

P-Pass 是一个开源工具，把手机里的照片和视频备份到自己的电脑上。它有 macOS 和 Android 两个客户端，都不走应用商店。新版本发在 GitHub Releases。客户端定期读一份我们自己维护的更新清单，有新版本就提示用户，确认后下载、验签、安装。

没有应用商店替你审包、分发、比版本，这些事全得自己做。这条链路我们改了一个月，版本从 0.8.x 走到 0.9.0，再到现在按批次发的 `v2026.10.x`。中间出过的事，最后收成了五条规则。要保证的就两件事：装上的包是我们签的；哪一端没改，哪一端就不弹更新。

## 规则一：按平台分版本号，git tag 只当批次号

最早两端共用一个版本号。有一批改动只碰了安卓，Mac 端的二进制一个字节没变，号也跟着涨，Mac 用户就被叫去更新了一次。那几天一天要发好几版，同一个人一天能被叫好几次。

我们先想过给清单加个标记，让没变的那一端跳过。桌面端用的是 tauri-plugin-updater 2.10.1。翻它的源码，清单里版本号只有顶层一个字段，平台条目里只有 `url` 和 `signature`。判断要不要升级，就一行 `release.version > self.current_version`。没有地方写「这一端本次不更新」，要加只能 fork 插件。

我们拆成两层。

- git tag 是批次号，形如 `v2026.10.5`：年、月、当月第几个批次，只往前走。一个批次就是一次发版，用户在 GitHub 上看到的还是一个入口，最新那个 release 里永远两端齐全。
- 每一端的版本号单独记在 `release/versions.json`。客户端只跟自己那一端的号比。`androidVersionCode` 是 Android 安装器比较新旧用的整数，只增不减。

```json
{
  "desktop": "0.9.7",
  "android": "0.9.12",
  "androidVersionCode": 65
}
```

哪一端该涨号，由发版流水线按改动路径判断，号没涨就拦下：

| 改动路径 | 必须前进的号 |
|---|---|
| `apps/desktop/`、Rust 内核 `crates/`、`Cargo.lock` 等桌面会打包进去的代码 | 桌面 |
| `apps/android/` | 安卓 |
| 只改文档、官网、`.github/`、`tools/` | 都不该动 |

它只看路径，不看改动的意思，改一句注释也算改了代码。多发一版没关系，漏发不行。

一个小坑：同一个月的第二个批次要写成 `v2026.10.2`，别写成 `v2026.10.1-2`。在 semver 里 `-2` 是预发布后缀，比 `2026.10.1` 还小。流水线比较哪个 release 更新时，会直接判错。

10 月 12 日发的 `v2026.10.5` 只修了一个 Mac 首次启动的问题。Mac 升到 0.9.7，安卓留在 0.9.12，手机上不会出现更新提示。

## 规则二：更新清单（manifest）改格式，旧格式要冻结

已经装在用户设备上的老客户端，去哪儿找清单、怎么读清单，都写死在它自己那个版本里，我们改了格式，它不会知道。

具体是三步。

1. 换格式之前，先发一个两端同号的过渡版本 0.9.0，让老客户端按老格式升到它。
2. 老格式的清单从此冻住，内容停在 0.9.0，不再改。
3. 新客户端读分端清单，每端一份：`manifest-android.json` 和 `manifest-macos.json`。

少了第一步，老客户端会出两种问题。一种是读不懂新格式，每次检查都失败，再也收不到更新。另一种是新清单的顶层号比它大，于是提示更新，装完还是旧号，下次再提示。

清单里的 `signature` 是对着 `url` 指向的那个文件算的：

```json
{
  "version": "0.9.12",
  "platforms": {
    "android-arm64": {
      "url": "https://github.com/hawkeye-xb/P-Pass/releases/download/v2026.10.5/P-Pass_0.9.12_android.apk",
      "signature": "dW50cnVzdGVkIGNvbW1lbnQ6…",
      "sha256": "950f1f85…"
    }
  }
}
```

最早 `url` 指向 `P-Pass-latest.apk`。这个文件每版都被覆盖，下一版一发，老清单里的签名就对不上了，更新直接失败。现在清单里的地址一律指向带版本号、不会被覆盖的文件。

## 规则三：多个更新源按顺序回退，「查不到」不等于「已是最新」

以前只有 GitHub Releases 一个源。我们用手机在 5G 下试过，下载慢得等不下去。源连不上的时候，如果客户端把失败当成没有新版本，用户会一直停在旧版，界面上还写着已是最新。只换个源也不行，换过去的那个一样会挂。已经装机的老客户端也只认 GitHub 的地址，丢不掉。

现在客户端拿到的是一个有序列表，桌面端写在 `tauri.conf.json` 的 endpoints 里：

```
https://p-pass-dl.hawkeye-xb.com/manifest-macos.json
https://github.com/hawkeye-xb/P-Pass/releases/latest/download/manifest-macos.json
```

第一项是 Cloudflare R2 上的镜像，第二项是 GitHub。安卓端按同样的规则逐个去问，每种情况都写进了测试：

| 这个源返回了什么 | 客户端怎么做 |
|---|---|
| 有新版本 | 提示更新，停 |
| 已是最新 | 停，不再问下一个 |
| 404 | 镜像可能还没跟上，问下一个 |
| 拿到内容但解析不了 | 镜像可能写了一半，问下一个 |
| 全部问完，有过失败，没人给出答案 | 报「检查失败」 |

镜像只放正式版。我们还有一个 test 通道，给测试设备装预发布的 test 版。回头检查改动时发现，test 版发布以后，镜像任务会把它当成最新的 release，覆盖镜像上正式版的包和清单。test 包用的是同一把签名钥匙，校验能过，正式版用户就会被推一个测试包。这件事没真发生就被拦住了，现在镜像任务见到 `-test.` 的 tag 一律跳过。

## 规则四：验签测试用线上真实签名，CI 真跑 apksigner

这件事发生在 0.8.x，换版本规则之前。自动更新要验两道签名。安卓装包之前，App 用内置的 minisign 公钥验一遍；发版流水线出包时，确认 APK 是用发布证书签的。两道都出过错。

先说 App 这一道。第一次在手机上走完整条更新链路，是从 0.8.1 升到 0.8.2。检查、弹窗、下载都正常，最后一步报「安装包校验未通过」，重试也一样。清单里的 `signature` 装的是整个 `.minisig` 文件的 base64，解开是四行文本。App 却按 74 字节的裸结构去解，长度一对不上就判失败。

单元测试一直是绿的，测试向量是照着实现造的。修的时候我们把线上 v0.8.2 清单里的签名原文直接写进了测试。另外用 Node 自带的 crypto 独立验了一遍，签名和哈希都没问题，问题出在 App 的解析。

再说流水线这一道。原来判断 APK 签没签，看的是 `app-release.apk` 这个文件在不在。没签名、签名方案不满足最低系统版本、用错了证书，这个文件照样在。现在改成真跑 `apksigner`：

- `apksigner verify --min-sdk-version 26` 必须通过；
- 签名者必须是发布证书；
- 机器上找不到 `apksigner`，也算失败。

我们拿三个包试过：真发行包通过，没签名的包和用调试证书重签的包都被拦下。

## 规则五：GitHub Actions 发版流水线，缺产物就失败

- 发过渡版本 0.9.0 的那天晚上，桌面端升上去了，手机没反应。负责同步镜像的任务调用了仓库里的一个脚本，可这个任务从来没有 checkout 过仓库。安装包传完了，清单一份都没同步出去。
- 下一个批次发完，Mac 检查不到更新。macOS 的构建被取消了，上传跟着跳过，生成清单那一步看见没有 mac 产物，也就跳过了 mac 的清单。
- 再下一个批次，安卓的分端清单上传时签名是空的。签名那一步的触发条件还在找一个已经不再产出的文件，整步被跳过了。

现在该有的产物没有、有密钥但签名为空，流水线都直接失败。下面是 mac 产物那道门，节选自 `tools/release/compose-desktop.sh`，报错文字有简化。

```bash
case "${PLATFORMS:-all}" in
  *macos*|*all*|"")
    [ -n "$MAC_UPD" ] || {
      echo "::error::本次应产出 macOS 产物但更新包不在——拒绝发布没有 mac 更新源的清单"
      exit 1
    } ;;
esac
```

我们还加了一个修复用的工作流。它拿已发布 tag 现有的产物，重算、重签全部清单，不重新构建，也不挪 tag，几分钟就能补好一个发坏的版本。

这类问题几乎都要真打一次 tag 才暴露。GitHub Actions 的 release 事件，用的是 tag 那个 commit 里的 workflow。本地 dry-run 和 PR 上的 CI，都走不到只有发版才会走的分支。流水线自己的 bug，也没法靠重跑旧 tag 修好。

最后一步，我们让 test 通道和正式版走同一条路。test 版同样按端判断要不要构建，同样写分端清单，Mac 的 test 版也用正式版的插件做应用内更新。我们试发了一个只改安卓的 test 版。流水线判定安卓构建、macOS 跳过。Mac 没收到提示，测试手机在应用内升了上去。

## 代码在哪

P-Pass 是开源的，上面的做法都在 [GitHub 仓库](https://github.com/hawkeye-xb/P-Pass)里。

- 判端规则：`tools/check-version-bump.sh`、`tools/release/plan-builds.sh`
- 生成清单：`tools/make-update-manifest.mjs`
- 发版和修复清单：`.github/workflows/release.yml`、`.github/workflows/repair-manifests.yml`
