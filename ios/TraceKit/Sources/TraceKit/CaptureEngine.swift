import CoreVideo
import Foundation
import ImageIO
#if os(iOS)
import os
#endif

/// 録画拡張の中で、フレームから「全体画像」と「編集画面で小さな変化があった時間」を作る
/// （tasks/T05_録画拡張_画面の変化.md。【11/6】作り直した）。
///
/// 録画拡張は、1つの直列キューの上で次を呼ぶ（スレッドセーフではない）。
/// - フレームが届いたら `handle(_:orientation:frameTime:)`（`processSampleBuffer` の中で同期的に。バッファは保持しない）
/// - 250ms ごとのタイマーで `tick(now:)`
/// - 録画を終えるときに `finish(now:)`
///
/// T07（`ChunkBuilder`）は `accumulator` を5秒ごとに取り出し、`onStartImage`（または `startImageSha`）と `finish` の結果をヘッダの `images` に入れる。
public final class CaptureEngine {
    public struct Config {
        /// 処理する間隔（2fps）。これより短い間隔で届いたフレームは何もしない。
        public var processInterval: TimeInterval = 0.5
        /// メモリが足りないときの間隔（1fps）。
        public var degradedInterval: TimeInterval = 1.0
        /// 残りのメモリがこれを切ったら、1fps に落とす。
        public var lowMemoryBytes = 10 * 1024 * 1024
        /// 残りのメモリがこれを超えたら、2fps に戻す。
        public var recoverMemoryBytes = 20 * 1024 * 1024
        public var memoryCheckInterval: TimeInterval = 1.0
        public var lumaLongSide = 683
        public var snapshotLongSide = 1024
        public var jpegQuality = 0.7
        /// 画面が止まったとみなす秒数（全体画像の検出をかける条件）。
        public var stableAfter: TimeInterval = 1.0
        public var detector = ChangeDetectorConfig()
        public var editor = EditorScreenConfig()
        public var whole = WholeCanvasConfig()

        public init() {}
    }

    /// 録画を終えたときの結果。
    public struct Final: Equatable {
        public var start: String?
        public var end: String?
        public var wholeCount: Int
    }

    public let sid: String
    public let config: Config
    /// T07 が5秒ごとに取り出す。
    public let accumulator = ActivityAccumulator()
    /// 開始画面（最初の全体画像）が決まったときに1回だけ呼ぶ（キューの上で）。
    public var onStartImage: ((String) -> Void)?
    public var onWholeImage: ((String) -> Void)?

    public private(set) var startImageSha: String?
    public private(set) var endImageSha: String?
    /// メモリが足りず 1fps に落としているか（チャンクの `stats.degraded`）。
    public private(set) var degraded = false
    public private(set) var lastError: String?
    public private(set) var processedFrames = 0
    public private(set) var globalChanges = 0
    /// 最後に処理したフレームの、編集画面の判定。
    public private(set) var lastEditor = EditorMatch.none
    /// 録画の始めからの合計（確認の表示用。チャンクの値は `accumulator` から取る）。
    public private(set) var totalEditorMs = 0
    public private(set) var totalActiveMs = 0
    /// 最後にキャンバスの検出をかけた結果（`ok` か、外れた理由）。
    public private(set) var lastWholeReason = "-"
    public private(set) var wholeAttempts = 0
    /// 最後に測った残りのメモリ（バイト）。
    public private(set) var availableBytes: Int?

    private let store: AppGroupStore
    private let writer: SnapshotWriter
    private let detector: ChangeDetector
    private let luma: LumaDownscaler
    private let snapshot: ColorSnapshot
    private let editorDetector: EditorScreenDetector
    private let wholeDetector: WholeCanvasDetector
    private let wholeCapture: WholeCapture
    private let availableMemory: () -> Int?
    private var lastProcessedAt: Date?
    private var lastTickAt: Date?
    private var lastMemoryCheckAt: Date?
    private var recentProcessed: [Date] = []
    private var tileLayout: (width: Int, height: Int, rotation: Int)?

    public init(
        sid: String,
        store: AppGroupStore,
        signer: ImageSigning,
        recordingStartedAt: Date,
        config: Config = Config(),
        availableMemory: @escaping () -> Int? = CaptureEngine.systemAvailableMemory
    ) throws {
        self.sid = sid
        self.config = config
        self.store = store
        self.availableMemory = availableMemory
        writer = try SnapshotWriter(store: store, sid: sid, signer: signer)
        detector = ChangeDetector(config: config.detector)
        luma = LumaDownscaler(longSide: config.lumaLongSide)
        snapshot = ColorSnapshot(longSide: config.snapshotLongSide)
        editorDetector = EditorScreenDetector(config: config.editor)
        wholeDetector = WholeCanvasDetector(config: config.whole)
        wholeCapture = WholeCapture(config: config.whole, stableAfter: config.stableAfter)
        lastTickAt = recordingStartedAt
    }

