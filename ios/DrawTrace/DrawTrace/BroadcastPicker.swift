import ReplayKit
import SwiftUI

/// 録画を始める・止めるボタン。押すと、この録画拡張だけを選んだ状態のシステムのシートが出る。
///
/// 【11/7】システムのボタン（RPSystemBroadcastPickerView）は、中のアイコンが中心からずれることがあり、
/// 中のボタンの大きさを直そうとするとアイコンが消えた。そこで、見た目は自分で描き（二重丸を真ん中に）、
/// 押したときに、見えないところに置いたシステムのボタンを押したことにする。システムのボタンの中身は変えない。
struct BroadcastButton: View {
    var size: CGFloat = 60
    @State private var holder = BroadcastPickerHolder()

    var body: some View {
        Button { holder.show() } label: {
            Image(systemName: "record.circle")
                .font(.system(size: size * 0.5, weight: .regular))
                .foregroundStyle(TraceStyle.green)
                .frame(width: size, height: size)
                .background(TraceStyle.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(TraceButtonStyle())
        // システムのボタンは画面の中に置く（シートを出すため）。小さく、ほぼ透明にして、触れないようにする
        .background(alignment: .center) {
            BroadcastPicker(holder: holder)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("画面のブロードキャスト")
        .accessibilityIdentifier("work.broadcast")
    }
}

/// 見えないところに置いたシステムのボタンを持ち、押したことにする。
@MainActor
final class BroadcastPickerHolder {
    weak var picker: RPSystemBroadcastPickerView?

    func show() {
        guard let picker else { return }
        for case let button as UIButton in picker.subviews {
            button.sendActions(for: .allEvents)
        }
    }
}

/// システムのボタン（RPSystemBroadcastPickerView）。中身は変えない。
struct BroadcastPicker: UIViewRepresentable {
    static let extensionBundleID = "com.ggdevfest2026.drawtrace.broadcast"
    let holder: BroadcastPickerHolder

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = Self.extensionBundleID
        picker.showsMicrophoneButton = false
        holder.picker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        holder.picker = uiView
    }
}
