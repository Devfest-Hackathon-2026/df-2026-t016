import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

// 録画拡張に届いたフレームから、変化の判定用の輝度と、開始画面・終了画面用の色つきの写しを作る
// （tasks/T05_録画拡張_画面の変化.md の2・5・6）。vImage だけを使い、CoreImage・Metal は使わない（設計書7章の11）。

public enum CaptureError: Error, Equatable, CustomStringConvertible {
    /// `420f`・`420v` 以外の形式。録画拡張はこのとき録画を終える。
    case unsupportedPixelFormat(String)
    case lockFailed(Int32)
    case vImage(String, Int)
    case jpeg(String)

    public var description: String {
        switch self {
        case .unsupportedPixelFormat(let fourCC): return "対応していない画面形式（\(fourCC)）"
        case .lockFailed(let code): return "フレームを読めない（\(code)）"
        case .vImage(let step, let code): return "vImage の\(step)に失敗（\(code)）"
        case .jpeg(let step): return "JPEG の\(step)に失敗"
        }
    }
}

public enum FrameGeometry {
    /// 受け付けるピクセル形式（`420f` と `420v`）。
    public static let supportedFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ]

    /// 長辺を `longSide` にした大きさ。元が小さければ、そのまま（拡大しない）。
    public static func scaled(width: Int, height: Int, longSide: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > longSide else { return (width, height) }
        let ratio = Double(longSide) / Double(long)
        return (
            max(1, Int((Double(width) * ratio).rounded())),
            max(1, Int((Double(height) * ratio).rounded()))
        )
    }

    /// ピクセル形式の FourCC（`420f` など）。
    public static func fourCC(_ type: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((type >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(format: "0x%08x", type)
    }

    /// 鍵をかけた（`CVPixelBufferLockBaseAddress` 済みの）バッファの面を、vImage の形で見る（コピーしない）。
    static func plane(_ pixelBuffer: CVPixelBuffer, _ index: Int) -> vImage_Buffer {
        vImage_Buffer(
            data: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, index),
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, index)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, index)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
        )
    }

    /// vImage の回転の定数（時計回りの角度から）。
    static func rotationConstant(degrees: Int) -> UInt8 {
        switch degrees {
        case 90: return UInt8(kRotate90DegreesClockwise)
        case 180: return UInt8(kRotate180DegreesClockwise)
        case 270: return UInt8(kRotate270DegreesClockwise)
        default: return UInt8(kRotate0DegreesClockwise)
        }
    }

    /// 表示の向きの大きさ（バッファを時計回りに `rotation` 度回したとき）。
    public static func displaySize(bufferWidth: Int, bufferHeight: Int, rotation: Int) -> (width: Int, height: Int) {
        rotation == 90 || rotation == 270 ? (bufferHeight, bufferWidth) : (bufferWidth, bufferHeight)
    }

    /// バッファの点 → 表示の向きの点（時計回りに `rotation` 度回したとき。vImage の回転と同じ向き）。
    public static func displayPoint(
        x: Int, y: Int, bufferWidth w: Int, bufferHeight h: Int, rotation: Int
    ) -> (x: Int, y: Int) {
        switch rotation {
        case 90: return (h - 1 - y, x)
        case 180: return (w - 1 - x, h - 1 - y)
        case 270: return (y, w - 1 - x)
        default: return (x, y)
        }
    }

    /// 表示の向きの点 → バッファの点（`displayPoint` の逆）。
    public static func bufferPoint(
        x: Int, y: Int, bufferWidth w: Int, bufferHeight h: Int, rotation: Int
    ) -> (x: Int, y: Int) {
        switch rotation {
        case 90: return (y, h - 1 - x)
        case 180: return (w - 1 - x, h - 1 - y)
        case 270: return (w - 1 - y, x)
        default: return (x, y)
        }
    }

    /// 【11/6】上のバーとサイドバーにかかるタイル（変化の判定で数えない）。
    /// `topBarPx`・`leftBarPx` は、表示の向きで長辺1024px のときの画素。バッファの大きさに合わせて縮めて使う。
    public static func uiTiles(
        bufferWidth w: Int, bufferHeight h: Int, rotation: Int, topBarPx: Int, leftBarPx: Int
    ) -> Set<Int> {
        let scale = Double(max(w, h)) / 1024
        let top = Double(topBarPx) * scale
        let left = Double(leftBarPx) * scale
        let tileWidth = w / TileBitmap.columns
        let tileHeight = h / TileBitmap.rows
        var result = Set<Int>()
        for tileY in 0..<TileBitmap.rows {
            let y0 = tileY * tileHeight
            let y1 = tileY == TileBitmap.rows - 1 ? h - 1 : y0 + tileHeight - 1
            for tileX in 0..<TileBitmap.columns {
                let x0 = tileX * tileWidth
                let x1 = tileX == TileBitmap.columns - 1 ? w - 1 : x0 + tileWidth - 1
                var minX = Int.max
                var minY = Int.max
                for (cx, cy) in [(x0, y0), (x1, y0), (x0, y1), (x1, y1)] {
                    let p = displayPoint(x: cx, y: cy, bufferWidth: w, bufferHeight: h, rotation: rotation)
                    minX = min(minX, p.x)
                    minY = min(minY, p.y)
                }
                if Double(minY) < top || Double(minX) < left {
                    result.insert(tileY * TileBitmap.columns + tileX)
                }
            }
        }
        return result
    }

    /// 表示の向きにするために、時計回りに何度回すか（`RPVideoSampleOrientationKey` の値。EXIF の向きと同じ）。
    /// どの値でどちらへ回すかは、実機で横向き・縦向きの両方を撮って確かめる（T05）。鏡像は無視する。
    public static func clockwiseRotation(for orientation: CGImagePropertyOrientation) -> Int {
        switch orientation {
        case .up, .upMirrored: return 0
        case .down, .downMirrored: return 180
        case .right, .rightMirrored: return 90
        case .left, .leftMirrored: return 270
        @unknown default: return 0
        }
    }
}

