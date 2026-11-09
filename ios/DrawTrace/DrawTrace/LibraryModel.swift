import Foundation
import SwiftUI
import TraceKit

@MainActor
final class LibraryModel: ObservableObject {
    let auth = AuthService()
    let store: AppGroupStore?
    let preferences: UserDefaults
    private let connect: (() async throws -> (APIClient, String))?
    @Published private(set) var works: [WorkDetail] = []
    @Published var errorMessage: String?
    @Published private(set) var loading = false
    @Published private(set) var offline = false

    var client: APIClient? { AppConfig.apiBaseURL.map { APIClient(baseURL: $0) } }

    init(store: AppGroupStore? = AppGroupStore(), preferences: UserDefaults = .standard,
         connect: (() async throws -> (APIClient, String))? = nil) {
        self.store = store
        self.preferences = preferences
        self.connect = connect
    }

    func connection() async throws -> (APIClient, String) {
        if let connect { return try await connect() }
        guard let client else {
            throw APIError(status: -1, code: "CONFIG", message: "APIの接続先が設定されていません")
        }
        if auth.uid == nil { await auth.signIn() }
        guard let token = try await auth.idToken() else {
            throw APIError(status: 401, code: "UNAUTHENTICATED", message: "")
        }
        return (client, token)
    }

    /// 【T12】記録を作る直前に取る、App Check の使い切りのトークン。取れなければ nil。
    /// 試験とデザインプレビュー（`connect` を渡したとき）は Firebase を使わないので nil。
    func appCheckToken() async -> String? {
        if connect != nil { return nil }
        return await AppCheckService.limitedUseToken()
    }

    /// 署名済みの記録にはFirebaseの再ログインを要求しない。
    func recordingClient() async throws -> APIClient {
        if let connect { return try await connect().0 }
        guard let client else { throw APIError(status: -1, code: "CONFIG", message: "") }
        return client
    }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if connect == nil && auth.uid == nil { await auth.signIn() }
        if works.isEmpty, let uid = auth.uid,
           let data = preferences.data(forKey: "works.cache.\(uid)"),
           let cached = try? JSONDecoder().decode([WorkDetail].self, from: data) { works = cached }
        do {
            let (client, token) = try await connection()
            works = try await client.listWorks(idToken: token)
            cache()
            errorMessage = nil
            offline = false
        } catch {
            errorMessage = Self.message(error)
            offline = true
        }
    }

    func create(title: String, displayName: String) async -> WorkDetail? {
        do {
            let (client, token) = try await connection()
            let work = try await client.createWork(title: title, displayName: displayName, idToken: token)
            update(work)
            errorMessage = nil
            return work
        } catch {
            errorMessage = Self.message(error)
            return nil
        }
    }

    /// 【11/8】表示名をアカウント（受付API の accounts/{uid}）に保存する。失敗しても止めない
    /// （作品を作るときにも受付API がアカウントを作るため）。試験とデザインプレビューでは送らない。
    func saveProfile(displayName: String) async {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connect == nil, !name.isEmpty, name.count <= 50 else { return }
        do {
            let (client, token) = try await connection()
            try await client.putMe(displayName: name, idToken: token)
        } catch {}
    }

    func update(_ work: WorkDetail) {
        works.removeAll { $0.workId == work.workId }
        works.append(work)
        works.sort { $0.createdAt > $1.createdAt }
        cache()
    }

    func removed(_ work: WorkDetail) {
        works.removeAll { $0.workId == work.workId }
        preferences.removeObject(forKey: "work.showWhole.\(work.workId)")
        for sid in work.allSessions.map(\.sid) {  // 【T14】すべての記録
            store?.removeSession(sid)
            preferences.removeObject(forKey: "work.sent.\(sid)")
            preferences.removeObject(forKey: "work.expiry.\(sid)")
            if store?.sessionCurrent?.sid == sid { store?.removeValue(forKey: AppGroupStore.Key.sessionCurrent) }
            if store?.broadcastStatus?.sid == sid { store?.removeValue(forKey: AppGroupStore.Key.broadcastStatus) }
            if store?.broadcastDebug?.sid == sid { store?.removeValue(forKey: AppGroupStore.Key.broadcastDebug) }
            preferences.removeObject(forKey: "work.showWhole.\(sid)")
        }
        cache()
    }

    private func cache() {
        guard let uid = auth.uid, let data = try? JSONEncoder().encode(works) else { return }
        preferences.set(data, forKey: "works.cache.\(uid)")
    }

    static func message(_ error: Error) -> String {
        (error as? APIError)?.userMessage ?? "通信できませんでした。もう一度お試しください"
    }
}

/// 【T15b】表示する画像と、切り抜く四角形（無ければ元の画像のまま）。
struct SnapshotRef: Equatable {
    let url: URL
    let crop: [Double]?
}

extension WorkDetail {
    var statusTitle: String {
        switch status {
        case "draft": return "録画の準備"
        case "recording": return "記録中"
        case "recorded": return startedSessions.count > 1 ? "記録 \(startedSessions.count)回" : "記録済み"
        case "finalizing": return "確定中"
        case "finalized": return "共有できます"
        default: return "状態を確認"
        }
    }

    /// 作品の代表の画像と、絵の部分の四角形（【T15b】表示のときだけ切り抜く。提出画像には無い）。
    func snapshot(store: AppGroupStore?) -> SnapshotRef? {
        // 【T14】新しい記録から順に、この端末に残っている最新の全体画像を探す
        for sid in allSessions.map(\.sid).reversed() {
            if let store, let record = store.wholeRecord(sid: sid),
               let sha = record.latest?.sha ?? record.end ?? record.items.last?.sha {
                let url = store.directory(.images, sid: sid).appendingPathComponent("\(sha).jpg")
                if FileManager.default.fileExists(atPath: url.path) { return SnapshotRef(url: url, crop: record.rect(for: sha)) }
            }
        }
        if let publicId, let api = AppConfig.apiBaseURL {
            return SnapshotRef(url: api.appendingPathComponent("v1/p/\(publicId)/files/png.jpg"), crop: nil)
        }
        return nil
    }
}
