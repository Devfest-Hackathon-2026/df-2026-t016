import CryptoKit
import Foundation

/// 端末の鍵（設計書6章）。録画拡張がメモリ上で作り、保存しない。
/// 署名は ECDSA P-256 / SHA-256 で、r‖s の64バイト。
public struct DeviceKey {
    private let privateKey: P256.Signing.PrivateKey

    /// 新しい鍵を作る（録画のたびに1つ）。
    public init() {
        privateKey = P256.Signing.PrivateKey()
    }

    /// 決まった秘密鍵（32バイト）から作る。試験用。
    public init(rawRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    /// 公開鍵の x9.63 形式（65バイト、先頭が 0x04）。
    public var publicKeyX963: Data {
        privateKey.publicKey.x963Representation
    }

    /// 開始 API（#6）の `devicePubKey` に入れる値。
    public var publicKeyX963Base64: String {
        Canonical.base64(publicKeyX963)
    }

    /// `data` に署名し、r‖s の64バイトを返す（チャンクのヘッダのバイト列に使う）。
    public func signRS(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).rawRepresentation
    }

    /// 画像の端末署名。署名する対象は UTF-8 の文字列 `image:{sid}:{sha256}`。
    public func signImage(sid: String, sha256: String) throws -> Data {
        try signRS(Self.imageMessage(sid: sid, sha256: sha256))
    }

    public static func imageMessage(sid: String, sha256: String) -> Data {
        Data("image:\(sid):\(sha256)".utf8)
    }

    /// 端末署名（r‖s）を検証する。
    public static func verifyRS(publicKeyX963: Data, signature: Data, data: Data) -> Bool {
        guard
            let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
            let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { return false }
        return publicKey.isValidSignature(ecdsa, for: data)
    }
}

/// KMS の署名（開始証・受領証・確定記録）の検証。署名は DER、公開鍵は PEM（SPKI）。
public enum KMSSignature {
    public static func verify(publicKeyPEM: String, derSignature: Data, data: Data) -> Bool {
        guard
            let publicKey = try? P256.Signing.PublicKey(pemRepresentation: publicKeyPEM),
            let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: derSignature)
        else { return false }
        return publicKey.isValidSignature(ecdsa, for: data)
    }
}