/// vImage で1つの面を縮小する。縮小先と一時バッファは、大きさが変わったときだけ確保し直す。
final class PlaneScaler {
    enum Kind {
        /// 1画素1バイト（Y 面）。
        case planar8
        /// 1画素2バイト（CbCr 面）。
        case cbcr8
    }

    let kind: Kind
    private(set) var width = 0
    private(set) var height = 0
    private(set) var rowBytes = 0
    private(set) var data: UnsafeMutableRawPointer?
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var temp: UnsafeMutableRawPointer?

    init(kind: Kind) {
        self.kind = kind
    }

    deinit {
        data?.deallocate()
        temp?.deallocate()
    }

    private var bytesPerPixel: Int { kind == .planar8 ? 1 : 2 }

    private var destination: vImage_Buffer {
        vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
    }

    /// `source` を `width`×`height` に縮小する。戻り値は、縮小先を確保し直したか。
    @discardableResult
    func scale(_ source: vImage_Buffer, width: Int, height: Int) throws -> Bool {
        let resized = data == nil
            || width != self.width || height != self.height
            || Int(source.width) != sourceWidth || Int(source.height) != sourceHeight
        if resized {
            data?.deallocate()
            temp?.deallocate()
            temp = nil
            self.width = width
            self.height = height
            rowBytes = width * bytesPerPixel
            data = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 64)
            sourceWidth = Int(source.width)
            sourceHeight = Int(source.height)

            var src = source
            var dst = destination
            let size = run(&src, &dst, nil, vImage_Flags(kvImageGetTempBufferSize))
            guard size >= 0 else { throw CaptureError.vImage("一時バッファの大きさ", size) }
            if size > 0 {
                temp = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
            }
        }
        var src = source
        var dst = destination
        let error = run(&src, &dst, temp, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw CaptureError.vImage("縮小", error) }
        return resized
    }

    private func run(
        _ src: UnsafePointer<vImage_Buffer>,
        _ dst: UnsafePointer<vImage_Buffer>,
        _ temp: UnsafeMutableRawPointer?,
        _ flags: vImage_Flags
    ) -> vImage_Error {
        switch kind {
        case .planar8: return vImageScale_Planar8(src, dst, temp, flags)
        case .cbcr8: return vImageScale_CbCr8(src, dst, temp, flags)
        }
    }
}

/// 変化の判定用に、Y 面を長辺 683px に縮小する（1334×1920 なら 475×683）。バッファは使い回す。
public final class LumaDownscaler {
    public let longSide: Int
    private let scaler = PlaneScaler(kind: .planar8)

    public init(longSide: Int = 683) {
        self.longSide = longSide
    }

    public var width: Int { scaler.width }
    public var height: Int { scaler.height }
    public var bytesPerRow: Int { scaler.rowBytes }

