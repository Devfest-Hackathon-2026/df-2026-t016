import CoreMedia
import Foundation
import ImageIO
import os
import ReplayKit
import TraceKit

/// 【T15d】Developer タブを消したので、確認用の1行は Xcode のコンソール（録画拡張に接続したとき）か Console.app で見る。
private let debugLog = Logger(subsystem: "com.ggdevfest2026.drawtrace.broadcast", category: "debug")

/// 録画拡張（tasks/T05_録画拡張_画面の変化.md、tasks/T07_録画拡張_送信.md）。
/// - 録画の開始時に App Group の `session.current` を読み、端末の鍵を作って `CaptureEngine` を動かし始める
/// - 並行して、鍵を受付API に登録して開始証を受け取る（`SessionStarter`）。受け取れたら、5秒ごとのチャンクと送信を始める
/// - 0.5秒ごとに、変化の判定と編集画面の判定を行い、画面が止まったらキャンバスの検出をかけて全体画像を撮る
/// - 録画を終えるときは、終了画面を決めて最終チャンクを作り、最大10秒だけ送る。残りは本体アプリが送る
/// - `session.current` の `apiBaseURL` が空なら、送らずに記録だけをする（T05 の確認用の「仮の値」）
/// - 状態と本当のエラーを `broadcast.status`、確認用の1行を `broadcast.debug` に書く
final class SampleHandler: RPBroadcastSampleHandler {
    private let store = AppGroupStore()
    /// 下の変数は、このキューの上でだけ触る（`sender` の中身はスレッドセーフ）。
    private let queue = DispatchQueue(label: "com.ggdevfest2026.drawtrace.capture")
    private var engine: CaptureEngine?
    private var builder: ChunkBuilder?
    private var sender: ChunkSender?
    private var stats = FrameStats()
    private var captureTimer: DispatchSourceTimer?
    private var chunkTimer: DispatchSourceTimer?
    private var sid: String?
    private var state = BroadcastState.starting
    private var recordingStartedAt = Date()
    private var lastStatusAt = Date.distantPast
    private var finished = false
    private var note = ""
    private var lastError: String?
    private let registration = DispatchGroup()

    /// チャンクを作る間隔。
    private static let chunkInterval = 5
    /// 録画を終えるときに送る時間の上限。
    private static let finishSendSeconds: TimeInterval = 10

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let store else {
            fail("App Group を開けません（Signing & Capabilities の App Groups を確認してください）")
            return
        }
        guard let session = store.sessionCurrent else {
            fail("本体アプリで録画の準備をしてから始めてください")
            return
        }
        let startedAt = Date()
        // 端末の鍵（メモリ上だけ）。開始の登録・チャンクの署名・画像の署名のすべてに使う
        let key = DeviceKey()
        let engine: CaptureEngine
        do {
            engine = try CaptureEngine(sid: session.sid, store: store, signer: key, recordingStartedAt: startedAt)
        } catch {
            fail("録画の準備に失敗しました: \(error)")
            return
        }
        let apiURL = Self.apiURL(session.apiBaseURL)
        queue.sync {
            self.engine = engine
            self.sid = session.sid
            self.stats = FrameStats()
            self.finished = false
            self.lastError = nil
            self.recordingStartedAt = startedAt
            self.state = apiURL == nil ? .recording : .starting
            self.note = apiURL == nil ? "録画だけ（受付API の URL が無いので送らない）" : "開始の登録をしています"
            // 開始画面が決まったら、次のチャンクに入れる（キューの上で呼ばれる）
            engine.onStartImage = { [weak self] sha in self?.builder?.noteStartImage(sha) }
            engine.onWholeImage = { [weak self] sha in self?.builder?.noteWholeImage(sha) }
            self.startCaptureTimer()
            self.writeStatus(force: true)
        }
        guard let apiURL else { return }

