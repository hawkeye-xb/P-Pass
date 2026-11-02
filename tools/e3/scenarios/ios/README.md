# iOS 场景（TODO）

接口与 macOS / Android 相同。计划手段：本机 `xcodebuild` 开发签名 → `devicectl` 安装到 iPhone →
界面用 XCUITest 真机跑（`xcodebuild test -destination id=<udid>`），判定读测试结果与 App 落盘日志
（现有 `tools/ios/e3-judge.sh` 的拉日志 + 按阶段判定可直接收编为各场景的 judge）。
设备 UDID 写在本机 `e3.env` 的 `E3_IOS_UDID`；设备锁 `tools/e3/lock ios`。
