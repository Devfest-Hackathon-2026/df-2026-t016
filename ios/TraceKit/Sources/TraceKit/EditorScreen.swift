import Foundation

/// 【11/6】編集画面の判定の値（`shared/params/editor_screen.json` と同じ。変えるときは両方を直す）。
public struct EditorScreenConfig: Equatable {
    /// 見本を当てる位置（表示の向き、長辺1024px のときの画素。左上から）。
    public var regionX = 0
    public var regionY = 0
    /// 見本の地の色（最頻値）より、これ以上明るい画素を「明るい画素」（文字とアイコン）とする。
    public var brightDelta = 40
    /// 地の色から、これ以内の画素を「地の画素」とする。
    public var darkBand = 6
    /// 明るい画素・地の画素が「ほぼ同じ」とみなす明るさの差。
    public var brightTol = 24
    public var darkTol = 8
    /// 「ほぼ同じ」の割合がこれ以上なら、編集画面。
    public var brightMin = 0.60
    public var darkMin = 0.90

    public init() {}
}

/// 判定の結果。`bright`・`dark` は「ほぼ同じ」だった割合（確認の表示と、値の調整に使う）。
public struct EditorMatch: Equatable {
    public var bright: Double
    public var dark: Double
    public var isEditor: Bool

    public static let none = EditorMatch(bright: 0, dark: 0, isEditor: false)
}

/// 【11/6】Procreate の編集画面かどうかを、上のバーの左側（「Gallery」と4つのボタン）を見本と比べて決める（AI は使わない）。
///
/// - 見本（`EditorTemplate`）は、実機のスクリーンショットから `tools/editor_template/make_template.py` で作る。
/// - 見本の画素を、明るい画素（文字とアイコン）と地の画素に分け、それぞれ「ほぼ同じ」の割合を数える。
///   明るい画素だけ、または地の画素だけで比べると、真っ暗な画面などが編集画面に見えてしまうため。
/// - 右側（ブラシ・指先・消しゴム・レイヤー・色）とサイドバーは、使うと見た目が変わるので見本に入れない。
public final class EditorScreenDetector {
    public let config: EditorScreenConfig
    public let templateWidth: Int
    public let templateHeight: Int
    /// 見本の地の色。
    public let barColor: Int
    private let brightPoints: [(x: Int, y: Int, value: Int)]
    private let darkPoints: [(x: Int, y: Int, value: Int)]

    public init(
        config: EditorScreenConfig = EditorScreenConfig(),
        template: [UInt8] = EditorTemplate.pixels,
        templateWidth: Int = EditorTemplate.width,
        templateHeight: Int = EditorTemplate.height
    ) {
        precondition(template.count == templateWidth * templateHeight, "見本の大きさが合いません")
        self.config = config
        self.templateWidth = templateWidth
        self.templateHeight = templateHeight

        var histogram = [Int](repeating: 0, count: 256)
        for value in template {
            histogram[Int(value)] += 1
        }
        var mode = 0
        for value in 1..<256 where histogram[value] > histogram[mode] {
            mode = value
        }
        barColor = mode

        var bright: [(x: Int, y: Int, value: Int)] = []
        var dark: [(x: Int, y: Int, value: Int)] = []
        for y in 0..<templateHeight {
            for x in 0..<templateWidth {
                let value = Int(template[y * templateWidth + x])
                if value >= mode + config.brightDelta {
                    bright.append((x, y, value))
                } else if abs(value - mode) <= config.darkBand {
                    dark.append((x, y, value))
                }
            }
        }
        brightPoints = bright
        darkPoints = dark
    }

    /// 表示の向きのグレースケール画像（長辺1024px）で判定する。
    public func match(_ image: GrayImage) -> EditorMatch {
        image.pixels.withUnsafeBufferPointer { buffer in
            match(pixels: buffer.baseAddress!, width: image.width, height: image.height, rowBytes: image.width, rotation: 0)
        }
    }

    /// バッファの向きの Y 面（長辺1024px）で判定する。`rotation` は、表示の向きにするために時計回りに回す角度。
    /// 画面全体を回さず、見本の画素の位置だけをバッファの向きに直して読む（0.5秒ごとに呼ぶため）。
    public func match(
        pixels: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int, rotation: Int
    ) -> EditorMatch {
        let display = FrameGeometry.displaySize(bufferWidth: width, bufferHeight: height, rotation: rotation)
        guard
            display.width >= config.regionX + templateWidth,
            display.height >= config.regionY + templateHeight,
            !brightPoints.isEmpty, !darkPoints.isEmpty
        else { return .none }

        func value(_ x: Int, _ y: Int) -> Int {
            let point = FrameGeometry.bufferPoint(
                x: config.regionX + x, y: config.regionY + y, bufferWidth: width, bufferHeight: height, rotation: rotation
            )
            return Int(pixels[point.y * rowBytes + point.x])
        }

        var brightHits = 0
        for point in brightPoints where abs(value(point.x, point.y) - point.value) <= config.brightTol {
            brightHits += 1
        }
        var darkHits = 0
        for point in darkPoints where abs(value(point.x, point.y) - point.value) <= config.darkTol {
            darkHits += 1
        }
        let bright = Double(brightHits) / Double(brightPoints.count)
        let dark = Double(darkHits) / Double(darkPoints.count)
        return EditorMatch(bright: bright, dark: dark, isEditor: bright >= config.brightMin && dark >= config.darkMin)
    }
}