    /// 縮小した輝度。`scale` を呼ぶまでは `nil`。
    public var pixels: UnsafePointer<UInt8>? {
        scaler.data.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) }
    }

    /// 鍵をかけたバッファの Y 面を縮小する。戻り値は、大きさが変わった（`ChangeDetector` を初期化すべき）か。
    @discardableResult
    public func scale(_ pixelBuffer: CVPixelBuffer) throws -> Bool {
        let source = FrameGeometry.plane(pixelBuffer, 0)
        let size = FrameGeometry.scaled(width: Int(source.width), height: Int(source.height), longSide: longSide)
        return try scaler.scale(source, width: size.width, height: size.height)
    }
}

/// グレースケールの画像（1画素1バイト、行の詰め物なし）。
public struct GrayImage: Equatable {
    public var pixels: [UInt8]
    public var width: Int
    public var height: Int

    public init(pixels: [UInt8], width: Int, height: Int) {
        precondition(pixels.count >= width * height, "画素が足りません")
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
}

/// 写しの中身（コピー）。JPEG にするときに使う。
public struct SnapshotImage {
    public var luma: Data
    public var lumaWidth: Int
    public var lumaHeight: Int
    /// CbCr を交互に並べたもの（1画素2バイト）。
    public var chroma: Data
    public var chromaWidth: Int
    public var chromaHeight: Int
    public var fullRange: Bool
    public var orientation: CGImagePropertyOrientation
    public var frameTime: Date
}

/// 開始画面・終了画面用の、色つきの小さな写し（長辺1024px の Y 面と、その半分の CbCr 面）。
/// 元の解像度のまま ARGB にはしない（1334×1920×4 で約10MB になる）。
public final class ColorSnapshot {
    public let longSide: Int
    private let luma = PlaneScaler(kind: .planar8)
    private let chroma = PlaneScaler(kind: .cbcr8)
    public private(set) var frameTime: Date?
    public private(set) var orientation: CGImagePropertyOrientation = .up
    public private(set) var fullRange = true

    public init(longSide: Int = 1024) {
        self.longSide = longSide
    }

    public var width: Int { luma.width }
    public var height: Int { luma.height }
    public var lumaRowBytes: Int { luma.rowBytes }

    /// 写しの Y 面（バッファの向き）。まだ写していなければ `nil`。
    public var lumaPixels: UnsafePointer<UInt8>? {
        luma.data.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) }
    }

    /// 表示の向きにするために時計回りに回す角度。
    public var rotation: Int { FrameGeometry.clockwiseRotation(for: orientation) }

    /// 【11/6】写しの Y 面を表示の向きに回したもの（全体画像の判定に使う）。
    public func displayLuma() throws -> GrayImage? {
        guard let data = luma.data else { return nil }
        let width = luma.width
        let height = luma.height
        let degrees = rotation
        if degrees == 0 {
            var pixels = [UInt8](repeating: 0, count: width * height)
            let source = data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    pixels[y * width + x] = source[y * luma.rowBytes + x]
                }
            }
            return GrayImage(pixels: pixels, width: width, height: height)
        }
        let size = FrameGeometry.displaySize(bufferWidth: width, bufferHeight: height, rotation: degrees)
        var pixels = [UInt8](repeating: 0, count: size.width * size.height)
        var source = vImage_Buffer(
            data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: luma.rowBytes
        )
        try pixels.withUnsafeMutableBytes { bytes in
            var destination = vImage_Buffer(
                data: bytes.baseAddress, height: vImagePixelCount(size.height),
                width: vImagePixelCount(size.width), rowBytes: size.width
            )
            let error = vImageRotate90_Planar8(
                &source, &destination, FrameGeometry.rotationConstant(degrees: degrees), 0, vImage_Flags(kvImageNoFlags)
            )
            guard error == kvImageNoError else { throw CaptureError.vImage("回転", error) }
        }
        return GrayImage(pixels: pixels, width: size.width, height: size.height)
    }

    /// 鍵をかけたバッファで写しを更新する。
    public func update(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, frameTime: Date) throws {
        let y = FrameGeometry.plane(pixelBuffer, 0)
        let size = FrameGeometry.scaled(width: Int(y.width), height: Int(y.height), longSide: longSide)
        // 4:2:0 の変換は縦横が偶数のほうが確実なので、偶数に切り下げる（1334×1920 なら 710×1024）
        let width = max(2, size.width - size.width % 2)
        let height = max(2, size.height - size.height % 2)
        try luma.scale(y, width: width, height: height)
        try chroma.scale(FrameGeometry.plane(pixelBuffer, 1), width: width / 2, height: height / 2)
        self.frameTime = frameTime
        self.orientation = orientation
        fullRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    /// 今の写しのコピー。まだ写していなければ `nil`。
    public func copy() -> SnapshotImage? {
        guard let frameTime, let lumaData = luma.data, let chromaData = chroma.data else { return nil }
        return SnapshotImage(
            luma: Data(bytes: lumaData, count: luma.rowBytes * luma.height),
            lumaWidth: luma.width,
            lumaHeight: luma.height,
            chroma: Data(bytes: chromaData, count: chroma.rowBytes * chroma.height),
            chromaWidth: chroma.width,
            chromaHeight: chroma.height,
            fullRange: fullRange,
            orientation: orientation,
            frameTime: frameTime
        )
    }
}

