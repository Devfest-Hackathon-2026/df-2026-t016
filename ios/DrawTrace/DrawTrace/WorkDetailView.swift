import PhotosUI
import SwiftUI
import TraceKit
import UniformTypeIdentifiers

struct WorkDetailView: View {
    @StateObject private var model: WorkDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 1
    @State private var showImporter = false
    @State private var photo: PhotosPickerItem?
    @State private var showDelete = false
    @State private var copied = false
    @State private var showEndScreen = false
    @State private var action: Task<Void, Never>?

    init(work: WorkDetail, library: LibraryModel) {
        _model = StateObject(wrappedValue: WorkDetailModel(work: work, library: library))
        // 【T14】記録を足したり提出したりするのは「記録」のタブ。確定済みだけカレンダーから
        _selectedTab = State(initialValue: work.status == "finalized" ? 1 : 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                TraceTabs(titles: ["記録", "カレンダー"], selection: $selectedTab)
                    .disabled(model.recordingActive)
                if let message = model.errorMessage { InlineNotice(text: message, isError: true) }
                if selectedTab == 0 || model.recordingActive {
                    workflow
                    if !model.days.isEmpty && !model.recordingActive {
                        Button { selectedTab = 1 } label: {
                            HStack {
                                Label("履歴", systemImage: "calendar")
                                Spacer()
                                Text("\(model.days.count)日").foregroundStyle(TraceStyle.muted)
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(18).background(TraceStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                } else {
                    Button { selectedTab = 0 } label: {
                        HStack {
                            Label(model.work.status == "finalized" ? "共有" : "記録・提出", systemImage: model.work.status == "finalized" ? "square.and.arrow.up" : "record.circle")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.subheadline.weight(.semibold)).padding(16)
                        .background(TraceStyle.mint.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TraceStyle.green.opacity(0.35)))
                    }.buttonStyle(TraceButtonStyle()).foregroundStyle(TraceStyle.green)
                    WorkCalendarView(work: model.work, days: model.days, store: model.library.store)
                }
            }
            .frame(maxWidth: 960)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background { TraceBackground() }
        .foregroundStyle(TraceStyle.text)
        .navigationTitle(model.work.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("最新の状態を確認", systemImage: "arrow.clockwise") { Task { await model.reload() } }
                    Button("作品を削除", systemImage: "trash", role: .destructive) { showDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(model.busy)
            }
        }
        .confirmationDialog("この作品を削除しますか？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("作品を削除する", role: .destructive) {
                action = Task { if await model.delete() { dismiss() } }
            }
        } message: { Text("依頼主がすでにダウンロードした証拠は消せません。") }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.png]) { result in
            action = Task {
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 30 * 1024 * 1024 else {
                        model.errorMessage = "ファイルが大きすぎます。PNG は30MB以下で選んでください"
                        return
                    }
                    await model.upload(png: try Data(contentsOf: url, options: .mappedIfSafe))
                } catch CocoaError.userCancelled { }
                catch { model.errorMessage = "ファイルを読み込めませんでした。もう一度選んでください" }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            action = Task {
                defer { photo = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        model.errorMessage = "写真を読み込めませんでした。PNGをファイルから選んでください"
                        return
                    }
                    await model.upload(png: data)
                } catch { model.errorMessage = "写真を読み込めませんでした。もう一度選んでください" }
            }
        }
        .task { await model.run() }
        .onDisappear { action?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            TraceBrand(size: 36, iconSize: 46)
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RECORD").font(.caption2.weight(.semibold))
                        .tracking(2).foregroundStyle(TraceStyle.muted)
                    Text(model.work.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("\(model.work.displayName) ・ \(TraceDate.date(model.work.createdAt))")
                        .font(.caption).foregroundStyle(TraceStyle.muted)
                    WorkStatusBadge(work: model.work)
                }
                Spacer(minLength: 0)
                if !model.recordingActive {
                    let snapshot = model.work.snapshot(store: model.library.store)
                    WorkThumbnail(url: snapshot?.url, compact: true, crop: snapshot?.crop)
                        .frame(width: 120)
                }
            }
        }
    }

    @ViewBuilder private var workflow: some View {
        switch model.phase {
        case .ready: ready
        case .recording: recording
        case .sending: sending
        case .submit: submission
        case .finalizing: finalizing
        case .finalized: finalized
        }
    }

    /// 【T14】記録の一覧・録画（準備／記録を追加）・提出へ
    private var ready: some View {
        VStack(spacing: 20) {
            preparation
            if !model.summaries.isEmpty {
                recordList
                submitEntry
            }
        }
    }

    private var preparation: some View {
        TracePanel(title: model.summaries.isEmpty ? "録画" : "記録を追加", systemImage: "record.circle") {
            HStack(spacing: 16) {
                Button {
                    action = Task { await model.prepare() }
                } label: {
                    Label(model.readyToRecord ? "再準備" : model.summaries.isEmpty ? "準備" : "\(model.summaries.count + 1)回目を準備",
                          systemImage: model.summaries.isEmpty ? "record.circle" : "plus.circle")
                }
                .buttonStyle(.borderedProminent).foregroundStyle(TraceStyle.onGreen).controlSize(.large)
                .disabled(!model.canAddRecord && !model.readyToRecord)
                .accessibilityIdentifier("work.prepare")
                if model.busy { ProgressView() }
                if model.readyToRecord {
                    Label("準備完了", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(TraceStyle.green)
                }
            }
            Text("停止すると、その回の記録だけを保存します").font(.caption).foregroundStyle(TraceStyle.muted)
            if model.otherRecordingActive { InlineNotice(text: "別の作品を録画中") }
            if let expiry = model.expiry, model.readyToRecord || expiry <= model.now, model.work.session?.status == "created" {
                Text(expiry > model.now ? "有効期限 \(expiry.formatted(.dateTime.hour().minute()))" : "有効期限切れ")
                    .font(.caption).foregroundStyle(TraceStyle.muted)
            }
            if model.readyToRecord {
                Divider().overlay(TraceStyle.line)
                HStack {
                    pickerRow
                    Spacer()
                    Button { Task { await model.reload() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }.accessibilityLabel("録画状態を更新")
                }
                if let error = model.status?.lastError { InlineNotice(text: error, isError: true) }
            }
        }
    }

    private var recordList: some View {
        TracePanel(title: "記録 \(model.summaries.count)回", systemImage: "square.stack") {
            VStack(spacing: 0) {
                ForEach(model.summaries) { summary in
                    HStack(spacing: 16) {
                        WorkThumbnail(url: summary.lastSnapshot.flatMap { model.imageURL(sid: summary.sid, sha: $0.sha) },
                                      compact: true, crop: summary.lastSnapshot?.rect)
                            .frame(width: 72)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(summary.index + 1)回目").font(.headline)
                            if let start = summary.startedAt {
                                Text(recordInterval(start, summary.lastReceivedAt))
                                    .font(.system(.caption).monospacedDigit()).foregroundStyle(TraceStyle.muted)
                            }
                            HStack(spacing: 8) {
                                TraceBadge(text: summary.final ? "保存済み" : "停止を受信していません")
                                Text("全体画像 \(summary.snapshots.count)枚").font(.caption).foregroundStyle(TraceStyle.muted)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Rectangle().fill(TraceStyle.line).frame(height: 1) }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("work.record.\(summary.index)")
                }
            }
        }
    }

    private var submitEntry: some View {
        TracePanel(title: "提出", systemImage: "paperplane") {
            Button { model.beginSubmit() } label: {
                Label("提出へ", systemImage: "arrow.right")
            }
            .buttonStyle(.borderedProminent).tint(TraceStyle.green).foregroundStyle(TraceStyle.onGreen).controlSize(.large)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier("work.submit")
        }
    }

    private func recordInterval(_ start: Date, _ end: Date?) -> String {
        let day = start.formatted(.dateTime.month().day().locale(TraceDate.locale))
        let from = start.formatted(.dateTime.hour().minute().locale(TraceDate.locale))
        guard let end else { return "\(day) \(from) —" }
        return "\(day) \(from) — \(end.formatted(.dateTime.hour().minute().locale(TraceDate.locale)))"
    }

    private var recording: some View {
        TracePanel(title: "\(max(model.startedSids.count, 1))回目を録画中", systemImage: "record.circle") {
            Text("停止すると、その回の記録だけを保存します").font(.caption).foregroundStyle(TraceStyle.muted)
            recordingStats
            if let status = model.status {
                if status.state == .finishing { InlineNotice(text: "終了処理中") }
                if model.stale {
                    InlineNotice(text: "30秒以上更新なし")
                    Button { action = Task { await model.finishSending() } } label: {
                        Label("送信", systemImage: "arrow.up.circle")
                    }.buttonStyle(.borderedProminent).foregroundStyle(TraceStyle.onGreen).disabled(model.busy)
                }
                pickerRow
            } else {
                InlineNotice(text: "この端末に録画情報なし")
                Button { action = Task { await model.finishSending() } } label: {
                    Label("録画終了・次へ", systemImage: "arrow.right")
                }.buttonStyle(.borderedProminent).foregroundStyle(TraceStyle.onGreen).disabled(model.busy)
            }
            if model.busy { ProgressView(model.progressMessage) }
        }
    }

    private var sending: some View {
        TracePanel(title: "記録を保存", systemImage: "arrow.up.circle") {
            recordingStats
            Text(model.progressMessage).foregroundStyle(TraceStyle.muted)
            if model.busy { ProgressView() }
            Button { action = Task { await model.finishSending() } } label: {
                Label("送信", systemImage: "arrow.up")
            }.buttonStyle(.borderedProminent).foregroundStyle(TraceStyle.onGreen).controlSize(.large).disabled(model.busy)
        }
    }

    private var recordingStats: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 30) {
                metric("送信済み", "\(model.sentCount)件", TraceStyle.green)
                metric("未送信", "\(model.queuedCount)件", TraceStyle.green)
                metric("未送信の画像", "\(model.pendingImages)枚", TraceStyle.green)
            }
            if let status = model.status {
                LabeledContent("録画の状態", value: stateTitle(status.state)).font(.subheadline)
                LabeledContent("途中の全体画像", value: "\(status.wholeCount)枚").font(.subheadline)
                if let error = status.lastError { InlineNotice(text: error, isError: true) }
            }
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption).foregroundStyle(TraceStyle.muted)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
    }

    private func stateTitle(_ state: BroadcastState) -> String {
        switch state {
        case .starting: return "開始の登録中"
        case .recording: return "記録中"
        case .finishing: return "終了処理中"
        case .finished: return "終了"
        case .error: return "エラーで終了"
        }
    }

    private var pickerRow: some View {
        HStack(spacing: 18) {
            BroadcastButton()
            Text("開始・停止").font(.headline)
        }
    }

    private var submission: some View {
        VStack(spacing: 20) {
            HStack {
                Button { model.endSubmit() } label: { Label("記録に戻る", systemImage: "chevron.left") }
                    .buttonStyle(.bordered).disabled(model.busy).accessibilityIdentifier("work.submit.back")
                Spacer()
                Text("\(model.summaries.count)回の記録をまとめて提出").font(.subheadline).foregroundStyle(TraceStyle.muted)
            }
            // 【11/8】何を提出するのかを明記する（公開ページにも同じ値が出る）
            TracePanel(title: "提出する作品", systemImage: "doc.text") {
                infoRow("タイトル", model.work.title)
                infoRow("制作者", model.work.displayName)
            }
            TracePanel(title: "PNG", systemImage: "photo") {
                HStack(spacing: 16) {
                    Button { showImporter = true } label: { Label("ファイル", systemImage: "folder") }
                        .buttonStyle(.borderedProminent).foregroundStyle(TraceStyle.onGreen)
                    PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                        Label("写真", systemImage: "photo")
                    }.buttonStyle(.bordered)
                }.controlSize(.large).disabled(model.busy)
                Text("PNG · 30MBまで")
                    .font(.caption).foregroundStyle(TraceStyle.muted)
                if let preview = model.uploadedPreview {
                    Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 300)
                        .frame(maxWidth: .infinity).background(TraceStyle.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if let png = model.work.png {
                    Label("取り込み済み：\(png.width) × \(png.height) px", systemImage: "photo")
                        .font(.subheadline).foregroundStyle(TraceStyle.green)
                }
            }
            if model.work.png != nil {
                TracePanel(title: "終了画像", systemImage: "viewfinder") {
                    if let end = model.endImageURL {
                        // 【T15b】絵の部分だけを出す。照合に使うのは元の画面なので、切り替えて全体も見られる
                        SnapshotView(url: end, crop: showEndScreen ? nil : model.endImageRect)
                            .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 14))
                        if model.endImageRect != nil {
                            Toggle("元の画面", isOn: $showEndScreen)
                                .font(.subheadline).tint(TraceStyle.green).fixedSize()
                                .accessibilityIdentifier("work.endImage.screen")
                        }
                        HStack(spacing: 16) {
                            Button { model.useEndImage = true } label: {
                                Label("照合する", systemImage: model.useEndImage == true ? "largecircle.fill.circle" : "circle")
                            }.tint(TraceStyle.green).accessibilityIdentifier("work.endImage.use")
                            Button { model.useEndImage = false } label: {
                                Label("照合に使わない", systemImage: model.useEndImage == false ? "largecircle.fill.circle" : "circle")
                            }.accessibilityIdentifier("work.endImage.skip")
                        }.buttonStyle(.bordered).disabled(model.busy)
                        if model.useEndImage == false {
                            InlineNotice(text: "外観照合：未確認")
                        }
                    } else {
                        InlineNotice(text: "この端末に終了画像なし")
                    }
                }
                if !model.wholeImages.isEmpty {
                    TracePanel(title: "公開画像", systemImage: "photo.on.rectangle") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(Array(model.wholeImages.enumerated()), id: \.offset) { _, image in
                                    VStack(alignment: .leading, spacing: 6) {
                                        SnapshotView(url: model.imageURL(sid: image.summary.sid, sha: image.item.sha),
                                                     crop: image.item.rect)
                                            .frame(width: 140, height: 160)
                                        Text("\(image.summary.index + 1)回目 ・ \(TraceDate.time(image.item.frameTime))").font(.caption2)
                                    }
                                }
                            }
                        }
                        Toggle("途中画像を公開（\(model.wholeImages.count)枚）", isOn: $model.showWhole)
                            .tint(TraceStyle.green).disabled(model.busy)
                            .accessibilityIdentifier("work.showWhole")
                        Text("開始・終了画像は常に公開")
                            .font(.caption).foregroundStyle(TraceStyle.muted)
                    }
                }
                TracePanel(title: "作者の申告", systemImage: "signature") {
                    declarationPicker
                    Button { action = Task { await model.finalize() } } label: {
                        Label("確定する", systemImage: "arrow.up.right.square")
                    }.buttonStyle(.borderedProminent).tint(TraceStyle.green).foregroundStyle(TraceStyle.onGreen).controlSize(.large)
                        .disabled(model.busy || !model.declarationReady || (model.endImageURL != nil && model.useEndImage == nil))
                        .accessibilityIdentifier("work.finalize")
                    Text("確定すると、記録を追加できません").font(.caption).foregroundStyle(TraceStyle.muted)
                    waitProgress
                }
            }
            if model.busy && model.retrySeconds == 0 { ProgressView("処理しています") }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(.subheadline).foregroundStyle(TraceStyle.muted).frame(width: 72, alignment: .leading)
            Text(value).font(.headline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// 【11/8】作者の申告（版2）: AI の使い方を3つから選び、詳細は任意で書く。公開ページにそのまま載る
    private var declarationPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("この作品の制作に AI を使いましたか").font(.subheadline).foregroundStyle(TraceStyle.muted)
            HStack(spacing: 12) {
                ForEach(AIUse.allCases) { use in
                    let selected = model.aiUse == use
                    Button { model.aiUse = use } label: {
                        Label(use.label, systemImage: selected ? "largecircle.fill.circle" : "circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? TraceStyle.text : TraceStyle.muted)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(selected ? TraceStyle.mint : TraceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? TraceStyle.green : TraceStyle.line, lineWidth: selected ? 2 : 1))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("work.declaration.\(use.rawValue)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            if let use = model.aiUse {
                Text(use.text).font(.body).accessibilityIdentifier("work.declaration.text")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("詳細（任意）").font(.caption).foregroundStyle(TraceStyle.muted)
                TextField("例: 背景の案出しに画像生成 AI を使いました。線画と塗りは手描きです。", text: $model.declarationDetail, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(TraceStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TraceStyle.line))
                    .accessibilityIdentifier("work.declaration.detail")
                HStack {
                    Text("申告と詳細は公開ページにそのまま載ります。運営は内容を確かめません。")
                    Spacer(minLength: 8)
                    Text("\(model.detailLength) / \(AuthorDeclaration.maxDetail)").monospacedDigit()
                        .foregroundStyle(model.detailLength > AuthorDeclaration.maxDetail ? TraceStyle.error : TraceStyle.muted)
                }
                .font(.caption).foregroundStyle(TraceStyle.muted)
            }
        }
        .disabled(model.busy)
    }

    private var finalizing: some View {
        TracePanel(title: "確定中", systemImage: "arrow.clockwise") {
            waitProgress
            if model.busy { ProgressView("確定しています") }
            else {
                Button("もう一度試す") { action = Task { await model.finalize(resuming: true) } }
                    .buttonStyle(.borderedProminent).foregroundStyle(TraceStyle.onGreen)
            }
        }
    }

    @ViewBuilder private var waitProgress: some View {
        if model.retrySeconds > 0 {
            ProgressView("最後の記録を待っています（あと\(model.retrySeconds)秒）")
                .font(.subheadline).monospacedDigit()
        }
    }

    private var finalized: some View {
        VStack(spacing: 20) {
            TracePanel(title: "共有", systemImage: "square.and.arrow.up") {
                HStack {
                    Text("外観照合").font(.subheadline)
                    Spacer()
                    Text(model.work.match?.title ?? "未確認").font(.title2.weight(.semibold))
                        .foregroundStyle(model.work.match?.result == "match" ? TraceStyle.green : TraceStyle.muted)
                }
                if let reason = model.work.match?.reason { Text(reason).foregroundStyle(TraceStyle.muted) }
                LabeledContent("記録", value: "\(model.summaries.count)回").font(.subheadline)
                if model.completionStatus == "aborted" { InlineNotice(text: "停止を受信していない記録を含めて確定しました。公開ページで記録ごとの終了状況を確認できます。") }
                if let url = model.publicURL {
                    Text(url.absoluteString).font(.footnote.monospaced()).textSelection(.enabled)
                        .foregroundStyle(TraceStyle.muted)
                    HStack(spacing: 16) {
                        ShareLink(item: url) { Label("リンクを共有", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent).tint(TraceStyle.green).foregroundStyle(TraceStyle.onGreen)
                        Button {
                            UIPasteboard.general.url = url
                            copied = true
                        } label: { Label(copied ? "コピーしました" : "コピー", systemImage: "doc.on.doc") }
                            .buttonStyle(.bordered)
                        Link(destination: url) { Label("ページを開く", systemImage: "safari") }.buttonStyle(.bordered)
                    }.controlSize(.large)
                } else { InlineNotice(text: "共有リンクを作れません。Hostingの接続先を確認してください。", isError: true) }
            }
            if let explanation = model.work.explanation {
                TracePanel(title: "補足説明") {
                    Text(explanation.text).font(.subheadline).foregroundStyle(TraceStyle.muted)
                    Toggle("補足説明をページに載せる", isOn: Binding(
                        get: { model.work.explanation?.included ?? false },
                        set: { value in action = Task { await model.setExplanation(value) } }
                    )).tint(TraceStyle.green).disabled(model.busy)
                }
            }
        }
    }
}
