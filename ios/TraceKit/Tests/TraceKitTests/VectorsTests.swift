import Foundation
import XCTest
@testable import TraceKit

/// `shared/vectors/signing.json`（T01）との互換性の試験と、`swift_signature.json` の書き出し。
/// Mac のターミナルで `cd ios/TraceKit && swift test` で回す（リポジトリのファイルを読むため）。
final class VectorsTests: XCTestCase {
    // MARK: - テストベクタ

    struct Vectors: Decodable {
        struct Key: Decodable { let privateHex: String; let publicX963: String }
        struct CanonicalSample: Decodable { let obj: JSONValue; let bytes: String }
        struct Signed: Decodable { let bytes: String; let sig: String }
        struct Header: Decodable { let obj: ChunkHeader; let bytes: String; let sha256: String }
        struct Body: Decodable { let obj: ChunkBody; let bytes: String; let sha256: String; let tilesSet: [Int] }
        struct Sig: Decodable { let sig: String }
        struct ImageSig: Decodable { let message: String; let sig: String }
        struct KMSKey: Decodable { let publicPem: String }

        let deviceKey: Key
        let canonical: CanonicalSample
        let startCert: Signed
        let body: Body
        let header: Header
        let deviceSig: Sig
        let imageSig: ImageSig
        let receipt: Signed
        let kmsKey: KMSKey
    }

    /// リポジトリの一番上（このファイルは ios/TraceKit/Tests/TraceKitTests/ にある）。
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static let vectorsDirectory = repoRoot.appendingPathComponent("shared/vectors", isDirectory: true)