/// 写しを、表示の向きの JPEG にする。
public enum SnapshotEncoder {
    /// YCbCr → ARGB（ITU-R 709、範囲はフル／ビデオに合わせる）→ 表示の向きに回す。戻り値は ARGB の並び。
    public static func argb(_ image: SnapshotImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        var range = image.fullRange
            ? vImage_YpCbCrPixelRange(
                Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
                YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0
            )
            : vImage_YpCbCrPixelRange(
                Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16
            )
        var info = vImage_YpCbCrToARGB()
        let generated = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
            &range,
            &info,
            kvImage420Yp8_CbCr8,
            kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)
        )
        guard generated == kvImageNoError else { throw CaptureError.vImage("変換の準備", generated) }

        let width = image.lumaWidth
        let height = image.lumaHeight
        var argb = [UInt8](repeating: 255, count: width * height * 4)
        var lumaData = image.luma
        var chromaData = image.chroma
        var permute: [UInt8] = [0, 1, 2, 3]
        try lumaData.withUnsafeMutableBytes { lumaBytes in
            try chromaData.withUnsafeMutableBytes { chromaBytes in
                try argb.withUnsafeMutableBytes { argbBytes in
                    var y = vImage_Buffer(
                        data: lumaBytes.baseAddress, height: vImagePixelCount(height),
                        width: vImagePixelCount(width), rowBytes: width
                    )
                    var cbcr = vImage_Buffer(
                        data: chromaBytes.baseAddress, height: vImagePixelCount(image.chromaHeight),
                        width: vImagePixelCount(image.chromaWidth), rowBytes: image.chromaWidth * 2
                    )
                    var destination = vImage_Buffer(
                        data: argbBytes.baseAddress, height: vImagePixelCount(height),
                        width: vImagePixelCount(width), rowBytes: width * 4
                    )
                    let error = vImageConvert_420Yp8_CbCr8ToARGB8888(
                        &y, &cbcr, &destination, &info, &permute, 255, vImage_Flags(kvImageNoFlags)
                    )
                    guard error == kvImageNoError else { throw CaptureError.vImage("色の変換", error) }
                }
            }
        }

        let degrees = FrameGeometry.clockwiseRotation(for: image.orientation)
        guard degrees != 0 else { return (argb, width, height) }
        let rotatedWidth = degrees == 180 ? width : height
        let rotatedHeight = degrees == 180 ? height : width
        let constant = FrameGeometry.rotationConstant(degrees: degrees)
        var rotated = [UInt8](repeating: 255, count: rotatedWidth * rotatedHeight * 4)
        var background: [UInt8] = [255, 0, 0, 0]
        try argb.withUnsafeMutableBytes { sourceBytes in
            try rotated.withUnsafeMutableBytes { destinationBytes in
                var source = vImage_Buffer(
                    data: sourceBytes.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 4
                )
                var destination = vImage_Buffer(
                    data: destinationBytes.baseAddress, height: vImagePixelCount(rotatedHeight),
                    width: vImagePixelCount(rotatedWidth), rowBytes: rotatedWidth * 4
                )
                let error = vImageRotate90_ARGB8888(
                    &source, &destination, constant, &background, vImage_Flags(kvImageNoFlags)
                )
                guard error == kvImageNoError else { throw CaptureError.vImage("回転", error) }
            }
        }
        return (rotated, rotatedWidth, rotatedHeight)
    }

    /// 表示の向きの JPEG（品質 `quality`）。
    public static func jpeg(_ image: SnapshotImage, quality: Double = 0.7) throws -> Data {
        let (pixels, width, height) = try argb(image)
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { throw CaptureError.jpeg("画像の準備") }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { throw CaptureError.jpeg("書き出しの準備") }
        let options = [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.jpeg("書き出し") }
        return output as Data
    }
}
