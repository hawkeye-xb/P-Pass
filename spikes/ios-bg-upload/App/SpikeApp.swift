import SwiftUI
import Photos
import os

/// IOS-03（#332）spike 宿主 App。所有观察都打到 unified log（subsystem com.hawkeyexb.ppass.bgspike），
/// 由 tools/run-sim.sh 用 `log show` 收集。动作由启动参数驱动，方便 `simctl launch` 自动化：
///   --enable / --disable     调 setUploadJobExtensionEnabled
///   --create-in-app          在主 App 进程里试建一个 job（看系统是否只允许扩展建）
///   --dump                   列出各 action 下的 job 及其状态 / 回执头 / 错误
let log = Logger(subsystem: "com.hawkeyexb.ppass.bgspike", category: "app")

@main
struct SpikeApp: App {
    init() {
        Task.detached { Spike.run(arguments: ProcessInfo.processInfo.arguments) }
    }

    var body: some Scene {
        WindowGroup { Text("BgUploadSpike") }
    }
}

enum Spike {
    static func run(arguments: [String]) {
        let library = PHPhotoLibrary.shared()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        log.notice("SPIKE app start args=\(arguments.dropFirst().joined(separator: " "), privacy: .public) readWrite=\(status.rawValue, privacy: .public) extensionEnabled=\(library.uploadJobExtensionEnabled, privacy: .public) jobLimit=\(PHAssetResourceUploadJob.jobLimit, privacy: .public) assets=\(PHAsset.fetchAssets(with: nil).count, privacy: .public)")

        if arguments.contains("--enable") || arguments.contains("--disable") {
            let enable = arguments.contains("--enable")
            do {
                try library.setUploadJobExtensionEnabled(enable)
                log.notice("SPIKE app setUploadJobExtensionEnabled(\(enable, privacy: .public)) ok; now enabled=\(library.uploadJobExtensionEnabled, privacy: .public)")
            } catch {
                let ns = error as NSError
                log.error("SPIKE app setUploadJobExtensionEnabled(\(enable, privacy: .public)) failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            }
        }

        if arguments.contains("--create-in-app") {
            guard let asset = PHAsset.fetchAssets(with: nil).firstObject,
                  let resource = PHAssetResource.assetResources(for: asset).first else {
                log.error("SPIKE app create-in-app: no asset")
                return
            }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(SpikeConfig.port)/upload/from-app")!)
            request.httpMethod = "PUT"
            request.setValue("lease-from-app", forHTTPHeaderField: "X-PPass-Lease")
            do {
                try library.performChangesAndWait {
                    _ = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: request, resource: resource)
                }
                log.notice("SPIKE app create-in-app ok")
            } catch {
                let ns = error as NSError
                log.error("SPIKE app create-in-app failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public)")
            }
        }

        if arguments.contains("--dump") {
            SpikeJobs.dump(prefix: "app")
        }
    }
}

enum SpikeConfig {
    static let port = 8765
}
