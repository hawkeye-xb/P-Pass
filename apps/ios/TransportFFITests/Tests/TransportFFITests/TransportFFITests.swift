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

    // MARK: - 配对链接（Rust transport::parse_pair_link，Swift 不写第二份）

    func testPairLinkParsedByRust() throws {
        // 合法 NodeId 必须是曲线上的点：借一个 ephemeral 控制面端点的 NodeId。
        let client = try CtrlClient.bind(
            config: CtrlConfig(secretKey: nil, relayUrls: [], offline: true, bindTimeoutMs: 0))
        defer { client.close() }
        let node = try client.nodeId()

        let link = try parsePairLink(
            link: "ppf://pair?node=\(node)&t=0123456789abcdef01234567&r=https://relay.example\n")
        XCTAssertEqual(link.nodeId, node)
        XCTAssertEqual(link.token, "0123456789abcdef01234567")
        XCTAssertEqual(link.relayUrl.map { $0.hasPrefix("https://relay.example") }, true)
        XCTAssertFalse(link.peerToken.isEmpty)

        let bare = try parsePairLink(link: "ppf://pair?node=\(node)&t=deadbeef")
        XCTAssertNil(bare.relayUrl)
        XCTAssertEqual(bare.token, "deadbeef")

        XCTAssertThrowsError(try parsePairLink(link: "https://example.com/?node=x")) { error in
            guard case FfiError.InvalidArgument = error else {
                return XCTFail("expected InvalidArgument, got \(error)")
            }
        }
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

        // #963：未配对身份发 timeline.subscribe——流式调用收到的第一帧就是拒绝应答，随后流结束。
        let rec = StreamRecorder()
        let handle = try client.openStream(peerToken: token, method: "timeline.subscribe", paramsJson: "{}",
                                           connectTimeoutMs: 0, listener: rec)
        defer { handle.cancel() }
        try waitFor(15, "unpaired subscription closes") { rec.closed != nil }
        let first = try XCTUnwrap(rec.frames.first, "the rejection reply is the first frame")
        XCTAssertEqual(first["ok"] as? Bool, false, "\(first)")
        print("ctrl timeline.subscribe (unpaired): frames=\(rec.frames) closed=\(String(describing: rec.closed))")
    }

    // MARK: - G2 模拟器版（IOS-07 #334）：provider 挂起前后 → 本机隔离 daemon 拉走一张 → 凭据回来

    private struct PrintLogger: CoreLogger {
        func log(_ message: String) { print("core-log: \(message)") }
    }

    /// 一次控制面调用，返回 `Resp` 信封（JSON 对象）。
    private func ctrl(_ client: CtrlClient, _ peer: String, _ method: String,
                      _ params: [String: Any], timeoutMs: UInt64 = 0) throws -> [String: Any] {
        let body = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        let reply = try client.call(peerToken: peer, method: method, paramsJson: body, timeoutMs: timeoutMs)
        return try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
    }

    /// [dir] 下所有普通文件（相对路径 → 字节数），用来贴「store 目录列表」。
    private func listing(_ dir: URL) -> [String: Int] {
        // 宿主的 /var 是 /private/var 的软链：两边都过一遍 resolvingSymlinksInPath 再切前缀。
        let dir = dir.resolvingSymlinksInPath()
        var out: [String: Int] = [:]
        guard let it = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return out }
        for case let url as URL in it {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true {
                let full = url.resolvingSymlinksInPath().path
                out[String(full.dropFirst(dir.path.count + 1))] = v?.fileSize ?? 0
            }
        }
        return out
    }

    private func waitFor(_ seconds: Double, _ what: String, _ cond: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try cond() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("timed out after \(seconds)s waiting for \(what)")
        throw XCTSkip("aborting after timeout: \(what)")
    }

    func testG2ProviderServesOnePhotoToLocalDaemonAcrossSuspension() throws {
        let env = ProcessInfo.processInfo.environment
        guard let linkText = env["PPASS_PAIR_LINK"], let directToken = env["PPASS_DAEMON_TOKEN"],
              let e2e = env["PPASS_E2E_DIR"].map(URL.init(fileURLWithPath:)),
              let library = env["PPASS_DAEMON_LIBRARY"].map(URL.init(fileURLWithPath:)) else {
            if env["PPASS_REQUIRE_DAEMON"] == "1" { return XCTFail("G2 env missing (tools/ios/test-transport-ffi.sh)") }
            throw XCTSkip("no local daemon (run tools/ios/test-transport-ffi.sh)")
        }
        let suspendSecs = Double(env["PPASS_SUSPEND_SECS"] ?? "5") ?? 5

        // ① 配对链接由 Rust 解析；用旧格式 &a= 把宿主给的直连地址并进来——
        //    parsePairLink 会核对地址里的 node 与链接一致（不一致就抛）。
        let link = try parsePairLink(link: linkText)
        let peer = try parsePairLink(link: "ppf://pair?node=\(link.nodeId)&t=\(link.token)&a=\(directToken)").peerToken

        // ② 配对：pair.request(ack_then_poll) 立即回执 → 轮询 pair.status 到业主点允许
        //    （宿主脚本的 owner_loop 代点）。阻塞式 pair.request 已退役（#1050）。
        let client = try CtrlClient.bind(
            config: CtrlConfig(secretKey: nil, relayUrls: [], offline: true, bindTimeoutMs: 0))
        defer { client.close() }
        let submitted = try ctrl(client, peer, "pair.request",
                                 ["token": link.token, "device_name": "iOS 模拟器 G2", "role": "member",
                                  "ack_then_poll": true],
                                 timeoutMs: 15_000)
        XCTAssertEqual(submitted["ok"] as? Bool, true, "\(submitted)")
        let ack = try XCTUnwrap(submitted["result"] as? [String: Any], "\(submitted)")
        let requestId = try XCTUnwrap(ack["request_id"] as? String, "\(submitted)")
        let ttlMs = (ack["ttl_ms"] as? NSNumber)?.doubleValue ?? 60_000
        var acceptedEpoch: String?
        let pollDeadline = Date().addingTimeInterval(ttlMs / 1000 + 5)
        while acceptedEpoch == nil {
            let st = try ctrl(client, peer, "pair.status", ["request_id": requestId], timeoutMs: 15_000)
            XCTAssertEqual(st["ok"] as? Bool, true, "\(st)")
            let reply = try XCTUnwrap(st["result"] as? [String: Any], "\(st)")
            switch reply["state"] as? String {
            case "accepted":
                acceptedEpoch = try XCTUnwrap((reply["accepted"] as? [String: Any])?["pairing_epoch"] as? String, "\(st)")
            case "pending":
                guard Date() < pollDeadline else { return XCTFail("pair.status still pending after ttl: \(st)") }
                Thread.sleep(forTimeInterval: 0.5)
            default:
                return XCTFail("pairing not accepted: \(st)")
            }
        }
        let epoch = try XCTUnwrap(acceptedEpoch)
        print("G2 paired: epoch=\(epoch.prefix(8))… phone=\(try client.nodeId().prefix(8))…")

        // ③ provider 的 FsStore 落在存储根下（模拟一个 App Group 容器；真 entitlement 是 App 线的事）。
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("g2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try StorageRoot.resolve(
            appGroupContainer: tmp.appendingPathComponent("group-container"),
            groupIdentifier: "group.test.ppass", appPrivateDirectory: tmp.appendingPathComponent("private"),
            logger: PrintLogger())
        XCTAssertEqual(root.kind, .appGroup)
        let store = root.url.appendingPathComponent("blobs", isDirectory: true)
        let provider = try Provider.withGcInterval(root: store.path, gcIntervalMs: 1_000)
        defer { provider.close() }
        try provider.setAllowedPeer(nodeId: link.nodeId)

        let photo = tmp.appendingPathComponent("IMG_G2.HEIC")
        try FileManager.default.copyItem(at: try repoFile("crates/core-media/tests/fixtures/redaction/heic.original.heic"), to: photo)
        let imported = try provider.importFile(path: photo.path)
        XCTAssertEqual(imported.hash, try blake3FileHex(path: photo.path))
        let ticket = try provider.serve(hash: imported.hash)
        let leased = listing(store)
        XCTAssertTrue(leased.keys.allSatisfy { !$0.hasPrefix("..") }, "store files stay under the root")
        XCTAssertTrue(leased.values.contains(Int(imported.size)), "the blob is a data file inside \(store.path): \(leased)")
        print("G2 store (lease held) \(store.path): \(leased.sorted { $0.key < $1.key })")

        // ④ 挂起：请宿主 SIGSTOP 本进程 suspendSecs 秒（≫ 1s 的 GC 周期），恢复后再给 GC 跑几轮。
        if suspendSecs > 0 {
        let resumed = e2e.appendingPathComponent("resumed")
        let askedAt = Date()
        try "\(getpid())".write(to: e2e.appendingPathComponent("suspend-request"), atomically: true, encoding: .utf8)
        try waitFor(suspendSecs + 60, "host SIGSTOP/SIGCONT") { FileManager.default.fileExists(atPath: resumed.path) }
        let frozen = Date().timeIntervalSince(askedAt)
        XCTAssertGreaterThanOrEqual(frozen, suspendSecs - 0.5, "the process really was frozen")
        Thread.sleep(forTimeInterval: 3.5)  // 恢复后 ≥3 个 GC 周期
        XCTAssertTrue(try provider.hasBlob(hash: imported.hash),
                      "lease TempTag must keep the blob through suspension + post-resume GC")
        print("G2 suspended ~\(Int(frozen))s, blob still present after resume + 3.5s of GC ✓")
        } else {
            print("G2 suspension step skipped (PPASS_SUSPEND_SECS=0)")
        }

        // #963：offer 之前订阅好推送，确认帧到了才 offer（桌面的 broadcast 不重放）。
        let push = StreamRecorder()
        let subscription = try client.openStream(peerToken: peer, method: "timeline.subscribe", paramsJson: "{}",
                                                 connectTimeoutMs: 0, listener: push)
        defer { subscription.cancel() }
        try waitFor(15, "subscription ack") { push.frames.first?["ok"] as? Bool == true }

        // ⑤ 交付：PPassCore 的 Codable FlowFetchRequest → flow.offer → 轮询 flow.status 到 completed。
        let request = PPassCore.FlowFetchRequest(
            queueSequence: 1, pairingEpoch: epoch, leaseToken: "lease-1", contentHash: imported.hash,
            fileName: "IMG_G2.HEIC", mediaType: "image/heic", provider: ticket,
            captureAtMs: Int64(Date().timeIntervalSince1970 * 1000), sizeBytes: Int64(imported.size))
        let offerParams = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as! [String: Any]
        let offer = try ctrl(client, peer, "flow.offer", offerParams, timeoutMs: 30_000)
        XCTAssertEqual(offer["ok"] as? Bool, true, "\(offer)")
        let tuple: [String: Any] = ["queue_sequence": 1, "pairing_epoch": epoch, "lease_token": "lease-1"]
        var receipt: [String: Any]?
        try waitFor(90, "flow.status completed") {
            let status = try ctrl(client, peer, "flow.status", tuple)
            let result = status["result"] as? [String: Any]
            if let state = result?["state"] as? String, state != "active" {
                XCTAssertEqual(state, "completed", "\(status)")
                receipt = result?["receipt"] as? [String: Any]
                return true
            }
            return false
        }
        let r = try XCTUnwrap(receipt)
        XCTAssertEqual(r["content_hash"] as? String, imported.hash)
        XCTAssertEqual(r["lease_token"] as? String, "lease-1")
        XCTAssertEqual(r["pairing_epoch"] as? String, epoch)
        XCTAssertFalse((r["receipt_id"] as? String ?? "").isEmpty)
        print("G2 receipt: \(r)")

        // #963：同一张的完成也经推送到达（flow.delivered，带这张的 queue_sequence 与同一份回执）。
        try waitFor(15, "flow.delivered push") {
            push.frames.contains { ($0["event"] as? String) == "flow.delivered"
                && (($0["data"] as? [String: Any])?["queue_sequence"] as? Int) == 1 }
        }
        let delivered = push.frames.first { ($0["event"] as? String) == "flow.delivered" }
        let pushedReceipt = (delivered?["data"] as? [String: Any])?["receipt"] as? [String: Any]
        XCTAssertEqual(pushedReceipt?["receipt_id"] as? String, r["receipt_id"] as? String)
        XCTAssertNil(push.closed, "the subscription stays open while nobody cancels it")
        print("G2 push frames: \(push.frames.map { $0["event"] as? String ?? "ack" })")

        // ⑥ 落盘：daemon 库目录（非 .ppf/）里有一个文件字节与原图相同（BLAKE3 相等）。
        var landed: String?
        // 只认库里的成品（originals/…），不认 daemon 自己的 .ppf/ 内部存储（flow-blobs 等）。
        for (rel, size) in listing(library) where size == Int(imported.size) && rel.hasPrefix(".ppf/") == false {
            let url = library.resolvingSymlinksInPath().appendingPathComponent(rel)
            if (try? blake3FileHex(path: url.path)) == imported.hash { landed = rel; break }
        }
        XCTAssertNotNil(landed, "the photo must be materialized under the daemon library \(library.path)")
        print("G2 landed on desktop: \(landed ?? "-")")

        // ⑦ 反证（IOS-07 验收 3）：放掉 lease 的 TempTag ⇒ 下一个 GC 周期后 blob 消失。
        provider.releaseRetention()
        try waitFor(15, "GC reclaims the released blob") { try !provider.hasBlob(hash: imported.hash) }
        let released = listing(store)
        XCTAssertFalse(released.values.contains(Int(imported.size)), "data file gone: \(released)")
        print("G2 store (retention released, after GC): \(released.sorted { $0.key < $1.key })")
    }
}

/// #963：记录流式调用收到的帧与结束原因（FFI 回调来自 Rust 的 runtime 线程）。
private final class StreamRecorder: StreamListener, @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [[String: Any]] = []
    private var _closed: String??

    var frames: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _frames }
    /// nil = 还没结束；.some(nil) = 对端正常结束；.some(原因)。
    var closed: String?? { lock.lock(); defer { lock.unlock() }; return _closed }

    func onFrame(json: String) {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        lock.lock(); _frames.append(obj); lock.unlock()
    }

    func onClosed(error: String?) {
        lock.lock(); _closed = .some(error); lock.unlock()
    }
}
