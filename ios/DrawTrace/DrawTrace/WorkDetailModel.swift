import Foundation
import ImageIO
import SwiftUI
import TraceKit

@MainActor
final class WorkDetailModel: ObservableObject {
    /// 【T14】ready: 記録の一覧と「記録を追加」。submit: 提出（PNG・申告・確定）。録画を止めても submit には進まない
    enum Phase { case ready, recording, sending, submit, finalizing, finalized }
    let library: LibraryModel
    @Published var work: WorkDetail
    @Published private(set) var status: BroadcastStatus?
    /// 記録（sid）ごとの全体画像の控え（`sessions/{sid}/whole.json`）
    @Published private(set) var records: [String: WholeRecord] = [:]
    /// 「提出へ」を押した（提出の画面を出している）
    @Published private(set) var submitting = false
    @Published private(set) var sentCount = 0
    @Published private(set) var queuedCount = 0
    @Published private(set) var pendingImages = 0
    @Published private(set) var busy = false
    @Published var errorMessage: String?
    @Published private(set) var progressMessage = ""
    @Published private(set) var retrySeconds = 0
    /// 【11/8】作者の申告（版2）: AI の使い方（未選択なら nil）と、任意の詳細
    @Published var aiUse: AIUse?
    @Published var declarationDetail = ""
    @Published var useEndImage: Bool?
    /// 途中画像を公開するか（【T14】記録ごとではなく作品ごと）
    @Published var showWhole = true {
        didSet { library.preferences.set(showWhole, forKey: "work.showWhole.\(work.workId)") }
    }
    @Published private(set) var now = Date()
    @Published var uploadedPreview: UIImage?
    @Published private(set) var completionStatus: String?
    private var lastRemoteRead = Date.distantPast
    private var autoResumeAttempted = false
    private var autoFlushAttempted = false

    init(work: WorkDetail, library: LibraryModel) {
        self.work = work
        self.library = library
        let legacy = work.session.map { "work.showWhole.\($0.sid)" }  // T14 より前は記録ごとに持っていた
        showWhole = library.preferences.object(forKey: "work.showWhole.\(work.workId)") as? Bool
            ?? legacy.flatMap { library.preferences.object(forKey: $0) as? Bool } ?? true
        refreshLocal()
    }

