import ImageIO
import SwiftUI
import TraceKit

/// 【Canvault】iPad本体の表示色。地は黒、アクセントは緑の1色（検証ページの style.css と同じ値）。
/// 作品画像の色はそのまま表示する。
enum TraceStyle {
    static let background = Color.black                                    // #000000
    static let panel = Color(red: 0.086, green: 0.086, blue: 0.090)        // #161617
    static let surface = Color(red: 0.114, green: 0.114, blue: 0.122)      // #1d1d1f
    static let green = Color(red: 0.188, green: 0.820, blue: 0.345)        // #30d158
    static let secondaryGreen = Color(red: 0.494, green: 0.851, blue: 0.612) // #7ed99c
    static let mint = Color(red: 0.059, green: 0.165, blue: 0.094)         // #0f2a18（緑の札の地）
    static let onGreen = Color.black                                       // 緑のボタンの上の文字
    static let text = Color(red: 0.961, green: 0.961, blue: 0.969)         // #f5f5f7
    static let muted = Color(red: 0.631, green: 0.631, blue: 0.651)        // #a1a1a6
    static let line = Color(red: 0.184, green: 0.184, blue: 0.196)         // #2f2f32
    static let error = Color(red: 1.0, green: 0.624, blue: 0.420)          // #ff9f6b
}

/// 画面の地。【Canvault】飾り（波模様）はやめて黒一色にした
struct TraceBackground: View {
    var body: some View {
        TraceStyle.background
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct TracePanel<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(TraceStyle.green) }
                Text(title).foregroundStyle(TraceStyle.text)
            }.font(.title3.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(TraceStyle.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(TraceStyle.line))
    }
}

struct WorkStatusBadge: View {
    let work: WorkDetail
    private var isDraft: Bool { work.status == "draft" }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(isDraft ? TraceStyle.muted : TraceStyle.green).frame(width: 4, height: 4)
            Text(work.statusTitle).font(.caption.weight(.medium))
        }
        .foregroundStyle(isDraft ? TraceStyle.muted : TraceStyle.green)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(isDraft ? TraceStyle.surface : TraceStyle.mint, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct SnapshotView: View {
    let url: URL?
    var emptyText = "全体画像なし"
    var compact = false
    /// 【T15b】キャンバスの四角形（`WholeItem.rect`）。あれば表示のときだけ切り抜く（保存した画像は変えない）
    var crop: [Double]? = nil
    @State private var localImage: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TraceStyle.surface
                if let url, !url.isFileURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else if phase.error != nil { placeholder }
                        else { ProgressView().tint(TraceStyle.green) }
                    }
                } else if let localImage {
                    Image(uiImage: localImage).resizable().scaledToFit()
                } else { placeholder }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: SnapshotKey(url: url, crop: crop)) {
            localImage = nil
            guard let url, url.isFileURL else { return }
            let crop = crop
            localImage = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1200
                      ] as CFDictionary) else { return nil as UIImage? }
                // 四角形が使えなければ、元の画像をそのまま出す
                if let rect = CanvasCrop.pixelRect(crop, width: image.width, height: image.height),
                   let cropped = image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) {
                    return UIImage(cgImage: cropped)
                }
                return UIImage(cgImage: image)
            }.value
        }
        .accessibilityLabel(url == nil ? emptyText : "記録した全体画像")
    }

    private struct SnapshotKey: Equatable {
        let url: URL?
        let crop: [Double]?
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: compact ? 17 : 30, weight: .light))
                .foregroundStyle(TraceStyle.secondaryGreen)
            if !compact {
                Text(emptyText).font(.caption).multilineTextAlignment(.center)
                    .foregroundStyle(TraceStyle.muted).padding(.horizontal, 16)
            }
        }
    }
}

struct InlineNotice: View {
    let text: String
    var isError = false
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "info.circle")
            .font(.subheadline)
            .foregroundStyle(isError ? TraceStyle.error : TraceStyle.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(isError ? TraceStyle.error.opacity(0.12) : TraceStyle.surface,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(TraceStyle.line))
            .accessibilityIdentifier(isError ? "notice.error" : "notice.info")
    }
}

struct TraceBrand: View {
    var size: CGFloat = 44
    var iconSize: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    var body: some View {
        HStack(spacing: 12) {
            // 【Canvault】ロゴの画像は白い背景を透過にした（黒い地の上にそのまま置く）
            Image("DrawTraceBrand")
                .resizable().scaledToFit().frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text("Canvault")
                .font(.system(size: size * typeScale, weight: .bold))
                .tracking(-size * 0.035)
                .foregroundStyle(TraceStyle.text)
                .lineLimit(1).minimumScaleFactor(0.65)
                .accessibilityIdentifier("brand.name")
        }
    }
}

enum TraceDate {
    static let locale = Locale(identifier: "ja_JP")
    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar
    }
    static func date(_ text: String) -> String {
        guard let date = Canonical.parseTime(text) else { return "日時を確認できません" }
        return date.formatted(.dateTime.year().month().day().locale(locale))
    }
    static func time(_ text: String) -> String {
        Canonical.parseTime(text)?.formatted(.dateTime.hour().minute().second().locale(locale)) ?? "—"
    }
    static func dayNumber(_ date: Date) -> String {
        String(format: "%02d", calendar.component(.day, from: date))
    }
}
