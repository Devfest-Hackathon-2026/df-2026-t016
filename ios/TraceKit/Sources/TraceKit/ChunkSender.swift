import Foundation

/// チャンクと画像の送り先。ふだんは `APIClient`、試験ではモック。
public protocol ChunkTransport: AnyObject {
    func sendChunk(sid: String, item: QueueItem) async throws -> ReceiptResponse
    func putImage(sid: String, sha256: String, jpeg: Data, deviceSig: Data) async throws -> ImageResponse
}

extension APIClient: ChunkTransport {}

/// App Group のキューのチャンクと、送る印（`.pending`）の付いた画像を、受付API に順に送る
/// （tasks/T07_録画拡張_送信.md の3・4）。録画拡張と本体アプリの両方から使う。
///
/// - 画像を先に送り、次にキューの `seq` が最も小さいチャンクを1件ずつ送る。受領証を受け取るまで次を送らない。
/// - 再送するときも、キューに書いた署名済みのバイト列をそのまま送る（作り直さない）。
/// - 通信エラーと 5xx は、1→2→4→8→16→30秒（以後30秒）の間隔で再送する。
/// - チャンクで再送しないエラー（共通仕様5章の表）が返ったら、そこで止める（`fatal`）。
/// - 画像で「再送しない」エラー（`TOO_LARGE` など）が返ったら、その画像の印だけを外して続ける（画像が無くても記録は続けられるため。
///   その画像は確定のときに「届いていない」になる）。「録画を止める」エラーなら止める。
public final class ChunkSender: @unchecked Sendable {
    /// 1回分の送信の結果。
    public enum PassResult: Equatable {
        /// 送るものが無くなった。
        case drained
        /// 通信エラーか 5xx。間をおいて送り直す。
        case retryLater(APIError)
        /// 再送しないエラー。録画を止める。
        case fatal(APIError)
    }

