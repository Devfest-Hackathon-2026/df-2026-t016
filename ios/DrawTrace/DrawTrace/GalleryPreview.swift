#if DEBUG
import Foundation
import SwiftUI
import TraceKit

/// UI試験専用。匿名ログインも本物の受付APIも使わず、通常のApp Groupと表示名を変更しない。
enum GalleryPreview {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        || ProcessInfo.processInfo.arguments.contains("--design-preview")
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let defaults = UserDefaults(suiteName: "drawtrace.ui-testing")!

    @MainActor static func makeLibrary() -> LibraryModel {
        defaults.removePersistentDomain(forName: "drawtrace.ui-testing")
        defaults.set("サンプル作者", forKey: "profile.displayName")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-testing-\(UUID())")
        let store = AppGroupStore(defaults: defaults, containerURL: root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewURLProtocol.self]
        let client = APIClient(baseURL: URL(string: "https://preview.invalid")!, session: URLSession(configuration: configuration))
        let library = LibraryModel(store: store, preferences: defaults, connect: { (client, "preview") })
        var works: [[String: Any]] = []
        let titles = ["青い午後", "余白の構成", "夜明けの習作", "線の習作"]
        let today = Calendar.current.startOfDay(for: Date())
        for index in titles.indices {
            // 【T14】1つ目の作品は2回の記録（2日前と昨日が1回目、今日が2回目）。ほかは1回
            let plan: [(sid: String, days: [Int])] = index == 0
                ? [("s_preview0", [2, 1]), ("s_preview0_1", [0])]
                : [("s_preview\(index)", [2, 1, 0])]
            var sessions: [[String: Any]] = []
            for (sid, days) in plan {
                _ = try? store.prepareSession(sid)
                var record = WholeRecord()
                for day in days {
                    let time = today.addingTimeInterval(Double(-day * 86400 + 3600 * 9))
                    let sha = "preview-\(index)-\(day)"
                    let item = WholeItem(sha: sha, frameTime: Canonical.timeString(time), rect: [0, 0, 1, 1])
                    record.items.append(item)
                    try? artwork(index: index, stage: day).jpegData(compressionQuality: 0.85)?.write(
                        to: store.directory(.images, sid: sid).appendingPathComponent("\(sha).jpg"))
                }
                record.items.sort { $0.frameTime < $1.frameTime }
                record.latest = record.items.last
                record.start = record.items.first?.sha
                record.end = record.items.last?.sha
                try? store.setWholeRecord(record, sid: sid)
                sessions.append(["sid": sid, "status": "completed", "chunkCount": 24, "final": true,
                                 "startedAt": record.items.first!.frameTime, "lastReceivedAt": record.items.last!.frameTime])
                defaults.set(true, forKey: "work.sent.\(sid)")
            }
            var json: [String: Any] = [
                "workId": "w_preview\(index)", "title": titles[index], "displayName": "サンプル作者",
                "status": "recorded", "createdAt": Canonical.timeString(today.addingTimeInterval(Double(-index * 86400))),
                "session": sessions.last!, "sessions": sessions,
                "png": ["sha256": "png", "width": 2048, "height": 1536]
            ]
            if index == 0 && ProcessInfo.processInfo.arguments.contains("--prepare-preview") {
                json["status"] = "draft"
                json.removeValue(forKey: "session")
                json.removeValue(forKey: "sessions")
                json.removeValue(forKey: "png")
                for (sid, _) in plan { try? store.setWholeRecord(WholeRecord(), sid: sid) }
            }
            works.append(json)
            if let data = try? JSONSerialization.data(withJSONObject: json), let work = try? JSONDecoder().decode(WorkDetail.self, from: data) {
                library.update(work)
            }
        }
        PreviewURLProtocol.works = works
        return library
    }