    /// `os_proc_available_memory()`（iOS だけ。ほかでは測らない）。
    public static func systemAvailableMemory() -> Int? {
        #if os(iOS)
        return Int(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    /// 直近1秒に処理したフレームの数（確認の表示用）。画面が止まるとフレームが来ないので0になる。
    public var processedFps: Int { recentProcessed.count }

    /// 処理する枚数（毎秒）。通常 2、メモリ不足のときは 1（チャンクの `stats.fps`）。
    public var processingFps: Int { Int((1 / currentInterval).rounded()) }

    /// 残した全体画像の数（`broadcast.status.wholeCount`）。
    public var wholeCount: Int { wholeCapture.count }

    /// `whole.json` の中身。
    public var wholeRecord: WholeRecord { wholeCapture.record }

    private var currentInterval: TimeInterval { degraded ? config.degradedInterval : config.processInterval }

    /// フレームを1枚処理する。間引いたときは `nil`。`420f`・`420v` 以外なら `CaptureError.unsupportedPixelFormat` を投げる。
    @discardableResult
    public func handle(
        _ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, frameTime: Date
    ) throws -> FrameResult? {
        let interval = currentInterval
        if let lastProcessedAt, frameTime.timeIntervalSince(lastProcessedAt) < interval {
            return nil
        }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard FrameGeometry.supportedFormats.contains(format) else {
            throw CaptureError.unsupportedPixelFormat(FrameGeometry.fourCC(format))
        }
        let locked = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard locked == kCVReturnSuccess else { throw CaptureError.lockFailed(locked) }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        lastProcessedAt = frameTime

        // 変化の判定（縦長のバッファのまま。上のバーとサイドバーのタイルは数えない）
        let rotation = FrameGeometry.clockwiseRotation(for: orientation)
        if try luma.scale(pixelBuffer) {
            detector.reset()
        }
        let sameLayout = tileLayout.map {
            $0.width == luma.width && $0.height == luma.height && $0.rotation == rotation
        } ?? false
        if !sameLayout {
            detector.setIgnoredTiles(FrameGeometry.uiTiles(
                bufferWidth: luma.width, bufferHeight: luma.height, rotation: rotation,
                topBarPx: config.whole.topBarPx, leftBarPx: config.whole.leftBarPx
            ))
            tileLayout = (luma.width, luma.height, rotation)
        }
        guard let pixels = luma.pixels else { return nil }
        let result = detector.process(
            width: luma.width, height: luma.height, bytesPerRow: luma.bytesPerRow, pixels: pixels, frameTime: frameTime
        )

        // 色つきの写しと、編集画面の判定（写しの Y 面の左上を、表示の向きで見本と比べる）
        try snapshot.update(pixelBuffer, orientation: orientation, frameTime: frameTime)
        let previousEditor = lastEditor.isEditor
        if let snapshotPixels = snapshot.lumaPixels {
            lastEditor = editorDetector.match(
                pixels: snapshotPixels, width: snapshot.width, height: snapshot.height,
                rowBytes: snapshot.lumaRowBytes, rotation: rotation
            )
        } else {
            lastEditor = .none
        }

        // 集計: 編集画面のときだけ数える。小さな変化（1〜230タイル）が続いたら、その間を足す
        processedFrames += 1
        recentProcessed.append(frameTime)
        recentProcessed.removeAll { frameTime.timeIntervalSince($0) > 1.0 }
        if result.isGlobalChange { globalChanges += 1 }
        if lastEditor.isEditor {
            accumulator.add(result)
            if previousEditor, result.adoptedCount > 0, !result.isGlobalChange {
                let milliseconds = Int(interval * 1000)
                accumulator.addActiveTime(milliseconds: milliseconds)
                totalActiveMs += milliseconds
            }
        } else {
            accumulator.add(FrameResult(
                frameTime: frameTime, adoptedTiles: [], differingCount: result.differingCount,
                isFirst: result.isFirst, isGlobalChange: false
            ))
        }
        wholeCapture.frameProcessed(
            changed: result.isFirst || result.differingCount > 0, editor: lastEditor.isEditor, at: frameTime
        )
        return result
    }

    /// 250ms ごとに呼ぶ。編集画面だった時間を足し、画面が止まっていれば全体画像の検出をかけ、メモリを確かめる。
    public func tick(now: Date) {
        if let lastTickAt, lastEditor.isEditor {
            // 画面が止まるとフレームが来ないが、その間も画面は変わっていないので、最後の判定のまま足す
            let milliseconds = Int((min(max(now.timeIntervalSince(lastTickAt), 0), 1.0) * 1000).rounded())
            accumulator.addEditorTime(milliseconds: milliseconds)
            totalEditorMs += milliseconds
        }
        lastTickAt = now
        checkMemory(now: now)
        if wholeCapture.shouldCheck(now: now) {
            wholeCapture.markChecked()
            captureWholeIfVisible()
        }
    }

    /// ReplayKitの一時停止中は、最後の編集画面の判定で時間を加算しない。
    public func suspend(now: Date) {
        lastEditor = .none
        lastTickAt = now
        wholeCapture.frameProcessed(changed: true, editor: false, at: now)
        detector.reset()
    }

    /// 録画を終えるときに呼ぶ。いちばん新しい全体画像を終了画面にする。
    @discardableResult
    public func finish(now: Date) -> Final {
        tick(now: now)
        if let end = wholeCapture.finish() {
            endImageSha = end
            do {
                try writer.markPending(end)
            } catch {
                lastError = "終了画面の印: \(error)"
            }
        }
        writeWhole()
        return Final(start: startImageSha, end: endImageSha, wholeCount: wholeCapture.count)
    }

    /// `broadcast.status` に出す1行（T05 の確認用）。
    public func summary() -> String {
        var parts = [
            "proc=\(processedFrames)",
            "pfps=\(processedFps)",
            "editor=\(lastEditor.isEditor ? 1 : 0)",
            String(format: "eb=%.2f", lastEditor.bright),
            String(format: "ed=%.2f", lastEditor.dark),
            String(format: "editorSec=%.1f", Double(totalEditorMs) / 1000),
            String(format: "activeSec=%.1f", Double(totalActiveMs) / 1000),
            "global=\(globalChanges)",
            "wholes=\(wholeCapture.count)",
            "wholeTry=\(wholeAttempts)",
            "lastWhole=\(lastWholeReason)",
            "start=\(Self.short(startImageSha))",
            "end=\(Self.short(endImageSha))",
        ]
        if let availableBytes {
            parts.append(String(format: "free=%.0fMB", Double(availableBytes) / 1_048_576))
        }
        if degraded { parts.append("degraded") }
        if let lastError { parts.append("err=\(lastError.replacingOccurrences(of: " ", with: "_"))") }
        return parts.joined(separator: " ")
    }

    static func short(_ sha: String?) -> String {
        sha.map { String($0.prefix(8)) } ?? "-"
    }

    // MARK: -

    private func captureWholeIfVisible() {
        wholeAttempts += 1
        do {
            guard let gray = try snapshot.displayLuma(), let image = snapshot.copy() else { return }
            let detected = wholeDetector.detect(gray)
            lastWholeReason = detected.reason
            guard let rect = detected.rect else { return }

            let jpeg = try SnapshotEncoder.jpeg(image, quality: config.jpegQuality)
            let sha = try writer.save(jpeg)
            let decision = wholeCapture.add(
                sha: sha, frameTime: image.frameTime, rect: rect.normalized(width: gray.width, height: gray.height)
            )
            if let old = decision.discard {
                writer.remove(old)
            }
            if decision.isStart {
                startImageSha = sha
                try writer.markPending(sha)
                onStartImage?(sha)
            }
            if decision.kept, config.whole.sendWhole {
                try writer.markPending(sha)
                onWholeImage?(sha)
            }
            writeWhole()
        } catch {
            lastError = "全体画像: \(error)"
        }
    }

    private func checkMemory(now: Date) {
        if let lastMemoryCheckAt, now.timeIntervalSince(lastMemoryCheckAt) < config.memoryCheckInterval {
            return
        }
        lastMemoryCheckAt = now
        guard let available = availableMemory() else { return }
        availableBytes = available
        if available < config.lowMemoryBytes {
            degraded = true
        } else if available > config.recoverMemoryBytes {
            degraded = false
        }
    }

    private func writeWhole() {
        do {
            try store.setWholeRecord(wholeCapture.record, sid: sid)
        } catch {
            lastError = "whole.json: \(error)"
        }
    }
}
