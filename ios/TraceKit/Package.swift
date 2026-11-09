// swift-tools-version: 5.9
// 本体アプリと録画拡張の両方が使う共通パッケージ（tasks/T03_iOSの土台.md の2）。
// Firebase には依存しない。macOS も対象に入れているのは、Mac のターミナルで `swift test` を回すため。
import PackageDescription

let package = Package(
    name: "TraceKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TraceKit", targets: ["TraceKit"]),
    ],
    targets: [
        .target(name: "TraceKit"),
        .testTarget(name: "TraceKitTests", dependencies: ["TraceKit"]),
    ]
)
