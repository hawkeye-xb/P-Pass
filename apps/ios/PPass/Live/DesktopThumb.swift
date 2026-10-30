import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 电脑发来的缩略图（对位 Android `DesktopThumb.kt`）：只认 JPEG，宽高都不超过 1024（电脑生成的最大档）。
/// 先看魔数，再用 `CGImageSource` 只读文件头里的格式和宽高，合格了才解码；不合格的不解码、抛出原因，
/// 由调用方写日志并显示占位。手机本机相册走 `PHImageManager`，不经过这里。
enum DesktopThumb {
    static let maxEdge = 1024

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case notJpeg, unreadable, tooLarge(width: Int, height: Int)
        var description: String {
            switch self {
            case .notJpeg: return "not JPEG"
            case .unreadable: return "unreadable header"
            case let .tooLarge(w, h): return "too large \(w)x\(h)"
            }
        }
    }

    /// JPEG 文件以 SOI（FF D8）开头，紧跟一个标记段（FF xx）。
    static func hasJpegMagic(_ data: Data) -> Bool {
        data.count >= 3 && data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF])
    }

    /// 纯判定：魔数 + 文件头里读出的类型与宽高。
    static func judge(magicOk: Bool, typeIdentifier: String?, width: Int, height: Int) -> Rejection? {
        if !magicOk || (typeIdentifier != nil && typeIdentifier != UTType.jpeg.identifier) { return .notJpeg }
        if width <= 0 || height <= 0 { return .unreadable }
        if width > maxEdge || height > maxEdge { return .tooLarge(width: width, height: height) }
        return nil
    }

    static func decode(_ data: Data) throws -> UIImage {
        guard hasJpegMagic(data) else { throw Rejection.notJpeg } // 魔数不对，连文件头都不交给解码器
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { throw Rejection.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if let rejection = judge(magicOk: true, typeIdentifier: CGImageSourceGetType(source) as String?, width: width, height: height) {
            throw rejection
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Rejection.unreadable }
        return UIImage(cgImage: image)
    }
}