    /// 再送の間隔（秒）。
    public static let backoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    /// `attempt` 回目（0から）の失敗の後に待つ秒数。
    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        backoff[min(max(attempt, 0), backoff.count - 1)]
    }

    public let sid: String
    public let store: AppGroupStore
    private let transport: ChunkTransport
    private let lock = NSLock()
    private var sentSeqValue: Int
    private var lastErrorValue: String?
    private var transientError = false
    private var fatalValue: APIError?
    private var stopped = false
    private var wakeRequested = false
    private var failures = 0

    /// 再送しないエラーで止まったときに1回呼ぶ（送信のスレッドの上で）。
    public var onFatal: ((APIError) -> Void)?
    /// チャンクを1件送れるたびに呼ぶ（送信のスレッドの上で）。
    public var onSent: ((Int) -> Void)?

    public init(store: AppGroupStore, sid: String, transport: ChunkTransport) {
        self.store = store
        self.sid = sid
        self.transport = transport
        sentSeqValue = Self.lastReceiptSeq(store: store, sid: sid) ?? -1
    }

    // MARK: - 状態（どのスレッドから読んでもよい）

    /// 送り終えたチャンクの最後の `seq`（受領証の控えから。無ければ -1）。
    public var sentSeq: Int { locked { sentSeqValue } }
    /// 最後のエラー（再送中の通信エラーも含む）。
    public var lastError: String? { locked { lastErrorValue } }
    /// 止まった理由。
    public var fatal: APIError? { locked { fatalValue } }
    /// 続けて失敗した回数（成功すると0に戻る）。
    public var consecutiveFailures: Int { locked { failures } }
    /// 送信待ちのチャンクの数。
    public var queuedCount: Int { Self.queueFiles(store: store, sid: sid).count }
    /// 送る印の付いた画像の数。
    public var pendingImageCount: Int { Self.pendingImages(store: store, sid: sid).count }
    /// 送るものが残っていない。
    public var isDrained: Bool { queuedCount == 0 && pendingImageCount == 0 }

    // MARK: - 送る

    /// 送れるものを順に送る（画像 → チャンク）。送るものが無くなるか、エラーが起きたら返す。
    public func sendPass() async -> PassResult {
        if let fatal { return .fatal(fatal) }
        while true {
            if Task.isCancelled || locked({ stopped }) { return .drained }
            if let sha = Self.pendingImages(store: store, sid: sid).first {
                if let result = await sendImage(sha) {
                    return finishPass(result)
                }
                continue
            }
            if let url = Self.queueFiles(store: store, sid: sid).first {
                if let result = await sendChunk(at: url) {
                    return finishPass(result)
                }
                continue
            }
            return finishPass(.drained)
        }
    }

    /// 録画拡張の中で動かし続ける。止まるのは `stop()` か、再送しないエラーのとき。
    /// 送るものが無いときは `idleInterval` ごとにキューを見に行く（`wake()` ですぐ見に行く）。
    public func run(idleInterval: TimeInterval = 1.0) async {
        while !Task.isCancelled && !locked({ stopped }) {
            switch await sendPass() {
            case .drained:
                await pause(idleInterval)
            case .retryLater:
                await pause(Self.delay(forAttempt: consecutiveFailures - 1))
            case .fatal(let error):
                onFatal?(error)
                return
            }
        }
    }

    /// 本体アプリから、残りを送る（`flushRemaining`）。送り切るか、止まるか、`maxAttempts` 回続けて失敗したら返す。
    public func flush(maxAttempts: Int = 5) async -> PassResult {
        var result = PassResult.drained
        for attempt in 0..<max(1, maxAttempts) {
            result = await sendPass()
            guard case .retryLater = result else { return result }
            if attempt < maxAttempts - 1 {
                await pause(Self.delay(forAttempt: attempt))
            }
        }
        return result
    }

    /// 待っている間なら、すぐに送りに行く（再送の待ちも打ち切る）。
    public func wake() {
        locked { wakeRequested = true }
    }

    public func stop() {
        locked { stopped = true }
    }

    // MARK: - 本体アプリが送ってよいか（共通仕様8章）

    /// 本体アプリが、この `sid` の残りを送ってよいか。
    /// - 録画拡張が `finished`・`error` になった、または `updatedAt` が30秒以上前
    /// - `broadcast.status` が無い、または別の `sid` のもの（録画拡張はこの `sid` を送っていない）
    public static func shouldAppSend(status: BroadcastStatus?, sid: String, now: Date = Date()) -> Bool {
        guard let status, status.sid == sid else { return true }
        switch status.state {
        case .finished, .error:
            return true
        case .starting, .recording, .finishing:
            return RecordingPolicy.isStale(status, now: now)
        }
    }

    // MARK: - App Group の中

    /// キューのファイル（`seq` の順）。
    public static func queueFiles(store: AppGroupStore, sid: String) -> [URL] {
        store.files(in: .queue, sid: sid).filter { $0.pathExtension == "json" }
    }

    /// 送る印の付いた画像の sha（名前の順）。
    public static func pendingImages(store: AppGroupStore, sid: String) -> [String] {
        store.files(in: .images, sid: sid)
            .filter { $0.pathExtension == "pending" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// 受領証の控えの最後の `seq`。
    public static func lastReceiptSeq(store: AppGroupStore, sid: String) -> Int? {
        store.files(in: .receipts, sid: sid)
            .compactMap { Int($0.deletingPathExtension().lastPathComponent) }
            .max()
    }

    public static func receiptURL(store: AppGroupStore, sid: String, seq: Int) -> URL {
        store.directory(.receipts, sid: sid).appendingPathComponent(String(format: "%06d.json", seq))
    }

    // MARK: -

    /// 画像を1枚送る。続けてよければ `nil`。
    private func sendImage(_ sha: String) async -> PassResult? {
        let folder = store.directory(.images, sid: sid)
        let pending = folder.appendingPathComponent("\(sha).pending")
        guard
            let jpeg = try? Data(contentsOf: folder.appendingPathComponent("\(sha).jpg")),
            let sigText = try? String(contentsOf: folder.appendingPathComponent("\(sha).sig"), encoding: .utf8),
            let signature = Canonical.fromBase64(sigText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            store.remove(pending)
            note("画像 \(sha.prefix(8)) のファイルか署名が無いので送らない")
            return nil
        }
        do {
            _ = try await transport.putImage(sid: sid, sha256: sha, jpeg: jpeg, deviceSig: signature)
            store.remove(pending)
            return nil
        } catch let error as APIError {
            switch error.deviceAction {
            case .retry:
                return .retryLater(error)
            case .stopRecording:
                return .fatal(error)
            case .doNotResend:
                store.remove(pending)
                note("画像 \(sha.prefix(8)) を送れない: \(error)")
                return nil
            }
        } catch {
            return .retryLater(APIError(status: 0, code: "NETWORK", message: "\(error)"))
        }
    }

    /// チャンクを1件送る。続けてよければ `nil`。
    private func sendChunk(at url: URL) async -> PassResult? {
        guard
            let data = try? Data(contentsOf: url),
            let item = try? JSONDecoder().decode(QueueItem.self, from: data),
            let headerBytes = Canonical.fromBase64(item.header)
        else {
            return .fatal(APIError(status: -1, code: "BAD_QUEUE_ITEM", message: "キューのファイルが読めない: \(url.lastPathComponent)"))
        }
        let response: ReceiptResponse
        do {
            response = try await transport.sendChunk(sid: sid, item: item)
        } catch let error as APIError {
            return error.isRetryable ? .retryLater(error) : .fatal(error)
        } catch {
            return .retryLater(APIError(status: 0, code: "NETWORK", message: "\(error)"))
        }

        // 受領証が、送ったヘッダのものかを確かめる（KMS の署名は検証ページで確かめる）
        struct ReceiptBody: Decodable { let seq: Int; let header: String }
        guard
            let receiptBytes = Canonical.fromBase64(response.receipt),
            let receipt = try? JSONDecoder().decode(ReceiptBody.self, from: receiptBytes),
            receipt.seq == item.seq,
            receipt.header == Canonical.sha256Hex(headerBytes)
        else {
            return .fatal(APIError(status: -1, code: "RECEIPT_MISMATCH", message: "受領証が送ったチャンク（seq \(item.seq)）のものではない"))
        }
        do {
            try Canonical.encodeSorted(response).write(
                to: Self.receiptURL(store: store, sid: sid, seq: item.seq), options: .atomic
            )
        } catch {
            return .fatal(APIError(status: -1, code: "LOCAL_WRITE", message: "受領証の控えを書けない: \(error)"))
        }
        store.remove(url)
        locked { sentSeqValue = max(sentSeqValue, item.seq) }
        onSent?(item.seq)
        return nil
    }

    private func finishPass(_ result: PassResult) -> PassResult {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .drained:
            failures = 0
            if transientError { lastErrorValue = nil; transientError = false }
        case .retryLater(let error):
            failures += 1
            lastErrorValue = error.description
            transientError = true
        case .fatal(let error):
            fatalValue = error
            lastErrorValue = error.description
        }
        return result
    }

    private func note(_ message: String) {
        locked { lastErrorValue = message; transientError = false }
    }

    /// `seconds` だけ待つ。`wake()`・`stop()` で打ち切る。
    private func pause(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { return }
            let interrupted: Bool = locked {
                if wakeRequested || stopped {
                    wakeRequested = false
                    return true
                }
                return false
            }
            if interrupted { return }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
