import AVFoundation
import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: mp4frame <input.mp4> <output.jpg>\n", stderr)
    exit(1)
}

let inputPath  = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

let inputURL = URL(fileURLWithPath: inputPath)
let asset = AVURLAsset(url: inputURL)

let semaphore = DispatchSemaphore(value: 0)
var track: AVAssetTrack?

asset.loadTracks(withMediaType: .video) { maybeTracks, _ in
    track = maybeTracks?.first
    semaphore.signal()
}
semaphore.wait()

guard let videoTrack = track else {
    fputs("No video track in \(inputPath)\n", stderr)
    exit(2)
}

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
let time = CMTime(seconds: 0, preferredTimescale: 600)

var imageRef: CGImage?
do {
    imageRef = try generator.copyCGImage(at: time, actualTime: nil)
} catch {
    fputs("Failed to generate frame: \(error)\n", stderr)
    exit(3)
}

guard let cgImage = imageRef else {
    fputs("No image generated\n", stderr)
    exit(4)
}

let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
guard let tiff = nsImage.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
    fputs("Failed to encode JPEG\n", stderr)
    exit(5)
}

do {
    try jpeg.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("Failed to write \(outputPath): \(error)\n", stderr)
    exit(6)
}