    private static func artwork(index: Int, stage: Int) -> UIImage {
        let colors: [(UIColor, UIColor)] = [
            (UIColor(red: 0.13, green: 0.30, blue: 0.40, alpha: 1), UIColor(red: 0.73, green: 0.85, blue: 0.89, alpha: 1)),
            (UIColor(red: 0.72, green: 0.29, blue: 0.12, alpha: 1), UIColor(red: 0.93, green: 0.89, blue: 0.80, alpha: 1)),
            (UIColor(red: 0.25, green: 0.21, blue: 0.34, alpha: 1), UIColor(red: 0.86, green: 0.72, blue: 0.65, alpha: 1)),
            (UIColor(red: 0.16, green: 0.17, blue: 0.16, alpha: 1), UIColor(red: 0.94, green: 0.92, blue: 0.86, alpha: 1))
        ]
        return UIGraphicsImageRenderer(size: CGSize(width: 720, height: 540)).image { context in
            let (dark, light) = colors[index]
            light.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 540))
            if index == 1 {
                dark.setFill()
                UIBezierPath(ovalIn: CGRect(x: -280, y: -290, width: 760, height: 760)).fill()
                UIColor(red: 0.12, green: 0.14, blue: 0.13, alpha: 0.95).setFill()
                context.fill(CGRect(x: 400, y: 290 + stage * 30, width: 320, height: 250))
                return
            }
            if index == 3 {
                for line in 0..<(7 - stage) {
                    let x = CGFloat(80 + line * 90)
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addCurve(to: CGPoint(x: 720 - x / 2, y: 540),
                                  controlPoint1: CGPoint(x: x - 180, y: 280),
                                  controlPoint2: CGPoint(x: x + 100, y: 200))
                    path.lineWidth = line.isMultiple(of: 3) ? 28 : 1.5
                    dark.withAlphaComponent(line.isMultiple(of: 3) ? 0.8 : 0.5).setStroke()
                    path.stroke()
                }
                return
            }
            dark.withAlphaComponent(0.25).setFill()
            UIBezierPath(ovalIn: CGRect(x: 400, y: 55, width: 145, height: 145)).fill()
            for layer in 0..<(4 - stage) {
                dark.withAlphaComponent(0.3 + Double(layer) * 0.17).setFill()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: 300 + layer * 45))
                path.addCurve(to: CGPoint(x: 720, y: 260 + layer * 45),
                              controlPoint1: CGPoint(x: 250, y: 100 + layer * 80), controlPoint2: CGPoint(x: 460, y: 450 - layer * 10))
                path.addLine(to: CGPoint(x: 720, y: 540))
                path.addLine(to: CGPoint(x: 0, y: 540))
                path.close()
                path.fill()
            }
        }
    }
}

private final class PreviewURLProtocol: URLProtocol {
    static var works: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "preview.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: [String: Any]
        if path == "/v1/works" { body = ["works": Self.works] }
        else if path.hasSuffix("/sessions"),
                let index = Self.works.firstIndex(where: { path.contains($0["workId"] as? String ?? "") }) {
            // 【T14】記録を足す。未開始の記録は置き換える
            var sessions = ((Self.works[index]["sessions"] as? [[String: Any]]) ?? []).filter { ($0["status"] as? String) != "created" }
            let sid = "s_preview\(index)_\(sessions.count + 1)"
            body = ["sid": sid, "startToken": "preview", "expiresAt": Canonical.timeString(Date().addingTimeInterval(600))]
            let created: [String: Any] = ["sid": sid, "status": "created", "chunkCount": 0, "final": false]
            sessions.append(created)
            Self.works[index]["sessions"] = sessions
            Self.works[index]["session"] = created
        } else if path.hasSuffix("/finalize") {
            let results = ((Self.works.first { path.contains($0["workId"] as? String ?? "") }?["sessions"] as? [[String: Any]]) ?? [])
                .map { ["sid": $0["sid"] ?? "", "status": "completed"] }
            body = ["publicId": "p_preview", "manifest": ["v": 2, "sessions": results, "match": ["result": "match", "score": 0.95]],
                    "explanation": NSNull()]
            if let index = Self.works.firstIndex(where: { path.contains($0["workId"] as? String ?? "") }) {
                Self.works[index]["status"] = "finalized"
                Self.works[index]["publicId"] = "p_preview"
                Self.works[index]["match"] = ["result": "match", "score": 0.95]
            }
        } else { body = Self.works.first { path.hasSuffix($0["workId"] as? String ?? "") } ?? [:] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