        let client = APIClient(baseURL: apiURL)
        registration.enter()
        Task.detached { [weak self] in
            guard let self else { return }
            defer { self.registration.leave() }
            do {
                let started = try await SessionStarter.start(session: session, key: key, store: store, transport: client)
                self.didStart(started, key: key, client: client)
            } catch {
                self.fail(SampleHandler.startFailureMessage(error))
            }
        }
    }

    override func broadcastPaused() {
        queue.async {
            self.engine?.suspend(now: Date())
            self.note = "一時停止"
            self.writeStatus(force: true)
        }
    }

    override func broadcastResumed() {
        queue.async {
            self.note = "再開"
            self.writeStatus(force: true)
        }
    }

    override func broadcastFinished() {
        let deadline = Date().addingTimeInterval(Self.finishSendSeconds)
        // 開始要求の返事より先に停止されても、鍵が生きている間に最終チャンクを残す。
        _ = registration.wait(timeout: .now() + 5)
        var sending: ChunkSender?
        queue.sync {
            captureTimer?.cancel()
            captureTimer = nil
            chunkTimer?.cancel()
            chunkTimer = nil
            guard !finished else { return }  // エラーで先に終えた
            finished = true
            guard let engine else { return }
            let result = engine.finish(now: Date())
            note = "終了 start=\(Self.short(result.start)) end=\(Self.short(result.end)) wholes=\(result.wholeCount)"
            guard let builder, let sender else {
                if store?.sessionCurrent?.apiBaseURL.isEmpty == true {
                    state = .finished
                } else {
                    state = .error
                    lastError = "開始の登録が完了する前に録画が止まりました。作品の状態を確認してください"
                }
                writeStatus(force: true)
                return
            }
            do {
                try builder.finish(
                    engine.accumulator.drain(), now: Date(), fps: engine.processingFps,
                    memMB: Self.memoryMB(), degraded: engine.degraded, end: result.end,
                    sendWhole: engine.config.whole.sendWhole
                )
            } catch {
                note += " 最終チャンクを作れません: \(error)"
                lastError = "最終チャンクを作れません: \(error)"
            }
            state = builder.finalBuilt ? .finishing : .error
            writeStatus(force: true)
            sending = sender
        }
        guard let sending else { return }

        // 最終チャンクまで、最大10秒だけ送る。送り切れなければ finishing のまま残し、本体アプリが引き継ぐ
        sending.wake()
        while Date() < deadline, !sending.isDrained, sending.fatal == nil {
            Thread.sleep(forTimeInterval: 0.1)
        }
        sending.stop()
        queue.sync {
            if sending.fatal == nil, builder?.finalBuilt == true {
                state = sending.isDrained ? .finished : .finishing
            }
            writeStatus(force: true)
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let frameTime = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let orientation = Self.orientation(of: sampleBuffer)
        var unsupported: CaptureError?
        queue.sync {
            stats.add(sampleBuffer, now: uptime)
            guard !finished, let engine, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            do {
                try engine.handle(pixelBuffer, orientation: orientation, frameTime: frameTime)
            } catch let error as CaptureError {
                if case .unsupportedPixelFormat = error {
                    unsupported = error
                    finished = true  // 続けて届くフレームで何度も終えないように
                } else {
                    note = "フレームの処理: \(error)"
                    lastError = note
                }
            } catch {
                note = "フレームの処理: \(error)"
                lastError = note
            }
        }
        if let unsupported {
            fail("\(unsupported)")
        }
    }

    // MARK: - 開始の登録の後

    /// 開始証を受け取った（送信のスレッドの上で呼ばれる）。チャンクと送信を始める。
    private func didStart(_ started: StartedSession, key: DeviceKey, client: APIClient) {
        guard let store else { return }
        let sender = ChunkSender(store: store, sid: started.sid, transport: client)
        sender.onFatal = { [weak self] error in
            self?.sendingFailed(error)
        }
        var ready = false
        queue.sync {
            guard !finished, let engine else { return }  // 登録が終わる前に止められた
            do {
                let builder = try ChunkBuilder(
                    sid: started.sid, store: store, signer: key,
                    startCert: started.startCert, recordingStartedAt: recordingStartedAt
                )
                if let sha = engine.startImageSha {
                    builder.noteStartImage(sha)
                }
                if engine.config.whole.sendWhole {
                    for image in engine.wholeRecord.items { builder.noteWholeImage(image.sha) }
                }
                self.builder = builder
                self.sender = sender
                state = .recording
                note = "記録しています"
                startChunkTimer()
                writeStatus(force: true)
                ready = true
            } catch {
                note = "チャンクの準備に失敗しました: \(error)"
            }
        }
        if ready {
            Task.detached { await sender.run() }
        } else {
            queue.sync {
                if !finished { fail("チャンクの準備に失敗しました") }
            }
        }
    }

    /// 再送しないエラーで送信が止まった（送信のスレッドの上で呼ばれる）。
    private func sendingFailed(_ error: APIError) {
        let message = "送信を止めました（\(error.code)）: \(error.message)"
        var finishing = false
        queue.sync {
            finishing = finished
            if finishing {
                // 録画を終えた後（最終チャンクを送っている間）なら、状態だけを error にする
                state = .error
                note = message
                lastError = message
                writeStatus(force: true)
            }
        }
        if !finishing {
            fail(message)
        }
    }

    // MARK: - タイマー（キューの上で作る）

    private func startCaptureTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished, let engine = self.engine else { return }
            engine.tick(now: Date())
            self.writeStatus(force: false)
        }
        captureTimer = timer
        timer.resume()
    }

    private func startChunkTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.seconds(Self.chunkInterval)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.makeChunk()
        }
        chunkTimer = timer
        timer.resume()
    }

    /// 5秒ごと。画面に変化がなくても作る（心拍）。
    private func makeChunk() {
        guard !finished, let builder, let engine else { return }
        do {
            try builder.append(
                engine.accumulator.drain(), now: Date(), fps: engine.processingFps,
                memMB: Self.memoryMB(), degraded: engine.degraded
            )
            sender?.wake()
        } catch let error as ChunkBuilder.BuildError {
            fail("\(error)")
        } catch {
            note = "チャンクを作れません: \(error)"
            lastError = note
        }
    }

    // MARK: - 状態

    /// キューの上で呼ぶ。`force` でなければ1秒に1回まで。
    private func writeStatus(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStatusAt) >= 1.0 else { return }
        lastStatusAt = now
        let uptime = ProcessInfo.processInfo.systemUptime
        var line = stats.summary(now: uptime)
        if let engine {
            line += " " + engine.summary()
        }
        if let builder {
            line += " seq=\(builder.seq)"
        }
        if let sender {
            line += " sent=\(sender.sentSeq) queued=\(sender.queuedCount) imgPending=\(sender.pendingImageCount)"
            if let error = sender.lastError {
                line += " sendErr=" + error.replacingOccurrences(of: " ", with: "_")
            }
        }
        if !note.isEmpty {
            line += " note=" + note.replacingOccurrences(of: " ", with: "_")
        }
        let status = BroadcastStatus(
            sid: sid,
            state: state,
            sentSeq: sender?.sentSeq ?? -1,
            queuedCount: sender?.queuedCount ?? 0,
            wholeCount: engine?.wholeCount ?? 0,
            lastError: lastError ?? sender?.lastError
        )
        try? store?.setBroadcastStatus(status)
        try? store?.setBroadcastDebug(BroadcastDebug(sid: sid, summary: line, updatedAt: status.updatedAt))
        debugLog.debug("\(line, privacy: .public)")
    }

    /// 理由を付けて録画を終える。どのスレッドから呼んでもよい（キューの上からでも）。
    private func fail(_ message: String) {
        queue.async {
            self.finished = true
            self.captureTimer?.cancel()
            self.captureTimer = nil
            self.chunkTimer?.cancel()
            self.chunkTimer = nil
            self.sender?.stop()
            self.state = .error
            self.note = message
            self.lastError = message
            self.writeStatus(force: true)
        }
        // キューの上から呼ばれたときに、broadcastFinished の queue.sync と行き詰まらないよう、別のスレッドで終える
        DispatchQueue.global().async {
            self.finishBroadcastWithError(NSError(
                domain: "com.ggdevfest2026.drawtrace",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }

    // MARK: -

    static func apiURL(_ string: String) -> URL? {
        guard !string.isEmpty, let url = URL(string: string), url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        return url
    }

    static func startFailureMessage(_ error: Error) -> String {
        if let error = error as? APIError {
            switch error.code {
            case "TOKEN_INVALID", "TOKEN_EXPIRED", "TOKEN_USED":
                return "開始トークンが使えません（\(error.code)）。本体アプリで録画の準備をし直してください"
            case "NOT_FOUND":
                return "受付API にこのセッションがありません。本体アプリで録画の準備をし直してください"
            default:
                if error.isRetryable {
                    return "受付API に届きません（\(error)）。通信を確かめて、録画をやり直してください"
                }
            }
        }
        return "開始の登録に失敗しました: \(error)"
    }

    static func memoryMB() -> Int {
        Int((MemoryInfo.footprintMB() ?? 0).rounded())
    }

    /// 表示の向き（`RPVideoSampleOrientationKey`）。無ければ上向き。
    static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard
            let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)
                as? NSNumber,
            let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value)
        else { return .up }
        return orientation
    }

    static func short(_ sha: String?) -> String {
        sha.map { String($0.prefix(8)) } ?? "-"
    }
}
