import Foundation
import os
#if canImport(FirebaseCore) && canImport(FirebaseAppCheck)
import FirebaseAppCheck
import FirebaseCore
#endif

/// 【T12】Firebase App Check（tasks/T12_AppCheck.md の Nさんの分）。
///
/// 記録（セッション）を作る直前に使い切りのトークンを取り、受付API に `X-Firebase-AppCheck` で送る。
/// - 実機: App Attest（エンタイトルメントの `com.apple.developer.devicecheck.appattest-environment`）
/// - シミュレータ: debug provider。起動するとコンソールに debug token が出るので、Firebase コンソールに登録する
/// 録画拡張では使わない（App Attest は拡張では使えないため）。
enum AppCheckService {
    private static let log = Logger(subsystem: "com.ggdevfest2026.drawtrace", category: "appcheck")

    /// ログに出す provider の名前
    private static var providerName: String {
        #if targetEnvironment(simulator)
        return "シミュレータ・debug provider"
        #else
        return "App Attest"
        #endif
    }

    /// `FirebaseApp.configure()` の前に1回呼ぶ。
    static func install() {
        #if canImport(FirebaseCore) && canImport(FirebaseAppCheck)
        AppCheck.setAppCheckProviderFactory(TraceAppCheckProviderFactory())
        #endif
    }

    /// 使い切りのトークン（`limitedUseToken`）。取れなければ nil。
    ///
    /// nil のときはヘッダを付けずに送る。受付API が `APP_CHECK=off` なら、そのまま記録を作れる。
    /// `required` なら受付API が `401 APP_CHECK_FAILED` を返し、画面にそのことを出す。
    static func limitedUseToken(timeout: TimeInterval = 10) async -> String? {
        #if canImport(FirebaseCore) && canImport(FirebaseAppCheck)
        let log = Self.log
        guard FirebaseApp.app() != nil else {
            log.error("Firebase が初期化されていないため、App Check を使いません（GoogleService-Info.plist を確認）")
            return nil
        }
        let providerName = Self.providerName
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            AppCheck.appCheck().limitedUseToken { token, error in
                if let error {
                    log.error("App Check のトークンを取れませんでした: \(error.localizedDescription, privacy: .public)")
                }
                // 確認用に、取れたことだけを出す（トークンの中身は出さない）
                if token != nil {
                    log.notice("App Check のトークンを取りました（\(providerName, privacy: .public)）")
                }
                once.resume(token?.token)
            }
            // App Attest の初回は鍵の作成と証明で時間がかかることがある。待ち続けないようにする
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.resume(nil) {
                    log.error("App Check のトークンが \(Int(timeout), privacy: .public) 秒で取れませんでした")
                }
            }
        }
        #else
        return nil
        #endif
    }
}

/// 続きを1回だけ再開する（トークンの応答と時間切れのうち、先に来た方だけを使う）。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ value: String?) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: value)
        return true
    }
}

#if canImport(FirebaseCore) && canImport(FirebaseAppCheck)
/// 実機は App Attest、シミュレータは debug provider。
final class TraceAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if targetEnvironment(simulator)
        return AppCheckDebugProvider(app: app)
        #else
        return AppAttestProvider(app: app)
        #endif
    }
}
#endif
