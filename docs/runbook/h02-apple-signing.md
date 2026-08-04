# H-02 操作单：Apple 签名 + 公证凭据（用户本人，约 10-15 分钟）

> 为什么必须真人：导出证书要 macOS 钥匙串的交互授权弹窗，agent 无法代替。
> 前提：Apple Developer Program 会员（$99/年）。没有会员就先不做——家人
> 用"右键→打开"过 Gatekeeper 完全可行，H-02 只在公开发布前是硬性的。

## A. Developer ID 证书（签名用）

1. 打开 Xcode → Settings → Accounts → 登录你的 Apple ID → 选中团队 →
   Manage Certificates… → 左下角 ＋ → **Developer ID Application**。
   - 若该选项灰色：去 developer.apple.com → Certificates → ＋ →
     Developer ID Application → 按提示用「钥匙串访问 → 证书助理 →
     从证书颁发机构请求证书…」生成 CSR 文件上传 → 下载 .cer → 双击导入。
2. 打开「钥匙串访问」→ 登录钥匙串 → 我的证书 → 找到
   `Developer ID Application: <你的名字> (TEAMID)` → **右键 → 导出** →
   格式 .p12 → 设一个导出密码（记住它）→ 存到桌面 `cert.p12`。
3. 终端执行（复制 base64 到剪贴板）：
   ```bash
   base64 -i ~/Desktop/cert.p12 | pbcopy
   ```
4. GitHub 仓库 → Settings → Secrets and variables → Actions → 更新：
   - `APPLE_CERT_P12` ← 粘贴（剪贴板里的 base64）
   - `APPLE_CERT_PASSWORD` ← 第 2 步设的导出密码
5. **删掉桌面的 cert.p12**（`rm ~/Desktop/cert.p12`）。

## B. 公证凭据（notarytool 用 App Store Connect API key）

1. appstoreconnect.apple.com → 用户和访问 → 集成 → App Store Connect API →
   团队密钥 → ＋ 生成（角色选 Developer）→ **下载 .p8**（只给下载一次）→
   页面上记下 **Key ID** 和 **Issuer ID**。
2. 配 secrets：
   - `APPLE_NOTARY_KEY` ← .p8 文件的**文本内容**（`cat *.p8 | pbcopy`）
   - `APPLE_NOTARY_KEY_ID` ← Key ID
   - `APPLE_NOTARY_ISSUER` ← Issuer ID
3. 删除本地 .p8。

## C. 验证（配完告诉主会话即可，也可自己来）

1. 打一个测试 tag（如 `v0.2.0-test.N+1`）触发 Release。
2. 预期：macOS job 的 `Codesign (gated)` 和 `Notarize + staple` 两步
   从 skipped 变 **success**；release notes 的签名状态变 `macOS=yes`。
3. 下载 dmg 双击——不再有 Gatekeeper 拦截。

## 已知小坑（主会话跟进，不用你管）

- workflow 里 `notarytool --key` 需要的是 .p8 **文件路径**，而 secret 存的是
  内容——首次真跑若在 Notarize 步报错，需要在 workflow 里加一行先把内容写到
  `$RUNNER_TEMP/notary.p8`（review 已记录，报错即修）。
- 签名跑通后可顺手做 T-071 挂账：daemon 身份从明文文件迁 Keychain。
