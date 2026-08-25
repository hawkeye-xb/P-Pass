# REL-04 update manifest 的下载地址在镜像成功之前就写死，镜像失败则带坏 manifest 出门　级别 L2

> ⬜ 状态：未开工（R2 镜像已于 2026-08-25 整步撤除，本卡是**重开镜像的前置条件**）
> 级别：L2 · 阻塞：无（但只有决定重开 R2 镜像时才需要做）

## 问题

`release.yml` 的 release job 步骤顺序是：

```
5. Compose update manifest   ← 这里决定下载地址
6. Sign update manifest      ← 签名（此后不可手改）
7. Create draft release
8. Upload release assets     ← manifest 已上传
9. Auto-publish test tags
10. Mirror release assets to R2   ← 镜像真正发生
```

第 5 步的地址是这么定的：

```bash
ASSET_BASE="https://github.com/.../releases/download/${TAG}"
if [ "$HAS_CF_TOKEN" = "true" ]; then
  ASSET_BASE="https://dl.p-pass.hawkeye-xb.com/releases/${TAG}"
fi
```

**判据是「token 存在」，而不是「镜像成功」。** 两件事之间隔着五步。

2026-08-25 实测后果（`v0.4.0-test.1`）：第 10 步 `403 Forbidden`，但第 5–8 步
早已把一份指向镜像域的 manifest **签名并上传**进 release 了。于是：

- 手动下载不受影响（GitHub 直链的资产都在，签名公证都真做了）
- **自动更新拿到一个指向不存在文件的 manifest**
- **补不了**——manifest 由 `UPDATE_SIGNING_KEY` 签名，手改破签名；只能重出一版

## 期望行为

镜像失败绝不产生指向镜像的 manifest。要么 manifest 指 GitHub 直链，
要么镜像已被证实成功。

## 验收标准

- [ ] 重排顺序：先镜像二进制（`continue-on-error` + 输出成功标志）→ 据标志
  决定 `ASSET_BASE` → 组装 manifest → 签名 → 单独镜像 manifest → 建 release
- [ ] 反证：注入镜像失败（如故意用无权限 token）→ manifest 的
  `platforms.*.url` **必须**是 `github.com/...`，且 release 仍正常产出
- [ ] 门控判据从「token 存在」改成「镜像实际成功」——`HAS_CF_TOKEN` 这类
  存在性检查不许再单独当作能力判据
- [ ] 实跑一次 dispatch 或 test tag 验证（改的是发布管线，不许只读 yml 报绿）

## 范围

- 只准动：`.github/workflows/release.yml`（release job 的步骤顺序与门控）
- 不准动：`tools/make-update-manifest.mjs` 的签名逻辑；客户端的 manifest 解析

## 阻塞与依赖

前置：R2 那个 403 得先解决，否则镜像永远失败、这条路径没法正向验证。
403 的排查线索见 `docs/NEXT.md`（2026-08-12 就已挂账：token
`ci-ppass-r2-mirror-worker-deploy-2026-08-12` 声称 R2 bucket 写权限精确到
`ppf-dl`，但 `wrangler@3 r2 object put` 实测 403）。

---

## 备注

**2026-08-25 用户拍板：整步撤除 R2 镜像**（「先把上传 R2 的撤走吧」），
`manifest` 恒指 GitHub 直链。所以现在**不存在这个 bug 的触发条件**——本卡
记录的是「重开镜像之前必须先修好的东西」，不是当前的活。

教训归档：**「凭据存在」不等于「能力可用」。** 这个坑在同一个步骤里犯过两次
——2026-08-12 是窄权限 token 无 `memberships` 读权限（已修，改成显式给
`account_id`），2026-08-25 是同一个 token 无 R2 写权限。存在性检查
（`secrets.X != ''`）永远只能证明「配了」，证不了「配对了」。
