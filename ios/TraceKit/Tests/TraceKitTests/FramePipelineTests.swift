import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import XCTest
@testable import TraceKit

/// T05 の録画拡張の中の部品の試験（合成した CVPixelBuffer で行う。Mac の `swift test` で回る）。
final class FramePipelineTests: XCTestCase {
    // MARK: - 合成のフレーム

    private enum TestError: Error { case create(Int32), decode }

    /// Y 面を `luma(x, y)`、CbCr 面を一様な値にした 420f（または 420v）のバッファ。
    private func makeBuffer(
        width: Int,
        height: Int,
        format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        cb: UInt8 = 128,
        cr: UInt8 = 128,
        luma: (Int, Int) -> UInt8
    ) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &created)
        guard status == kCVReturnSuccess, let buffer = created else { throw TestError.create(status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard CVPixelBufferIsPlanar(buffer) else { return buffer }

        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            for column in 0..<width {
                y[row * yStride + column] = luma(column, row)
            }
        }
        let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            for column in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                c[row * cStride + column * 2] = cb
                c[row * cStride + column * 2 + 1] = cr
            }
        }
        return buffer
    }

    /// 実機と同じ 1334×1920 の縦長で、左上 400×400 だけが黒いフレーム。
    private func portraitWithDarkTopLeft() throws -> CVPixelBuffer {
        try makeBuffer(width: 1334, height: 1920) { x, y in x < 400 && y < 400 ? 0 : 255 }
    }

    /// JPEG を読み、(x, y) の画素の明るさ（R・G・B の平均）を返す。y は上から。
    private func brightness(_ jpeg: Data, points: [(Int, Int)]) throws -> (width: Int, height: Int, values: [Int]) {
        guard
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw TestError.decode }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { throw TestError.decode }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let values = points.map { x, y -> Int in
            let offset = y * image.width * 4 + x * 4
            return (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
        }
        return (image.width, image.height, values)
    }

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 1_000 + seconds)
    }

    private func makeStore() throws -> (AppGroupStore, () -> Void) {
        let suite = "TraceKitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AppGroupStore(defaults: defaults, containerURL: folder)
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    // MARK: - 大きさと縮小

    func testScaledSizes() {
        XCTAssertTrue(FrameGeometry.scaled(width: 1334, height: 1920, longSide: 683) == (475, 683))
        XCTAssertTrue(FrameGeometry.scaled(width: 1334, height: 1920, longSide: 1024) == (711, 1024))
        XCTAssertTrue(FrameGeometry.scaled(width: 1920, height: 1334, longSide: 683) == (683, 475))
        XCTAssertTrue(FrameGeometry.scaled(width: 100, height: 50, longSide: 683) == (100, 50))
        XCTAssertEqual(FrameGeometry.fourCC(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), "420f")
        XCTAssertEqual(FrameGeometry.fourCC(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), "420v")
    }

    func testLumaDownscalerKeepsContentAndReusesBuffer() throws {
        let buffer = try portraitWithDarkTopLeft()
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let downscaler = LumaDownscaler()
        XCTAssertTrue(try downscaler.scale(buffer))
        XCTAssertEqual(downscaler.width, 475)
        XCTAssertEqual(downscaler.height, 683)
        let pixels = try XCTUnwrap(downscaler.pixels)
        // 左上の黒（400/1334×475 ≒ 142 画素）と、右下の白
        XCTAssertLessThan(pixels[20 * downscaler.bytesPerRow + 20], 30)
        XCTAssertGreaterThan(pixels[600 * downscaler.bytesPerRow + 400], 225)
        // 同じ大きさなら確保し直さない
        XCTAssertFalse(try downscaler.scale(buffer))
    }

    // MARK: - 写しと JPEG の向き

    private func makeJPEG(orientation: CGImagePropertyOrientation) throws -> Data {
        let buffer = try portraitWithDarkTopLeft()
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let snapshot = ColorSnapshot()
        try snapshot.update(buffer, orientation: orientation, frameTime: date(0))
        let image = try XCTUnwrap(snapshot.copy())
        XCTAssertEqual(image.lumaWidth, 710)
        XCTAssertEqual(image.lumaHeight, 1024)
        XCTAssertEqual(image.chromaWidth, 355)
        XCTAssertEqual(image.chromaHeight, 512)
        XCTAssertTrue(image.fullRange)
        return try SnapshotEncoder.jpeg(image)
    }

    func testJPEGUprightKeepsPortrait() throws {
        let result = try brightness(try makeJPEG(orientation: .up), points: [(30, 30), (680, 30), (30, 990)])
        XCTAssertEqual(result.width, 710)
        XCTAssertEqual(result.height, 1024)
        XCTAssertLessThan(result.values[0], 40)
        XCTAssertGreaterThan(result.values[1], 215)
        XCTAssertGreaterThan(result.values[2], 215)
    }

    func testJPEGRightIsRotatedClockwiseToLandscape() throws {
        // 向き 6（.right）: 時計回りに90度回す → 左上の黒は右上に来る
        let result = try brightness(try makeJPEG(orientation: .right), points: [(994, 30), (30, 30), (994, 680)])
        XCTAssertEqual(result.width, 1024)
        XCTAssertEqual(result.height, 710)
        XCTAssertLessThan(result.values[0], 40)
        XCTAssertGreaterThan(result.values[1], 215)
        XCTAssertGreaterThan(result.values[2], 215)
    }

    func testJPEGLeftAndDown() throws {
        // 向き 8（.left）: 反時計回りに90度 → 左上の黒は左下に来る
        let left = try brightness(try makeJPEG(orientation: .left), points: [(30, 680), (994, 30)])
        XCTAssertEqual(left.width, 1024)
        XCTAssertLessThan(left.values[0], 40)
        XCTAssertGreaterThan(left.values[1], 215)
        // 向き 3（.down）: 180度 → 左上の黒は右下に来る
        let down = try brightness(try makeJPEG(orientation: .down), points: [(680, 990), (30, 30)])
        XCTAssertEqual(down.width, 710)
        XCTAssertLessThan(down.values[0], 40)
        XCTAssertGreaterThan(down.values[1], 215)
    }

    func testColorConversionForFullAndVideoRange() throws {
        func argb(_ format: OSType, lumaValue: UInt8, cb: UInt8 = 128, cr: UInt8 = 128) throws -> [UInt8] {
            let buffer = try makeBuffer(width: 64, height: 48, format: format, cb: cb, cr: cr) { _, _ in lumaValue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let snapshot = ColorSnapshot()
            try snapshot.update(buffer, orientation: .up, frameTime: date(0))
            let result = try SnapshotEncoder.argb(try XCTUnwrap(snapshot.copy()))
            XCTAssertEqual(result.width, 64)
            XCTAssertEqual(result.height, 48)
            return Array(result.pixels[(24 * 64 + 32) * 4..<(24 * 64 + 32) * 4 + 4])
        }
        let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // ARGB の並び: [A, R, G, B]
        XCTAssertTrue(try argb(full, lumaValue: 255)[1...].allSatisfy { $0 >= 250 })
        XCTAssertTrue(try argb(full, lumaValue: 0)[1...].allSatisfy { $0 <= 5 })
        XCTAssertTrue(try argb(video, lumaValue: 235)[1...].allSatisfy { $0 >= 250 })
        XCTAssertTrue(try argb(video, lumaValue: 16)[1...].allSatisfy { $0 <= 5 })
        // Cr が大きいと赤くなる
        let reddish = try argb(full, lumaValue: 128, cr: 220)
        XCTAssertGreaterThan(reddish[1], reddish[2])
        XCTAssertGreaterThan(reddish[1], reddish[3])
    }

    // MARK: - 保存と署名

    func testWriterSavesSignedImageAndKeepsPending() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let key = DeviceKey()
        let writer = try SnapshotWriter(store: store, sid: "s_test", signer: key)
        let jpeg = try makeJPEG(orientation: .up)
        let sha = try writer.save(jpeg)
        XCTAssertEqual(sha, Canonical.sha256Hex(jpeg))
        XCTAssertEqual(try Data(contentsOf: writer.imageURL(sha)), jpeg)
        let signatureText = try String(contentsOf: writer.signatureURL(sha), encoding: .utf8)
        let signature = try XCTUnwrap(Canonical.fromBase64(signatureText))
        XCTAssertTrue(DeviceKey.verifyRS(
            publicKeyX963: key.publicKeyX963,
            signature: signature,
            data: DeviceKey.imageMessage(sid: "s_test", sha256: sha)
        ))

        // 送る印が付いた画像は消さない
        try writer.markPending(sha)
        writer.remove(sha)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.imageURL(sha).path))

        let other = try writer.save(Data("other".utf8))
        writer.remove(other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.imageURL(other).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.signatureURL(other).path))
    }

    // MARK: - CaptureEngine（【11/6】作り直した。実機の画面から作ったフレームで試す）

    /// 実機の縦持ちの画面を、実機と同じ 1334×1920 のフレームにする。
    private func portraitFrame(_ edit: ((GrayImage) -> GrayImage)? = nil) throws -> CVPixelBuffer {
        var gray = try TestImages.loadGray(TestImages.real("dark_blank_ipadportrait.jpg"), width: 1334, height: 1920)
        if let edit { gray = edit(gray) }
        return try TestImages.pixelBuffer(gray)
    }

    private func makeEngine(
        _ store: AppGroupStore, sid: String = "s_engine", memory: @escaping () -> Int? = { nil }
    ) throws -> CaptureEngine {
        try CaptureEngine(sid: sid, store: store, signer: DeviceKey(), recordingStartedAt: date(0), availableMemory: memory)
    }

    func testEngineTakesWholeImagesAndCountsEditorTime() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let engine = try makeEngine(store)
        var reportedStarts: [String] = []
        engine.onStartImage = { reportedStarts.append($0) }

        // 1. 白いキャンバスの全体を表示した画面 → 編集画面。1秒止まると全体画像を撮り、開始画面になる
        let blank = try portraitFrame()
        XCTAssertNotNil(try engine.handle(blank, orientation: .up, frameTime: date(0.0)))
        XCTAssertTrue(engine.lastEditor.isEditor, "\(engine.lastEditor)")
        XCTAssertNil(try engine.handle(blank, orientation: .up, frameTime: date(0.3)), "0.5秒より短い間隔は処理しない")
        engine.tick(now: date(0.5))
        XCTAssertNil(engine.startImageSha, "止まってから1秒たっていない")
        engine.tick(now: date(1.1))
        let start = try XCTUnwrap(engine.startImageSha, engine.summary())
        XCTAssertEqual(reportedStarts, [start])
        XCTAssertEqual(engine.wholeCount, 1)

        // 2. キャンバスに描く（1334×1920 の (600, 900) から 120×80）→ 小さな変化の時間が増える
        let drawn = try portraitFrame { TestImages.painting($0, x0: 600, y0: 900, w: 120, h: 80, value: 0) }
        XCTAssertNotNil(try engine.handle(drawn, orientation: .up, frameTime: date(2.0)))
        let adopted = try XCTUnwrap(try engine.handle(drawn, orientation: .up, frameTime: date(2.5)))
        XCTAssertGreaterThan(adopted.adoptedCount, 0)
        XCTAssertFalse(adopted.isGlobalChange)
        engine.tick(now: date(3.0))
        engine.tick(now: date(3.6)) // 描いてから1秒止まった → 全体画像（60秒たっていないので、いちばん新しいものとしてだけ持つ）
        XCTAssertEqual(engine.wholeCount, 1)
        XCTAssertNotNil(engine.wholeRecord.latest)
        XCTAssertNotEqual(engine.wholeRecord.latest?.sha, start)
        let first = engine.accumulator.drain()
        XCTAssertEqual(first.activeMs, 500)
        // タイマー 0.5秒（+500）、1.1秒（+600）、3.0秒（+1000。1回の上限は1秒）、3.6秒（+600）
        XCTAssertEqual(first.editorMs, 2_700)
        XCTAssertGreaterThan(first.changedTiles, 0)

        // 3. ホーム画面に切り替えた → 編集画面ではないので、時間も変化も数えない
        let home = try TestImages.pixelBuffer(TestImages.homeLike(width: 1334, height: 1920))
        XCTAssertNotNil(try engine.handle(home, orientation: .up, frameTime: date(4.0)))
        XCTAssertFalse(engine.lastEditor.isEditor)
        XCTAssertNotNil(try engine.handle(home, orientation: .up, frameTime: date(4.5)))
        engine.tick(now: date(5.0))
        engine.tick(now: date(6.0))
        XCTAssertEqual(engine.wholeCount, 1, "編集画面でなければ、全体画像の検出をかけない")

        // 4. 終える → いちばん新しい全体画像（描いた後）が終了画面
        let result = engine.finish(now: date(6.5))
        let end = try XCTUnwrap(result.end)
        XCTAssertEqual(result.start, start)
        XCTAssertNotEqual(end, start)
        XCTAssertEqual(result.wholeCount, 2)
        let second = engine.accumulator.drain()
        XCTAssertEqual(second.editorMs, 0)
        XCTAssertEqual(second.activeMs, 0)
        XCTAssertEqual(second.changedTiles, 0)
        XCTAssertEqual(second.frames, [0, 0])

        // ファイル: 開始画面と終了画面に、画像・署名・送る印。whole.json も同じ中身
        let writer = try SnapshotWriter(store: store, sid: "s_engine", signer: DeviceKey())
        for sha in [start, end] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: writer.imageURL(sha).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: writer.signatureURL(sha).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: writer.pendingURL(sha).path))
        }
        let record = try XCTUnwrap(store.wholeRecord(sid: "s_engine"))
        XCTAssertEqual(record, engine.wholeRecord)
        XCTAssertEqual(record.items.map(\.sha), [start, end])
        XCTAssertEqual(record.start, start)
        XCTAssertEqual(record.end, end)
        // 全体画像は表示の向きの JPEG（縦持ち: 710×1024）。キャンバスの四角形は Python とほぼ同じ
        let size = try brightness(try Data(contentsOf: writer.imageURL(start)), points: [])
        XCTAssertEqual(size.width, 710)
        XCTAssertEqual(size.height, 1024)
        let rect = try XCTUnwrap(record.items.first?.rect)
        XCTAssertEqual(rect[0], 0.146, accuracy: 0.01)
        XCTAssertEqual(rect[1], 0.182, accuracy: 0.01)
        XCTAssertTrue(engine.summary().contains("wholes=2"), engine.summary())
    }

    func testEngineLandscapeIsRotatedToDisplay() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let engine = try makeEngine(store, sid: "s_landscape")
        // 横持ちの画面を、実機と同じ縦長のバッファ（時計回りに90度回すと表示の向き）にして、向き 6（.right）で渡す
        let display = try TestImages.loadGray(TestImages.real("dark_blank_ipadlandscape.jpg"), width: 1920, height: 1334)
        let buffer = try TestImages.pixelBuffer(TestImages.rotateCounterClockwise(display))
        XCTAssertNotNil(try engine.handle(buffer, orientation: .right, frameTime: date(0)))
        XCTAssertTrue(engine.lastEditor.isEditor, "\(engine.lastEditor)")
        engine.tick(now: date(1.2))
        let start = try XCTUnwrap(engine.startImageSha, engine.summary())
        let writer = try SnapshotWriter(store: store, sid: "s_landscape", signer: DeviceKey())
        // 表示の向きの JPEG（1024×710）で、キャンバスの外（左上の背景）は暗く、キャンバスの中は白い
        let result = try brightness(try Data(contentsOf: writer.imageURL(start)), points: [(100, 300), (512, 355)])
        XCTAssertEqual(result.width, 1024)
        XCTAssertEqual(result.height, 710)
        XCTAssertLessThan(result.values[0], 60)
        XCTAssertGreaterThan(result.values[1], 230)
        let rect = try XCTUnwrap(engine.wholeRecord.items.first?.rect)
        XCTAssertEqual(rect[0], 0.182, accuracy: 0.01)
        XCTAssertEqual(rect[1], 0.147, accuracy: 0.01)
    }

    func testKeptWholeImagesArePendingAndPausingStopsEditorTime() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let engine = try makeEngine(store)
        var images: [String] = []
        engine.onWholeImage = { images.append($0) }
        try engine.handle(portraitFrame(), orientation: .up, frameTime: date(0))
        engine.tick(now: date(1.1))
        try engine.handle(portraitFrame { TestImages.painting($0, x0: 600, y0: 900, w: 120, h: 80, value: 0) },
                          orientation: .up, frameTime: date(61))
        engine.tick(now: date(62.1))
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(Set(ChunkSender.pendingImages(store: store, sid: engine.sid)), Set(images))
        engine.suspend(now: date(63))
        let before = engine.totalEditorMs
        engine.tick(now: date(64))
        engine.tick(now: date(65))
        XCTAssertEqual(engine.totalEditorMs, before)
        XCTAssertFalse(engine.lastEditor.isEditor)
    }

    func testEngineRejectsUnsupportedFormat() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let engine = try makeEngine(store, sid: "s_bgra")
        let bgra = try makeBuffer(width: 64, height: 48, format: kCVPixelFormatType_32BGRA) { _, _ in 0 }
        XCTAssertThrowsError(try engine.handle(bgra, orientation: .up, frameTime: date(0))) { error in
            XCTAssertEqual(error as? CaptureError, .unsupportedPixelFormat("BGRA"))
        }
    }

    func testEngineDropsToOneFpsWhenMemoryIsLow() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        var available = 5 * 1024 * 1024
        let engine = try makeEngine(store, sid: "s_memory", memory: { available })
        let blank = try makeBuffer(width: 192, height: 256) { _, _ in 255 }
        XCTAssertNotNil(try engine.handle(blank, orientation: .up, frameTime: date(0)))
        engine.tick(now: date(0.25))
        XCTAssertTrue(engine.degraded)
        XCTAssertNil(try engine.handle(blank, orientation: .up, frameTime: date(0.7)))
        XCTAssertNotNil(try engine.handle(blank, orientation: .up, frameTime: date(1.0)))
        // 戻ったら 2fps に戻す
        available = 100 * 1024 * 1024
        engine.tick(now: date(1.5))
        XCTAssertFalse(engine.degraded)
    }
}
