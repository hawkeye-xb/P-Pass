// IOS-06（#313）：Swift 经 XCFramework 调 Rust 导出的 BLAKE3 / proto 编解码 / provider /
// 控制面客户端。本文件里没有任何 BLAKE3 或帧编解码的 Swift 实现——只有输入数据的生成与比对。
import Foundation
import PPassCore
import PPassTransport
import XCTest

final class TransportFFITests: XCTestCase {

    // MARK: - BLAKE3 × tests/blake3-vectors.json

    /// 模拟器进程能直接读宿主文件系统：从本文件位置向上找仓库根。
    private func repoFile(_ relative: String) throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("\(relative) not found above \(#filePath)")
    }

    /// 与 Rust 向量生成器（crates/core-index/examples/gen_blake3_vectors.rs）及
    /// Kotlin Blake3VectorTest 同一个 xorshift：生成**输入字节**，不涉及哈希。
    private func xorshiftMiB(seed: UInt64) -> Data {
        var out = Data(capacity: 1 << 20)
        var s = seed
        while out.count + 8 <= 1 << 20 {
            s ^= s << 13
            s ^= s >> 7
            s ^= s << 17
            withUnsafeBytes(of: s.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    func testBlake3MatchesSharedVectors() throws {
        let url = try repoFile("tests/blake3-vectors.json")
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        XCTAssertEqual(vectors.count, 3)
        var checked = 0
        for v in vectors {
            let name = v["name"] as! String
            let expected = v["blake3_hex"] as! String
            let data: Data
            switch name {
            case "empty": data = Data()
            case "hello": data = Data("hello".utf8)
            case "photo_bytes_1MiB_xorshift_5EED202607310053":
                data = xorshiftMiB(seed: 0x5EED_2026_0731_0053)
            default:
                XCTFail("unknown vector \(name)"); continue
            }
            XCTAssertEqual(data.count, v["len"] as! Int, name)
            XCTAssertEqual(blake3Hex(data: data), expected, "\(name) (one shot)")

            let hasher = Blake3Hasher()
            var offset = 0
            while offset < data.count {
                let end = min(offset + 64 * 1024 + 7, data.count)
                hasher.update(data: data.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(hasher.finalizeHex(), expected, "\(name) (incremental)")

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("blake3-\(name)-\(UUID().uuidString)")
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertEqual(try blake3FileHex(path: file.path), expected, "\(name) (file)")
            print("BLAKE3 vector \(name): \(expected) ✓")
            checked += 1
        }
        XCTAssertEqual(checked, 3)
    }

    // MARK: - proto 编解码

    func testFlowFetchRequestEncodedThroughProtoDecodesFieldForField() throws {
        let request = ProtoFlowFetchRequest(
            queueSequence: 9_007_199_254_740_993,  // > 2^53：确认 u64 不经过浮点
            pairingEpoch: "epoch-2026-10-12",
            leaseToken: "lease-7f3a",
            contentHash: String(repeating: "ab", count: 32),
            fileName: "IMG_0001 照片.HEIC",
            mediaType: "image/heic",
            provider: "blobaa…ticket",
            captureAtMs: 1_790_243_013_123,
            sizeBytes: 532_102
        )
        let frame = try encodeFlowFetchRequest(request: request)

        // 帧头：u32 LE = 负载字节数（crates/proto/src/codec.rs）。
        XCTAssertGreaterThan(frame.count, 4)
        let len = frame.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        XCTAssertEqual(len, frame.count - 4)

        // crates/proto 解码回来，逐字段相等。
        let decoded = try decodeFlowFetchRequest(frame: frame)
        XCTAssertEqual(decoded.queueSequence, request.queueSequence)
        XCTAssertEqual(decoded.pairingEpoch, request.pairingEpoch)
        XCTAssertEqual(decoded.leaseToken, request.leaseToken)
        XCTAssertEqual(decoded.contentHash, request.contentHash)
        XCTAssertEqual(decoded.fileName, request.fileName)
        XCTAssertEqual(decoded.mediaType, request.mediaType)
        XCTAssertEqual(decoded.provider, request.provider)
        XCTAssertEqual(decoded.captureAtMs, request.captureAtMs)
        XCTAssertEqual(decoded.sizeBytes, request.sizeBytes)
        XCTAssertEqual(decoded, request)

        // 线上 JSON 用的是 proto 的 snake_case 字段名——Swift 侧 Codable 要对齐的就是它。
        let json = try JSONSerialization.jsonObject(
            with: Data(try decodeFrameJson(frame: frame).utf8)) as! [String: Any]
        XCTAssertEqual(
            Set(json.keys),
            ["queue_sequence", "pairing_epoch", "lease_token", "content_hash", "file_name",
             "media_type", "provider", "capture_at_ms", "size_bytes"])
        XCTAssertEqual(json["file_name"] as? String, request.fileName)
        print("FlowFetchRequest frame \(frame.count) bytes, fields equal ✓")
    }

    /// App 侧真正会走的路：PPassCore 的 Codable FlowFetchRequest → JSONEncoder → Rust 的
    /// proto 帧编码 → crates/proto 按 FlowFetchRequest 类型解码，逐字段相等。
    func testPPassCoreFlowFetchRequestJsonDecodesInCratesProto() throws {
        let request = PPassCore.FlowFetchRequest(
            queueSequence: 9_007_199_254_740_993,
            pairingEpoch: "epoch-2026-10-12",
            leaseToken: "lease-42",
            contentHash: String(repeating: "cd", count: 32),
            fileName: "IMG_0002 视频.MOV",
            mediaType: "video/quicktime",
            provider: "blob-ticket",
            captureAtMs: -1,
            sizeBytes: 4_294_967_297
        )
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let decoded = try decodeFlowFetchRequest(frame: try encodeFrameJson(json: json))
        XCTAssertEqual(decoded.queueSequence, request.queueSequence)
        XCTAssertEqual(decoded.pairingEpoch, request.pairingEpoch)
        XCTAssertEqual(decoded.leaseToken, request.leaseToken)
        XCTAssertEqual(decoded.contentHash, request.contentHash)
        XCTAssertEqual(decoded.fileName, request.fileName)
        XCTAssertEqual(decoded.mediaType, request.mediaType)
        XCTAssertEqual(decoded.provider, request.provider)
        XCTAssertEqual(decoded.captureAtMs, request.captureAtMs)
        XCTAssertEqual(decoded.sizeBytes, request.sizeBytes)
        print("PPassCore.FlowFetchRequest JSON → crates/proto decode, fields equal ✓")
    }

    func testJsonFrameRoundTripAndRejectsTruncatedFrame() throws {
        let frame = try encodeFrameJson(json: #"{"id":"1","method":"hello","params":{}}"#)
        let back = try JSONSerialization.jsonObject(with: Data(try decodeFrameJson(frame: frame).utf8))
            as! [String: Any]
        XCTAssertEqual(back["method"] as? String, "hello")
        XCTAssertThrowsError(try decodeFrameJson(frame: frame.prefix(frame.count - 1)))
        XCTAssertEqual(protoVersion(), 1)
    }

    // MARK: - provider

    func testProviderImportsAndHoldsAFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try Provider(root: root.path)

        let bytes = xorshiftMiB(seed: 0x1234_5678_9ABC_DEF0)
        let file = root.appendingPathExtension("src")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let imported = try provider.importFile(path: file.path)
        XCTAssertEqual(imported.hash, blake3Hex(data: bytes), "provider 的内容哈希就是 BLAKE3")
        XCTAssertEqual(imported.size, UInt64(bytes.count))
        XCTAssertFalse(imported.byReference)
        XCTAssertEqual(imported.fallback, "no_path")
        XCTAssertEqual(provider.transferStatus(), .noLease)

        XCTAssertNoThrow(try provider.setAllowedPeer(nodeId: String(repeating: "cd", count: 32)))
        XCTAssertThrowsError(try provider.setAllowedPeer(nodeId: "not-a-node-id"))
        XCTAssertThrowsError(try provider.serve(hash: String(repeating: "00", count: 32))) { error in
            guard case FfiError.NotImported = error else {
                return XCTFail("expected NotImported, got \(error)")
            }
        }
        try provider.release(hash: imported.hash)
        provider.close()
    }

    // MARK: - 控制面客户端 × 本机 daemon

    /// tools/ios/test-transport-ffi.sh 起一个 fake HOME、端口 0 的 daemon，把它的 PeerAddr
    /// token 经 TEST_RUNNER_PPASS_DAEMON_TOKEN 传进来。没有 daemon 时跳过，除非
    /// PPASS_REQUIRE_DAEMON=1（脚本里这样设，跳过就算失败）。
    func testCtrlClientHelloAgainstLocalDaemon() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["PPASS_DAEMON_TOKEN"], !token.isEmpty else {
            if env["PPASS_REQUIRE_DAEMON"] == "1" {
                return XCTFail("PPASS_DAEMON_TOKEN missing but PPASS_REQUIRE_DAEMON=1")
            }
            throw XCTSkip("no local daemon (run tools/ios/test-transport-ffi.sh)")
        }
        let client = try CtrlClient.bind(
            config: CtrlConfig(secretKey: nil, relayUrls: [], offline: true, bindTimeoutMs: 0))
        defer { client.close() }
        XCTAssertEqual(try client.nodeId().count, 64)

        let reply = try client.call(peerToken: token, method: "hello", paramsJson: "{}", timeoutMs: 0)
        let resp = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
        XCTAssertEqual(resp["ok"] as? Bool, true, reply)
        let result = try XCTUnwrap(resp["result"] as? [String: Any], reply)
        XCTAssertEqual(result["proto_ver"] as? Int, Int(protoVersion()), reply)
        XCTAssertNotNil(result["capabilities"] as? [String], reply)
        print("ctrl hello reply: \(reply)")

        // 未配对的 ephemeral 身份调需要配对的方法：daemon 的鉴权检查点必须拒绝。
        let denied = try client.call(peerToken: token, method: "diag.status", paramsJson: "{}", timeoutMs: 0)
        let deniedResp = try JSONSerialization.jsonObject(with: Data(denied.utf8)) as! [String: Any]
        XCTAssertEqual(deniedResp["ok"] as? Bool, false, denied)
        print("ctrl diag.status (unpaired) reply: \(denied)")
    }
}
