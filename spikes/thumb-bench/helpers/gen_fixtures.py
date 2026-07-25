#!/usr/bin/env python3
"""Fast fixture generator: 80 JPEG + 60 HEIC (via sips) + 60 MP4 (one generated, copied)."""
import os, subprocess, sys, random, tempfile

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/thumb-fixtures"
os.makedirs(OUT, exist_ok=True)
random.seed(42)

def mk_rgb_png(path, w, h, r, g, b):
    """Minimal solid-color PNG."""
    import struct, zlib
    raw = b""
    for y in range(h):
        raw += b"\x00"
        for x in range(w):
            raw += bytes([r, g, b])
    def chunk(ct, data):
        c = ct + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

print("Generating JPEGs...")
for i in range(80):
    w = random.choice([100, 200, 400, 800, 1200, 1920, 4000])
    h = random.choice([100, 150, 300, 600, 800, 1080, 3000])
    r, g, b = random.randint(0,255), random.randint(0,255), random.randint(0,255)
    tmp = f"/tmp/_thumb_jpg_{os.getpid()}.png"
    out = os.path.join(OUT, f"img_{i:04d}.jpg")
    mk_rgb_png(tmp, w, h, r, g, b)
    subprocess.run(["sips", "-s", "format", "jpeg", tmp, "--out", out], check=True, capture_output=True)
    os.unlink(tmp)

print("Generating HEICs...")
for i in range(80, 140):
    w = random.choice([100, 200, 400, 800, 1200, 1920])
    h = random.choice([100, 150, 300, 600, 800, 1080])
    r, g, b = random.randint(0,255), random.randint(0,255), random.randint(0,255)
    tmp = f"/tmp/_thumb_heic_{os.getpid()}.png"
    out = os.path.join(OUT, f"img_{i:04d}.heic")
    mk_rgb_png(tmp, w, h, r, g, b)
    subprocess.run(["sips", "-s", "format", "heic", tmp, "--out", out], check=True, capture_output=True)
    os.unlink(tmp)

# Generate ONE tiny MP4 via Swift, then copy
print("Generating base MP4...")
swift_src = f'''
import AVFoundation
let u = URL(fileURLWithPath: "/tmp/_thumb_base.mp4")
let sz = CGSize(width: 320, height: 240)
guard let w = try? AVAssetWriter(url: u, fileType: .mp4) else {{ exit(1) }}
let s: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240]
let inp = AVAssetWriterInput(mediaType: .video, outputSettings: s)
inp.expectsMediaDataInRealTime = true
w.add(inp); w.startWriting(); w.startSession(atSourceTime: .zero)
var pb: CVPixelBuffer?
CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32ARGB, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey: 320, kCVPixelBufferHeightKey: 240] as CFDictionary, &pb)
let sem = DispatchSemaphore(value: 0); var n = 0; let lim = 60
inp.requestMediaDataWhenReady(on: DispatchQueue.global()) {{
    while inp.isReadyForMoreMediaData && n < lim {{
        if let p = pb {{
            CVPixelBufferLockBaseAddress(p, []); let ptr = CVPixelBufferGetBaseAddress(p)!; let bpr = CVPixelBufferGetBytesPerRow(p)
            for y in 0..<240 {{ let row = ptr.advanced(by: y*bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<320 {{ row[x*4]=UInt8((n*11)%256); row[x*4+1]=UInt8((n*7)%256); row[x*4+2]=UInt8((n*3)%256); row[x*4+3]=255 }}
            }}
            CVPixelBufferUnlockBaseAddress(p, [])
            let pts = CMTime(value: Int64(n), timescale: 30)
            var ti = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var fd: CMVideoFormatDescription?, sb: CMSampleBuffer?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: p, formatDescriptionOut: &fd)
            if let f = fd {{ CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: p, formatDescription: f, sampleTiming: &ti, sampleBufferOut: &sb); if let s = sb {{ inp.append(s) }} }}
            n += 1
        }}
    }}
    inp.markAsFinished(); w.finishWriting {{ sem.signal() }}
}}
sem.wait()
'''
ts = f"/tmp/_mkmp4_{os.getpid()}.swift"
with open(ts, "w") as f: f.write(swift_src)
subprocess.run(["swiftc", "-O", "-o", "/tmp/_mkmp4", ts], check=True, capture_output=True)
subprocess.run(["/tmp/_mkmp4"], check=True, capture_output=True, timeout=15)
os.unlink(ts)

print("Copying MP4s...")
for i in range(140, 200):
    dst = os.path.join(OUT, f"vid_{i:04d}.mp4")
    open(dst, "wb").write(open("/tmp/_thumb_base.mp4", "rb").read())

os.unlink("/tmp/_thumb_base.mp4")
if os.path.exists("/tmp/_mkmp4"): os.unlink("/tmp/_mkmp4")

files = os.listdir(OUT)
print(f"Done: {len(files)} files in {OUT}")
for ext in [".jpg", ".heic", ".mp4"]:
    n = sum(1 for f in files if f.endswith(ext))
    print(f"  {ext}: {n}")