    /// いちばん新しい記録（録画の準備・録画中の状態はこれで見る）
    var sid: String? {
        work.session?.sid ?? library.store?.sessionCurrent.flatMap { $0.workId == work.workId ? $0.sid : nil }
    }
    /// 作品のすべての記録の sid（作った順）。サーバにまだ出ていない、この端末で準備した記録も含める
    var sids: [String] {
        var out = work.allSessions.map(\.sid)
        if let sid, !out.contains(sid) { out.append(sid) }
        return out
    }
    /// この端末で録画拡張が開始の登録をした（`start.json` がある）
    func registered(_ sid: String) -> Bool {
        guard let url = library.store?.startURL(sid: sid) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    /// 開始した記録の sid（作った順）。サーバが未開始でも、この端末で開始の登録をしたものは含める
    var startedSids: [String] {
        sids.filter { sid in
            let server = work.allSessions.first { $0.sid == sid }?.status
            return (server != nil && server != "created") || registered(sid)
        }
    }
    /// 一覧とカレンダー用の作品。この端末で開始した記録は、サーバがまだ `created` でも録画中として扱う
    private var effectiveWork: WorkDetail {
        var w = work
        var all = work.allSessions
        for sid in startedSids {
            if let i = all.firstIndex(where: { $0.sid == sid }) {
                if all[i].status == "created" { all[i].status = "recording" }
            } else {
                all.append(.init(sid: sid, status: "recording"))
            }
        }
        w.sessions = all
        return w
    }
    var recordingActive: Bool { RecordingPolicy.isActive(status, now: now) }
    /// 開始した記録のうち、この端末から送り終えたと確かめていないものがある
    var needsSending: Bool {
        queuedCount > 0 || pendingImages > 0 || startedSids.contains { !library.preferences.bool(forKey: "work.sent.\($0)") }
    }
    var phase: Phase {
        if work.status == "finalized" { return .finalized }
        if work.status == "finalizing" { return .finalizing }
        if recordingActive { return .recording }
        if needsSending { return .sending }
        if submitting { return .submit }
        return .ready
    }
    /// 記録を追加できる（録画中・未送信・ほかの作品の録画中は不可）
    var canAddRecord: Bool { !busy && !recordingActive && !needsSending && !otherRecordingActive }
    /// 提出へ進める（開始した記録が1つ以上あり、すべて送り終えている）
    var canSubmit: Bool { !busy && !startedSids.isEmpty && !recordingActive && !needsSending }
    var stale: Bool { status.map { RecordingPolicy.isStale($0, now: now) } ?? false }
    var summaries: [WorkRecordSummary] { WorkRecordSummary.make(work: effectiveWork, records: records) }
    var days: [WorkHistoryDay] { WorkHistoryDay.make(work: effectiveWork, records: records) }
    /// 提出で公開を選ぶ途中の全体画像（すべての記録、記録の順・撮った順）
    var wholeImages: [(summary: WorkRecordSummary, item: WholeItem)] {
        summaries.flatMap { s in (records[s.sid]?.items ?? []).map { (s, $0) } }
    }
    /// 照合に使う終了画像は、最後に開始した記録のもの
    var endImageURL: URL? {
        guard let store = library.store, let sid = startedSids.last, let sha = records[sid]?.end else { return nil }
        let url = store.directory(.images, sid: sid).appendingPathComponent("\(sha).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// 【T15b】終了画像のキャンバスの四角形（表示のときだけ切り抜く）
    var endImageRect: [Double]? {
        guard let sid = startedSids.last, let record = records[sid], let sha = record.end else { return nil }
        return record.rect(for: sha)
    }
    func imageURL(sid: String, sha: String) -> URL? {
        library.store?.directory(.images, sid: sid).appendingPathComponent("\(sha).jpg")
    }
    var expiry: Date? {
        guard let sid, let text = library.preferences.string(forKey: "work.expiry.\(sid)") else { return nil }
        return Canonical.parseTime(text)
    }
    var readyToRecord: Bool {
        guard let store = library.store, let current = store.sessionCurrent, current.workId == work.workId,
              current.sid == sid, let expiry else { return false }
        return expiry > now && !recordingActive && status?.state != .finished
            && !FileManager.default.fileExists(atPath: store.startURL(sid: current.sid).path)
    }
    var otherRecordingActive: Bool {
        guard let current = library.store?.broadcastStatus else { return false }
        return current.sid != sid && RecordingPolicy.isActive(current, now: now)
    }
    var publicURL: URL? {
        guard let id = work.publicId, let hosting = AppConfig.hostingURL else { return nil }
        return hosting.appendingPathComponent("p/\(id)")
    }

    /// SwiftUIのtaskが消えたらポーリングと待ち時間も止まる。再表示時はサーバの状態から再開する。
    func run() async {
        await reload()
        while !Task.isCancelled {
            refreshLocal()
            if phase == .finalizing && !autoResumeAttempted && !busy {
                autoResumeAttempted = true
                await finalize(resuming: true)
            } else if phase == .sending && !autoFlushAttempted && !busy {
                autoFlushAttempted = true
                await finishSending()
            }
            if now.timeIntervalSince(lastRemoteRead) >= 5 && !busy { await reload() }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }

    func refreshLocal() {
        now = Date()
        status = RecordingPolicy.matchingStatus(library.store?.broadcastStatus, sid: sid)
        guard let store = library.store else { return }
        var loaded: [String: WholeRecord] = [:]
        var queued = 0, pending = 0, receipts = 0
        for sid in sids {
            if let record = store.wholeRecord(sid: sid) { loaded[sid] = record }
            queued += ChunkSender.queueFiles(store: store, sid: sid).count
            pending += ChunkSender.pendingImages(store: store, sid: sid).count
        }
        if records != loaded { records = loaded }
        queuedCount = queued
        pendingImages = pending
        // 送信済みの件数は、いちばん新しい記録の分（録画中の表示に使う）
        if let sid {
            receipts = max(store.files(in: .receipts, sid: sid).count, work.session?.sid == sid ? work.session?.chunkCount ?? 0 : 0,
                           (status?.sentSeq ?? -1) + 1)
        }
        sentCount = receipts
        // 録画中か、送っていないものがある記録は「送り終えた」の印を外す
        for sid in sids where library.preferences.bool(forKey: "work.sent.\(sid)") {
            let active = sid == self.sid && recordingActive
            if active || !ChunkSender.queueFiles(store: store, sid: sid).isEmpty || !ChunkSender.pendingImages(store: store, sid: sid).isEmpty {
                library.preferences.set(false, forKey: "work.sent.\(sid)")
            }
        }
    }

    func reload() async {
        lastRemoteRead = Date()
        do {
            let (client, token) = try await library.connection()
            let updated = try await client.getWork(workId: work.workId, idToken: token)
            work = updated
            library.update(updated)
        } catch {
            if !Task.isCancelled { errorMessage = LibraryModel.message(error) }
        }
        refreshLocal()
    }

    func prepare() async {
        guard !busy else { return }
        guard let store = library.store else {
            errorMessage = "録画の保存先を開けません（App Group の設定を確認してください）"
            return
        }
        guard !RecordingPolicy.isActive(store.broadcastStatus) else {
            errorMessage = "録画が動いています。録画を止めてから準備してください"
            return
        }
        guard !needsSending else {
            errorMessage = "前の記録の送信が終わっていません。残りを送ってから追加してください"
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let (client, token) = try await library.connection()
            // 【T12】使い切りのトークンなので、送る直前に取る
            let appCheck = await library.appCheckToken()
            let created = try await client.createSession(workId: work.workId, idToken: token, appCheckToken: appCheck)
            try store.setSessionCurrent(SessionInfo(sid: created.sid, workId: work.workId,
                                                   startToken: created.startToken, apiBaseURL: client.baseURL.absoluteString,
                                                   createdAt: Canonical.timeString()))
            library.preferences.set(created.expiresAt, forKey: "work.expiry.\(created.sid)")
            let new = WorkDetail.Session(sid: created.sid, status: "created")
            work.sessions = work.startedSessions + [new]  // 未開始の記録はサーバが置き換える
            work.session = new
            autoFlushAttempted = false
            library.update(work)
            refreshLocal()
            await reload()
        } catch {
            errorMessage = LibraryModel.message(error)
            if let error = error as? APIError, error.code == "SESSION_EXISTS" || error.code == "ALREADY_FINALIZED" {
                await reload()
            }
        }
    }

    /// 開始した記録の残りを、作った順に送る（【T14】いちばん新しい記録だけでなく、すべて）。
    func finishSending() async {
        guard !busy, !startedSids.isEmpty else { return }
        refreshLocal()
        if let sid, !ChunkSender.shouldAppSend(status: library.store?.broadcastStatus, sid: sid) {
            progressMessage = "録画拡張が送信しています。最後の記録を待っています"
            autoFlushAttempted = false
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        progressMessage = "残っている記録を送っています"
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshLocal()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
        defer { progress.cancel() }
        do {
            for sid in startedSids {
                if let store = library.store {
                    let client = try await library.recordingClient()
                    let sender = ChunkSender(store: store, sid: sid, transport: client)
                    let sending = Task { await sender.flush(maxAttempts: 4) }
                    let result = await withTaskCancellationHandler(operation: { await sending.value }, onCancel: { sender.stop() })
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .drained:
                        guard ChunkSender.queueFiles(store: store, sid: sid).isEmpty,
                              ChunkSender.pendingImages(store: store, sid: sid).isEmpty else {
                            errorMessage = "未送信の記録が残っています。もう一度送ってください"
                            return
                        }
                    case .retryLater:
                        errorMessage = "通信できる場所でもう一度開いてください"
                        return
                    case .fatal(let error):
                        errorMessage = error.userMessage
                        return
                    }
                }
                library.preferences.set(true, forKey: "work.sent.\(sid)")
            }
            refreshLocal()
            progressMessage = "記録を保存しました"
            await reload()
        } catch { errorMessage = LibraryModel.message(error) }
    }

    /// 【11/8】送る詳細（前後の空白を取る）と、上限に収まっているか（受付API と同じく Unicode のスカラー数で数える）
    var trimmedDetail: String { declarationDetail.trimmingCharacters(in: .whitespacesAndNewlines) }
    var detailLength: Int { trimmedDetail.unicodeScalars.count }
    var declarationReady: Bool { aiUse != nil && detailLength <= AuthorDeclaration.maxDetail }

    /// 「提出へ」。録画中・未送信なら進まない。
    func beginSubmit() {
        guard canSubmit else { return }
        aiUse = nil
        submitting = true
    }

    /// 提出の画面から記録の一覧に戻る（PNG は差し替えできるので、そのまま残す）。
    func endSubmit() {
        guard !busy else { return }
        submitting = false
    }

    func upload(png: Data) async {
        guard !busy, phase == .submit else { return }
        guard png.count <= 30 * 1024 * 1024 else {
            errorMessage = "ファイルが大きすぎます。PNG は30MB以下で選んでください"
            return
        }
        guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            errorMessage = "PNG形式の画像を選んでください"
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let (client, token) = try await library.connection()
            let response = try await client.putPNG(workId: work.workId, png: png, idToken: token)
            work.png = response
            uploadedPreview = UIImage(cgImage: thumbnail)
            library.update(work)
            aiUse = nil
        } catch { errorMessage = LibraryModel.message(error) }
    }

    func finalize(resuming: Bool = false) async {
        guard !busy else { return }
        if resuming && work.status != "finalizing" { return }
        guard resuming || (phase == .submit && declarationReady && work.png != nil && (endImageURL == nil || useEndImage != nil)) else { return }
        guard !RecordingPolicy.isActive(status) else {
            errorMessage = "録画を止めて、記録を送り終えてから確定してください"
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false; retrySeconds = 0 }
        while !Task.isCancelled {
            do {
                let (client, token) = try await library.connection()
                let showAll = wholeImages.isEmpty ? true : showWhole
                // 【11/8】申告の版2を送る。確定の途中からの再開では、申告は受付API が固定済みなので版1の形で呼ぶ
                let result: FinalizeResponse
                if let aiUse, !resuming {
                    result = try await client.finalize(workId: work.workId, declaration: AuthorDeclarationInput(aiUse: aiUse, detail: trimmedDetail),
                                                       useEndImage: useEndImage ?? true, showWhole: showAll, idToken: token)
                } else {
                    result = try await client.finalize(workId: work.workId, declarationAccepted: true,
                                                       useEndImage: useEndImage ?? true, showWhole: showAll, idToken: token)
                }
                submitting = false
                work.status = "finalized"
                work.publicId = result.publicId
                work.match = result.manifest.match
                work.explanation = result.explanation
                completionStatus = result.manifest.resultStatus
                library.update(work)
                await reload()
                return
            } catch let error as APIError where error.code == "STILL_RECORDING" {
                // サーバの60秒ルールに従い、指定された秒数を待って同じ選択で再試行する。
                let deadline = Date().addingTimeInterval(TimeInterval(max(1, error.retryAfterSec ?? 1)))
                while Date() < deadline {
                    retrySeconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                }
                retrySeconds = 0
            } catch {
                if !Task.isCancelled { errorMessage = LibraryModel.message(error) }
                // 確定の段階Aだけ完了した場合もサーバから読み直す。
                await reload()
                return
            }
        }
    }

    func setExplanation(_ include: Bool) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let (client, token) = try await library.connection()
            let included = try await client.setExplanation(workId: work.workId, include: include, idToken: token)
            work.explanation?.included = included
            library.update(work)
        } catch { errorMessage = LibraryModel.message(error) }
    }

    func delete() async -> Bool {
        guard !busy else { return false }
        guard !RecordingPolicy.isActive(status) else {
            errorMessage = "この作品の録画を止めてから削除してください"
            return false
        }
        busy = true
        defer { busy = false }
        do {
            let (client, token) = try await library.connection()
            try await client.deleteWork(workId: work.workId, idToken: token)
            library.removed(work)
            return true
        } catch {
            errorMessage = LibraryModel.message(error)
            return false
        }
    }
}
