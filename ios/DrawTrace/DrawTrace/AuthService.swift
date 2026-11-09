import Foundation
import SwiftUI
#if canImport(FirebaseCore) && canImport(FirebaseAuth)
import FirebaseAuth
import FirebaseCore
#endif

/// Firebase の匿名ログイン（tasks/T03_iOSの土台.md の3）。
/// FirebaseAuth のパッケージや GoogleService-Info.plist がまだ無くても、ビルドと起動はできるようにしてある。
/// 録画拡張では使わない（Firebase は本体アプリだけ）。
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var uid: String?
    @Published private(set) var message = "まだログインしていません"
    private var signingIn: Task<Void, Never>?

    /// アプリの起動時に1回呼ぶ。GoogleService-Info.plist があるときだけ Firebase を初期化する。
    static func configureIfPossible() {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth)
        guard FirebaseApp.app() == nil else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        AppCheckService.install()  // 【T12】configure の前に登録する
        FirebaseApp.configure()
        #endif
    }

    /// 匿名ログインする。前回の匿名ユーザーが残っていれば、それを使う。
    func signIn() async {
        if let signingIn { await signingIn.value; return }
        let task = Task { await self.performSignIn() }
        signingIn = task
        await task.value
        signingIn = nil
    }

    private func performSignIn() async {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth)
        guard FirebaseApp.app() != nil else {
            message = "GoogleService-Info.plist が無いため、Firebase を使えません"
            return
        }
        if let user = Auth.auth().currentUser {
            uid = user.uid
            message = "ログイン済み（前回の匿名ユーザー）"
            return
        }
        message = "ログインしています…"
        do {
            let result = try await Auth.auth().signInAnonymously()
            uid = result.user.uid
            message = "匿名ログインしました"
        } catch {
            message = "匿名ログインに失敗しました: \(error.localizedDescription)"
        }
        #else
        message = "FirebaseAuth のパッケージがまだ入っていません"
        #endif
    }

    /// 受付API に付ける ID トークン（T10 で使う）。ログインしていなければ nil。
    func idToken() async throws -> String? {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth)
        guard FirebaseApp.app() != nil, let user = Auth.auth().currentUser else { return nil }
        return try await user.getIDToken()
        #else
        return nil
        #endif
    }
}
