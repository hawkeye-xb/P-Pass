import Foundation
import Photos
import ExtensionFoundation
import os

/// com.apple.photos.background-upload 扩展。process() 被调度时：
/// 1. 列出并确认（acknowledge）已结束的 job，打出状态、回执头、错误（第 7 问）；
/// 2. 给最多 3 张还没建过 job 的照片建 job，目的地 http://127.0.0.1:<port>，分别用 PUT+自定义头 / POST / 自定义方法 PATCH（第 2、5 问）。
let extLog = Logger(subsystem: "com.hawkeyexb.ppass.bgspike", category: "extension")

@main
struct UploadExtension: PHBackgroundResourceUploadExtension {
    init() {
        extLog.notice("SPIKE ext init pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
    }

    func process() -> PHBackgroundResourceUploadProcessingResult {
        extLog.notice("SPIKE ext process() called jobLimit=\(PHAssetResourceUploadJob.jobLimit, privacy: .public)")
        SpikeJobs.dump(prefix: "ext")
        let library = PHPhotoLibrary.shared()

        let finished = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
        if finished.count > 0 {
            do {
                try library.performChangesAndWait {
                    finished.enumerateObjects { job, _, _ in
                        PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge()
                    }
                }
                extLog.notice("SPIKE ext acknowledged \(finished.count, privacy: .public)")
            } catch {
                let ns = error as NSError
                extLog.error("SPIKE ext acknowledge failed \(ns.domain, privacy: .public)#\(ns.code, privacy: .public)")
            }
        }

        let defaults = UserDefaults.standard
        var done = Set(defaults.stringArray(forKey: "spike.jobbed") ?? [])
        let port = (Bundle.main.object(forInfoDictionaryKey: "SpikePort") as? String) ?? "8765"
        let methods = ["PUT", "POST", "PATCH"]
        var created = 0
        let assets = PHAsset.fetchAssets(with: nil)
        assets.enumerateObjects { asset, _, stop in
            guard created < methods.count, !done.contains(asset.localIdentifier),
                  let resource = PHAssetResource.assetResources(for: asset).first else { return }
            let method = methods[created]
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/upload/\(method.lowercased())?name=\(resource.originalFilename)")!)
            request.httpMethod = method
            request.setValue("lease-\(created)", forHTTPHeaderField: "X-PPass-Lease")
            request.setValue("application/x-ppass-test", forHTTPHeaderField: "Content-Type")
            do {
                try library.performChangesAndWait {
                    _ = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: request, resource: resource)
                }
                extLog.notice("SPIKE ext created job method=\(method, privacy: .public) asset=\(resource.originalFilename, privacy: .public)")
                done.insert(asset.localIdentifier)
                created += 1
            } catch {
                let ns = error as NSError
                extLog.error("SPIKE ext create job failed method=\(method, privacy: .public) \(ns.domain, privacy: .public)#\(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public)")
                stop.pointee = true
            }
        }
        defaults.set(Array(done), forKey: "spike.jobbed")
        extLog.notice("SPIKE ext process() returning completed created=\(created, privacy: .public)")
        return .completed
    }

    func notifyTermination() {
        extLog.notice("SPIKE ext notifyTermination()")
    }
}
