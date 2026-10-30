# 更新包篡改测试夹具（#1267）

`update_install.rs` 的 `tampered_update_package_is_rejected_by_the_updater_signature_check`
用这三份文件：

- `test.key.pub`：一次性测试公钥（`tauri signer generate --ci -p ""` 生成），私钥没有保留，
  与发版公钥无关。
- `pkg.bin`：被签名的内容。
- `pkg.bin.sig`：`tauri signer sign --app-version 99.0.0` 对 `pkg.bin` 的签名。

要换夹具就三份一起重新生成。
