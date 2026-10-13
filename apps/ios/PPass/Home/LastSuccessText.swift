import Foundation
import PPassCore

/// 「最近成功」的人话：英雄卡（带「最近成功 ·」前缀）与存储电脑详情（不带前缀）共用同一个裁决。
enum LastSuccessText {
    /// 无前缀的时间片段：刚刚 / N 分钟前 / N 小时前 / MM-dd HH:mm；从未成功 = 「还没有成功的备份」。
    static func fragment(_ ts: Int64?) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        switch HomeProjection.lastSuccess(ts: ts ?? 0, now: now) {
        case .never: return L.s("last_success_never")
        case .justNow: return L.s("last_just_now")
        case .minutesAgo(let m): return L.f("last_mins_ago", Int(m))
        case .hoursAgo(let h): return L.f("last_hours_ago", Int(h))
        case .at(let ts):
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            return f.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
        }
    }

    /// 英雄卡一行：从未成功时本身就是整句，其余套「最近成功：…」。
    static func line(_ ts: Int64?) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if case .never = HomeProjection.lastSuccess(ts: ts ?? 0, now: now) { return L.s("last_success_never") }
        return L.f("dog_last_success", fragment(ts))
    }
}
