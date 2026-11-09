import CryptoKit
import Foundation
import XCTest
@testable import TraceKit

/// 明示的に指定したときだけ本番に接続する。専用の匿名ユーザーと作品を作り、最後に削除する。
/// DRAWTRACE_LIVE_TEST=1 swift test --filter LiveRecordingTests
final class LiveRecordingTests: XCTestCase {
    func testSignedRecordingThroughPublicationAndDeletion() async throws {
        guard ProcessInfo.processInfo.environment["DRAWTRACE_LIVE_TEST"] == "1" else {
            throw XCTSkip("本番への接続試験はDRAWTRACE_LIVE_TEST=1で実行")
        }
        let root = VectorsTests.repoRoot
        let plistURL = root.appendingPathComponent("ios/DrawTrace/DrawTrace/GoogleService-Info.plist")
        let config = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        let apiKey = try XCTUnwrap(config["API_KEY"] as? String)
        let bundleID = try XCTUnwrap(config["BUNDLE_ID"] as? String)
        let api = APIClient(baseURL: URL(string: ProcessInfo.processInfo.environment["DRAWTRACE_API_BASE_URL"]
                                        ?? "https://trace-api-x6vza4wesa-an.a.run.app")!)
        let keyPEM = try String(contentsOf: root.appendingPathComponent("shared/keys/kms_public.pem"), encoding: .utf8)
        let kms = try P256.Signing.PublicKey(pemRepresentation: keyPEM)
        let signup = try await auth("signUp", apiKey: apiKey, bundleID: bundleID, body: ["returnSecureToken": true])
        let token = try XCTUnwrap(signup["idToken"] as? String)
        var workID: String?
        do {
            let healthy = try await api.healthz()
            XCTAssertTrue(healthy)
            for shown in [true, false] {
                let work = try await api.createWork(title: "iPad Swift 接続試験", displayName: "接続試験", idToken: token)
                workID = work.workId
                let session = try await api.createSession(workId: work.workId, idToken: token)
                let suite = "live-recording-\(UUID())"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
                defer {
                    defaults.removePersistentDomain(forName: suite)
                    try? FileManager.default.removeItem(at: folder)
                }
                let store = AppGroupStore(defaults: defaults, containerURL: folder)
                let key = DeviceKey()
                let started = try await SessionStarter.start(
                    session: SessionInfo(sid: session.sid, workId: work.workId, startToken: session.startToken,
                                         apiBaseURL: api.baseURL.absoluteString, createdAt: Canonical.timeString()),
                    key: key, store: store, transport: api)
                XCTAssertTrue(kms.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: started.startSig), for: started.startCert))
                let builder = try ChunkBuilder(sid: session.sid, store: store, signer: key,
                                               startCert: started.startCert, recordingStartedAt: Date())
                let writer = try SnapshotWriter(store: store, sid: session.sid, signer: key)
                let fixture = root.appendingPathComponent("web/public/fixtures/whole_normal")
                let names = ["start.jpg", "whole-2.jpg", "end.jpg"]
                let images = try names.map { try writer.save(Data(contentsOf: fixture.appendingPathComponent($0))) }
                for sha in images { try writer.markPending(sha); builder.noteWholeImage(sha) }
                builder.noteStartImage(images[0])
                let activity = ActivityAccumulator()
                activity.addEditorTime(milliseconds: 1000)
                activity.addActiveTime(milliseconds: 500)
                try builder.finish(activity.drain(), now: Date(), fps: 2, memMB: 30, degraded: false, end: images[2])
                let result = await ChunkSender(store: store, sid: session.sid, transport: api).flush()
                XCTAssertEqual(result, .drained)
                let recorded = try await api.getWork(workId: work.workId, idToken: token)
                XCTAssertEqual(recorded.status, "recorded")
                XCTAssertEqual(recorded.session?.chunkCount, 3)
                XCTAssertTrue(recorded.session?.final == true)
                let png = try Data(contentsOf: fixture.appendingPathComponent("original.png"))
                let uploaded = try await api.putPNG(workId: work.workId, png: png, idToken: token)
                XCTAssertEqual(uploaded.sha256, Canonical.sha256Hex(png))
                let finalized = try await api.finalize(workId: work.workId, declarationAccepted: true,
                                                       useEndImage: true, showWhole: shown, idToken: token)
                XCTAssertEqual(finalized.manifest.resultStatus, "completed")
                XCTAssertEqual(finalized.manifest.match.result, "match")
                let publicURL = api.baseURL.appendingPathComponent("v1/p/\(finalized.publicId)")
                let bundle = try await getJSON(publicURL)
                let manifest = try XCTUnwrap(bundle["manifest"] as? [String: String])
                let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(manifest["bytes"])))
                let sig = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(manifest["sig"])))
                XCTAssertTrue(kms.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: sig), for: bytes))
                let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let whole = try XCTUnwrap(decoded["whole"] as? [String: Any])
                XCTAssertEqual(whole["shown"] as? Bool, shown)
                let items = try XCTUnwrap(whole["items"] as? [[String: Any]])
                XCTAssertEqual(items.compactMap { $0["sha256"] as? String }, images)
                XCTAssertTrue(items.allSatisfy { $0["received"] as? Bool == true })
                let files = try XCTUnwrap(bundle["files"] as? [String: Any])
                if shown {
                    XCTAssertEqual((files["whole"] as? [String])?.count, 3)
                    for index in images.indices {
                        let (data, response) = try await URLSession.shared.data(from: publicURL.appendingPathComponent("files/whole-\(index).jpg"))
                        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                        XCTAssertEqual(Canonical.sha256Hex(data), images[index])
                    }
                } else {
                    XCTAssertTrue(files["whole"] is NSNull)
                    let (_, response) = try await URLSession.shared.data(from: publicURL.appendingPathComponent("files/whole-0.jpg"))
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
                }
                // 再確定でも、最初に選んだ公開設定と公開IDを保つ。
                let repeated = try await api.finalize(workId: work.workId, declarationAccepted: true,
                                                      useEndImage: true, showWhole: !shown, idToken: token)
                XCTAssertEqual(repeated.publicId, finalized.publicId)
                if finalized.explanation != nil {
                    let included = try await api.setExplanation(workId: work.workId, include: false, idToken: token)
                    XCTAssertFalse(included)
                }
                try await api.deleteWork(workId: work.workId, idToken: token)
                workID = nil
                let (_, deleted) = try await URLSession.shared.data(from: publicURL)
                XCTAssertEqual((deleted as? HTTPURLResponse)?.statusCode, 404)
            }
            _ = try await auth("delete", apiKey: apiKey, bundleID: bundleID, body: ["idToken": token])
        } catch {
            if let workID { try? await api.deleteWork(workId: workID, idToken: token) }
            _ = try? await auth("delete", apiKey: apiKey, bundleID: bundleID, body: ["idToken": token])
            throw error
        }
    }

    private func auth(_ action: String, apiKey: String, bundleID: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:\(action)?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await json(request)
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] { try await json(URLRequest(url: url)) }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, code: "LIVE_TEST", message: "\(request.url!.path): HTTP \(status)")
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