    private func loadVectors() throws -> Vectors {
        let url = Self.vectorsDirectory.appendingPathComponent("signing.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    private func b64(_ string: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: string), "base64 が読めない: \(string.prefix(20))…")
    }

    // MARK: - 署名

    func testDeviceKeyMatchesVectorPublicKey() throws {
        let v = try loadVectors()
        let key = try DeviceKey(rawRepresentation: try XCTUnwrap(Data(hex: v.deviceKey.privateHex)))
        XCTAssertEqual(key.publicKeyX963Base64, v.deviceKey.publicX963)
        XCTAssertEqual(key.publicKeyX963.count, 65)
        XCTAssertEqual(key.publicKeyX963.first, 0x04)
    }

    func testVerifiesPythonHeaderSignature() throws {
        let v = try loadVectors()
        XCTAssertTrue(DeviceKey.verifyRS(
            publicKeyX963: try b64(v.deviceKey.publicX963),
            signature: try b64(v.deviceSig.sig),
            data: try b64(v.header.bytes)
        ))
        // 1バイト変えたら通らない
        var tampered = try b64(v.header.bytes)
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertFalse(DeviceKey.verifyRS(
            publicKeyX963: try b64(v.deviceKey.publicX963),
            signature: try b64(v.deviceSig.sig),
            data: tampered
        ))
    }

    func testVerifiesPythonImageSignature() throws {
        let v = try loadVectors()
        let parts = v.imageSig.message.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(DeviceKey.imageMessage(sid: parts[1], sha256: parts[2]), Data(v.imageSig.message.utf8))
        XCTAssertTrue(DeviceKey.verifyRS(
            publicKeyX963: try b64(v.deviceKey.publicX963),
            signature: try b64(v.imageSig.sig),
            data: Data(v.imageSig.message.utf8)
        ))
    }

    func testSignAndVerifyRoundTrip() throws {
        let key = DeviceKey()
        let message = Data("hello".utf8)
        let signature = try key.signRS(message)
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(DeviceKey.verifyRS(publicKeyX963: key.publicKeyX963, signature: signature, data: message))
        XCTAssertFalse(DeviceKey.verifyRS(publicKeyX963: key.publicKeyX963, signature: signature, data: Data("hellO".utf8)))
    }

    func testVerifiesKMSSignatures() throws {
        let v = try loadVectors()
        XCTAssertTrue(KMSSignature.verify(
            publicKeyPEM: v.kmsKey.publicPem,
            derSignature: try b64(v.startCert.sig),
            data: try b64(v.startCert.bytes)
        ))
        XCTAssertTrue(KMSSignature.verify(
            publicKeyPEM: v.kmsKey.publicPem,
            derSignature: try b64(v.receipt.sig),
            data: try b64(v.receipt.bytes)
        ))
        XCTAssertFalse(KMSSignature.verify(
            publicKeyPEM: v.kmsKey.publicPem,
            derSignature: try b64(v.receipt.sig),
            data: try b64(v.startCert.bytes)
        ))
    }

    // MARK: - JSON とハッシュ

    func testCanonicalJSONMatchesPython() throws {
        let v = try loadVectors()
        let bytes = try Canonical.encodeSorted(v.canonical.obj)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), String(decoding: try b64(v.canonical.bytes), as: UTF8.self))
    }

    func testChunkHeaderBytesMatchPython() throws {
        let v = try loadVectors()
        let bytes = try Canonical.encodeSorted(v.header.obj)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), String(decoding: try b64(v.header.bytes), as: UTF8.self))
        XCTAssertEqual(Canonical.sha256Hex(bytes), v.header.sha256)
        XCTAssertEqual(v.header.obj.prev, Canonical.sha256Hex(try b64(v.startCert.bytes)))
    }

    func testChunkBodyBytesAndTilesMatchPython() throws {
        let v = try loadVectors()
        let bytes = try Canonical.encodeSorted(v.body.obj)
        XCTAssertEqual(bytes, try b64(v.body.bytes))
        XCTAssertEqual(Canonical.sha256Hex(bytes), v.body.sha256)
        XCTAssertEqual(v.header.obj.body, v.body.sha256)
        XCTAssertEqual(v.header.obj.bodyLen, bytes.count)

        let tiles = TileBitmap.make(v.body.tilesSet)
        XCTAssertEqual(tiles.count, 96)
        XCTAssertEqual(Canonical.base64(tiles), v.body.obj.tiles)
        XCTAssertEqual(TileBitmap.indices(tiles), v.body.tilesSet)
        XCTAssertEqual(ChunkBody(frames: v.body.obj.frames, tiles: tiles), v.body.obj)
    }

    func testHeaderWithoutImagesOmitsKey() throws {
        let header = ChunkHeader(
            sid: "s_A", seq: 1, prev: String(repeating: "0", count: 64),
            tStart: "2026-11-06T00:00:00.000Z", tEnd: "2026-11-06T00:00:05.000Z",
            body: String(repeating: "1", count: 64), bodyLen: 10,
            images: ChunkImages(),
            stats: ChunkStats(fps: 10, changedTiles: 0, resend: false, memMB: 9, degraded: false),
            final: false
        )
        let json = String(decoding: try Canonical.encodeSorted(header), as: UTF8.self)
        XCTAssertFalse(json.contains("images"))
        XCTAssertFalse(json.contains("whole"))
    }

    // MARK: - swift_signature.json（Python と web の試験が検証する）

    struct SwiftSignature: Codable {
        let publicX963: String
        let sig: String
    }

    /// テストベクタの鍵で `header.bytes` に署名し、`shared/vectors/swift_signature.json` に書く。
    /// CryptoKit の署名は毎回変わるので、既にあるファイルの署名が通るなら書き換えない（git の差分を出さないため）。
    func testWriteSwiftSignature() throws {
        let v = try loadVectors()
        let key = try DeviceKey(rawRepresentation: try XCTUnwrap(Data(hex: v.deviceKey.privateHex)))
        let header = try b64(v.header.bytes)
        let url = Self.vectorsDirectory.appendingPathComponent("swift_signature.json")

        if let existing = try? JSONDecoder().decode(SwiftSignature.self, from: Data(contentsOf: url)),
           let publicKey = Data(base64Encoded: existing.publicX963),
           let signature = Data(base64Encoded: existing.sig),
           DeviceKey.verifyRS(publicKeyX963: publicKey, signature: signature, data: header) {
            return
        }

        let signature = try key.signRS(header)
        XCTAssertTrue(DeviceKey.verifyRS(publicKeyX963: key.publicKeyX963, signature: signature, data: header))
        let output = SwiftSignature(publicX963: key.publicKeyX963Base64, sig: Canonical.base64(signature))
        var data = try Canonical.encodeSorted(output)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - 試験用の道具

/// 任意の JSON（正準 JSON の試験用）。
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension Data {
    /// 16進の文字列から作る。
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
