import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import XCTest
@testable import TraceKit

/// 試験で使う画像の読み込みと、フレームの合成（【11/6】実機のスクリーンショットを使う試験のため）。
enum TestImages {
    enum Failure: Error { case load(String), context, pixelBuffer(Int32) }

    /// `shared/vectors/whole_canvas/real/` の実機の画面。
    static func real(_ name: String) -> URL {
        VectorsTests.repoRoot.appendingPathComponent("shared/vectors/whole_canvas/real/\(name)")
    }

    /// 画像をグレースケールで読み、`width`×`height` にする（CoreGraphics で縮小する）。
    static func loadGray(_ url: URL, width: Int, height: Int) throws -> GrayImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.load(url.lastPathComponent) }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.context }
        return GrayImage(pixels: pixels, width: width, height: height)
    }

    /// 長辺を `longSide` にして読む（Python の `round` と同じく、短い辺は四捨五入）。
    static func loadGray(_ url: URL, longSide: Int = 1024) throws -> GrayImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure.load(url.lastPathComponent) }
        let scale = Double(longSide) / Double(max(width, height))
        return try loadGray(
            url,
            width: Int((Double(width) * scale).rounded()),
            height: Int((Double(height) * scale).rounded())
        )
    }

    /// 反時計回りに90度回す（横持ちの表示の画面から、実機と同じ縦長のバッファを作るため。
    /// このバッファを時計回りに90度回すと、もとの表示に戻る）。
    static func rotateCounterClockwise(_ image: GrayImage) -> GrayImage {
        let width = image.height
        let height = image.width
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // バッファの (x, y) を時計回りに回すと、表示の (width - 1 - y, x)
                let display = FrameGeometry.displayPoint(x: x, y: y, bufferWidth: width, bufferHeight: height, rotation: 90)
                pixels[y * width + x] = image[display.x, display.y]
            }
        }
        return GrayImage(pixels: pixels, width: width, height: height)
    }

    /// Y 面をグレースケールの画像、CbCr を 128（無彩色）にした `420f` のバッファ。
    static func pixelBuffer(
        _ image: GrayImage, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, format, nil, &created)
        guard status == kCVReturnSuccess, let buffer = created else { throw Failure.pixelBuffer(status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<image.height {
            for column in 0..<image.width {
                y[row * yStride + column] = image[column, row]
            }
        }
        let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            for column in 0..<(CVPixelBufferGetWidthOfPlane(buffer, 1) * 2) {
                c[row * cStride + column] = 128
            }
        }
        return buffer
    }

    /// `image` の (x0, y0) から w×h を `value` で塗ったもの。
    static func painting(_ image: GrayImage, x0: Int, y0: Int, w: Int, h: Int, value: UInt8) -> GrayImage {
        var result = image
        for y in max(0, y0)..<min(image.height, y0 + h) {
            for x in max(0, x0)..<min(image.width, x0 + w) {
                result.pixels[y * image.width + x] = value
            }
        }
        return result
    }

    /// ホーム画面のつもりの画面（なめらかに変わる模様）。
    static func homeLike(width: Int, height: Int) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8(truncatingIfNeeded: 60 + (x * 3 + y * 2) / 8 % 160)
            }
        }
        return GrayImage(pixels: pixels, width: width, height: height)
    }
}
