import SwiftUI

private struct TraceOrderedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var traceOrdered: Bool {
        get { self[TraceOrderedKey.self] }
        set { self[TraceOrderedKey.self] = newValue }
    }
}

struct TraceBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(TraceStyle.green)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(TraceStyle.mint, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct WorkThumbnail: View {
    let url: URL?
    var emptyText = "全体画像なし"
    var compact = false
    var ratio: CGFloat = 4 / 3
    /// 【T15b】キャンバスの四角形。あれば絵の部分だけを出す
    var crop: [Double]? = nil

    var body: some View {
        SnapshotView(url: url, emptyText: emptyText, compact: compact, crop: crop)
            .aspectRatio(ratio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TraceStyle.line, lineWidth: 0.75))
    }
}

struct TraceButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(!enabled ? 0.45 : configuration.isPressed ? 0.72 : 1)
    }
}

struct TraceTabs: View {
    let titles: [String]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 24) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button { selection = index } label: {
                    Text(title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == index ? TraceStyle.text : TraceStyle.muted)
                        .padding(.vertical, 14)
                        .frame(minWidth: 44, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if selection == index { Rectangle().fill(TraceStyle.green).frame(height: 2) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == index ? [.isSelected] : [])
                .accessibilityIdentifier("work.tab.\(index)")
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(TraceStyle.line).frame(height: 1).offset(y: 1) }
    }
}

struct TraceSectionTitle: View {
    let title: String
    let systemImage: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage).font(.subheadline).foregroundStyle(TraceStyle.green)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(TraceStyle.text)
            Spacer()
        }
    }
}
