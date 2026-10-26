#if DEBUG
import Foundation
import PPassCore

/// 仅 DEBUG：`PPASS_E2E_RESET=1` 启动前清掉存储根（配对 / 账本 / provider 库）和钥匙串里的身份，等价于全新安装但保留系统授权。
/// 真机端到端每轮换一个新 daemon，旧账本会把「已确认」算给旧电脑，必须从空账本开始。
///
/// 存储根只认 `LiveBackend.resolveRoot` 的结果：正常是 App Group 容器里的 `PPass/`，降级才是 Application Support/PPass。
/// 复位与真实写入同一个来源，不自己拼路径（之前写死 Application Support/PPass，App Group 里的真实数据一点没动）。
enum E2EReset {
    static func wipe(root: StorageRoot, identity: IdentitySecretStore, fileManager: FileManager = .default, logger: CoreLogger) {
        let kind = root.isDegraded ? "app-private fallback" : "app group"
        do {
            try fileManager.removeItem(at: root.url)
            logger.log("boot: DEBUG E2E reset removed storage root \(root.url.path) (\(kind))")
        } catch {
            logger.log("boot: DEBUG E2E reset failed to remove storage root \(root.url.path) (\(kind)): \(error)")
        }
        do { try identity.delete(); logger.log("boot: DEBUG E2E reset dropped the identity key") } catch {
            logger.log("boot: DEBUG E2E reset failed to drop the identity key: \(error)")
        }
    }
}
#endif
