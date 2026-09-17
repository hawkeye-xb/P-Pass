# BUILD-05 本地桌面打包在"预期内的"updater 签名失败处整个中断，产出一个跑不起来的 .app

状态：✅ 已归档（commit 见实施记录），2026-09-17
级别：L1（每次本地真机验证都复现；产出物看起来成功、实际无法启动）
关联: 无

## 可接段

context:
- 2026-09-17 做 NET-24 真机验收时踩到，当场手工绕过才完成验证。
- `tools/bundle-desktop-macos.sh` 六步：①sidecar ②`tauri build --no-bundle`
  ③`tauri bundle` ④把 `lib/` 塞进 `.app/Contents/MacOS/lib` ⑤重签 ⑥dmg。
- 脚本头部 `set -euo pipefail`（第 22 行）。
- `apps/desktop/src-tauri/tauri.conf.json:45` 是 `"createUpdaterArtifacts": true`，
  所以步骤③末尾一定会去签 updater 包；本地没有 `TAURI_SIGNING_PRIVATE_KEY`
  时它**必然**失败并让 `pnpm tauri bundle` 以非零码退出。
- CI 调用点：`.github/workflows/release.yml:244`
  `tools/bundle-desktop-macos.sh /tmp/rel /tmp/rel "$IDENTITY"`。

问题:
本地（无凭据路径）跑这个脚本时，步骤③在 `.app` **已经产出之后**因为
updater 签名失败而返回非零码 → `set -e` 让脚本当场中断 → **步骤④⑤⑥全部
没跑**。

结果是一个**残缺但看起来存在**的 `.app`：`Contents/MacOS/` 下只有
`p-pass-desktop` 和 `ppf-daemon`，**没有 `lib/`**。而 bundle 后的 daemon
其 rpath 是 `@executable_path/lib`，缺了它根本起不来。脚本最后打印的是
一堆看似正常的输出 + 一行 updater 错误，很容易被当成"签名步跳过了，其余
没问题"。

AGENTS.md 明写无凭据路径下签名失败是**预期行为、不是待修的 bug**——
问题不在它失败，而在它**连累了后面三步**。

期望行为:
- 本地（无 `TAURI_SIGNING_PRIVATE_KEY`）跑完脚本，直接得到一个**可运行**的
  `.app`（含 `lib/`、已 ad-hoc 重签），不需要任何手工补救。
- CI（有 identity/签名密钥）路径**维持严格**：那里 `tauri bundle` 失败就是
  真失败，必须照旧中断。
- 无论哪条路径，`.app` 不存在都必须显式失败，不许闷头往下走。

验收标准:
- [x] **[E1]** 本机无 `TAURI_SIGNING_PRIVATE_KEY` 跑
      `tools/bundle-desktop-macos.sh <rel> <dmg_out>` → 退出码 0，且
      `<app>/Contents/MacOS/lib` 存在、`codesign --verify --deep --strict`
      通过、`<app>/Contents/MacOS/ppf-daemon --version` 能打印版本
- [x] **[E2]** 反证：把步骤④的 `cp -R "$REL/lib"` 临时去掉 → 上一条必须变红
      （证明验收判据真的在查 `lib/`，不是只看退出码）
- [x] **[E1]** 设了 `TAURI_SIGNING_PRIVATE_KEY`（或传了真 identity）时
      `tauri bundle` 失败仍然中断——不许把 CI 的严格性一起放宽
- [x] **[E1]** `.app` 未产出时显式失败并给出可读原因

范围:
- 只准动：`tools/bundle-desktop-macos.sh`
- 不准动：`tauri.conf.json` 的 `createUpdaterArtifacts`（改它会影响
  release.yml 真发版的 updater 资产，属 UPD-01 范围）；
  `tools/bundle-macos.sh`；`.github/workflows/release.yml` 的调用形式

阻塞与依赖:
无。

## 备注

**验收人定调（2026-09-17）**：

> 本地构建是开发环境，可以不用签名公证，也不用做很仔细的 CI/CD 验证。
> 项目必须先讲究快速，能够快速验证之后，真正构建的时候再去严格控制
> 测试范围。

据此，本卡顺带把**本地路径的 dmg 步骤默认跳过**（步骤⑥ 的 hdiutil +
挂载 + AppleScript 布局对狗粮验证零价值，只拖慢每一轮）：ad-hoc 身份
（`IDENTITY == "-"`）时默认不出 dmg，需要时用 `PPF_BUNDLE_DMG=1` 显式
打开；传了真 identity 的 CI 路径行为一字不变。这是本卡唯一的行为变更，
在此显式登记而不是夹带。

## 实施记录（2026-09-17）

**改动两处，都在 `tools/bundle-desktop-macos.sh`（与「范围」一致）：**

1. **步骤③ 不再无差别中断**。`pnpm tauri bundle` 用 `set +e` 包住取退出码，
   然后按凭据分流：有 `TAURI_SIGNING_PRIVATE_KEY` **或**传了真 identity →
   失败即 `FATAL` 退出（CI 严格性一字未放宽）；两者都没有 → 打 warn 继续，
   因为 updater 签名失败在无凭据路径是 AGENTS.md 明写的预期行为。两条路径
   之后都仍要过原有的 `[ -d "$APP" ]` 断言。
2. **步骤⑥ 本地默认跳过 dmg**。`IDENTITY == "-"` 且未设 `PPF_BUNDLE_DMG=1`
   时直接打印 `.app` 路径并 `exit 0`。传真 identity 的 CI 路径行为不变。

### 验收证据

**[E1] 本地无凭据路径**：`tools/bundle-desktop-macos.sh <rel> <dmg_out>`
→ **退出码 0**；`.app/Contents/MacOS/lib` **6 个**；
`codesign --verify --deep --strict` 通过；
`.app/Contents/MacOS/ppf-daemon --version` 打印 `P-Pass daemon 0.5.4-test.5`。
脚本输出里能看到 `warn: tauri bundle 退出码 1 …继续` 后接
`── 4. embed lib/` / `── 5. re-sign` / `── 6. dmg 跳过`。

**[E2] 反证（真跑，已还原）**：把步骤④的 `cp -R "$REL/lib" ...` 注释掉后重跑
→ `lib/` 不存在，且 `ppf-daemon --version` 直接
`dyld: Library not loaded: @executable_path/lib/libheif.1.dylib`。
⚠️ **此时脚本退出码仍是 0** —— 这恰好证明本卡的验收判据不能只看退出码，
必须查 `lib/` 与 daemon 能否真的启动（也正是原 bug 能瞒过人的原因）。

**[E1] CI 严格性**：传 `"Developer ID Application: FAKE"` 作第三参（模拟带
凭据构建）→ 脚本打印
`FATAL: tauri bundle 失败（退出码 1），且本次是带凭据的构建——不容忍，这是真失败。`
并以**退出码 1** 终止。同一命令去掉 identity → 退出码 0。两者对照成立。

**[E1] `.app` 未产出**：原有 `[ -d "$APP" ] || { echo "FATAL: ..."; exit 1; }`
断言保留在两条分流之后，未被本次改动绕过。

**未做**：`tauri.conf.json` 的 `createUpdaterArtifacts` 一字未动（改它会波及
release.yml 真发版的 updater 资产，属 UPD-01 范围，卡面「不准动」已列明）。
