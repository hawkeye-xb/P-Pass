import Photos
import os

/// App 与扩展共用：把各 action 下的 job 打出来。
enum SpikeJobs {
    static func dump(prefix: String) {
        let logger = Logger(subsystem: "com.hawkeyexb.ppass.bgspike", category: prefix)
        for (name, action) in [("acknowledge", PHAssetResourceUploadJob.Action.acknowledge), ("retry", .retry)] {
            let jobs = PHAssetResourceUploadJob.fetchJobs(action: action, options: nil)
            logger.notice("SPIKE \(prefix, privacy: .public) jobs action=\(name, privacy: .public) count=\(jobs.count, privacy: .public)")
            jobs.enumerateObjects { job, _, _ in
                let ns = job.error.map { e in e as NSError }
                logger.notice("SPIKE \(prefix, privacy: .public) job id=\(job.localIdentifier, privacy: .public) state=\(job.state.rawValue, privacy: .public) type=\(job.type.rawValue, privacy: .public) dest=\(job.destination.httpMethod ?? "-", privacy: .public) \(job.destination.url?.absoluteString ?? "-", privacy: .public) responseHeaders=\(String(describing: job.responseHeaderFields), privacy: .public) error=\(ns.map { e in "\(e.domain)#\(e.code) \(e.localizedDescription)" } ?? "-", privacy: .public)")
            }
        }
    }
}
