# iOS 真机取证与安装（#347）

状态：骨架。「已实测」是在本机跑过并看到输出的；「待实测」是计划用的命令，真机跑通后再改成已实测。

## 已实测

- 列真机：`xcrun devicectl list devices`（看到 `available (paired)` 才能装）。
- 真机构建：`cd apps/ios && xcodegen generate && xcodebuild build -project PPass.xcodeproj -scheme PPass -configuration Debug -destination "id=<devicectl 标识>" -derivedDataPath build/DerivedDataDevice -allowProvisioningUpdates`。
  签名团队写在 `apps/ios/project.yml` 的 `DEVELOPMENT_TEAM[sdk=iphoneos*]`（一处），只对真机 SDK 生效。
- 签名前置条件（缺任何一项都会在这一步失败，报错原文：`No Accounts: Add a new account in Accounts settings` / `No profiles for 'com.hawkeyexb.ppass' were found`）：
  Xcode 的 Settings → Accounts 里登录了该团队的 Apple ID。本机钥匙串里只有该团队的 Developer ID 证书，没有 Apple Development 证书，
  Xcode 里也没有账号，所以自动签名无法创建开发证书与描述文件——这一步必须由用户在 Xcode 里登录，agent 不能代填 Apple ID 凭据。

## 待实测

- 安装：`xcrun devicectl device install app --device <id> <PPass.app>`
- 启动（带环境变量）：`xcrun devicectl device process launch --device <id> --terminate-existing --environment-variables '{"K":"V"}' com.hawkeyexb.ppass`
- 拉 App 容器：`xcrun devicectl device info files --device <id> --domain-type appDataContainer --domain-identifier com.hawkeyexb.ppass`，
  `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.hawkeyexb.ppass --source <设备内路径> --destination <本机路径>`
- 设备日志：`xcrun devicectl device ... ` / `log collect --device <id> --last 5m --output <x.logarchive>`，再 `log show --archive <x.logarchive> --predicate 'eventMessage CONTAINS "[PPass]"'`
