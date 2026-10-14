import CryptoKit
import Foundation

public enum VaultError: Error, Sendable, Equatable, CustomStringConvertible {
    case needsNewerMacOS
    case locked
    case wrongKey
    case corrupt(String)

    public var description: String {
        switch self {
        case .needsNewerMacOS: "Encrypted folders need macOS 26 or later"
        case .locked: "This folder is encrypted and its key isn't on this Mac. Turn on iCloud Keychain on a Mac that has the key, or sign in to the same iCloud account."
        case .wrongKey: "This folder was encrypted with a different key"
        case let .corrupt(what): "Encrypted data is damaged: \(what)"
        }
    }
}

/// The random key for one encrypted folder, and the subkeys derived from it.
public struct FolderKey: Sendable {
    public let raw: SymmetricKey
    let chunkKey: SymmetricKey
    let indexKey: SymmetricKey
    let idKey: SymmetricKey
    public let chunker: Chunker

    public init(raw: SymmetricKey) {
        self.raw = raw
        func derive(_ label: String, count: Int = 32) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: raw, salt: Data("GitDrive vault v1".utf8), info: Data(label.utf8), outputByteCount: count)
        }
        chunkKey = derive("chunk")
        indexKey = derive("index")
        idKey = derive("chunk-id")
        let gear = derive("gear", count: 2048).withUnsafeBytes { Data($0) }
        chunker = Chunker(gearSeed: gear)
    }

    public static func random() -> FolderKey { FolderKey(raw: SymmetricKey(size: .bits256)) }

    /// Keyed hash of a chunk's plaintext. Equal chunks get equal IDs, but the ID reveals nothing without the key.
    public func chunkID(_ plaintext: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: plaintext, using: idKey).prefix(16).hex
    }

    /// Compresses (when it helps) and encrypts one chunk. Layout: nonce, ciphertext, tag.
    public func sealChunk(_ plaintext: Data) throws -> (id: String, sealed: Data) {
        let id = chunkID(plaintext)
        var payload = Data([0])
        if let packed = try? (plaintext as NSData).compressed(using: .lzfse) as Data, packed.count < plaintext.count * 97 / 100 {
            payload = Data([1])
            payload.append(packed)
        } else {
            payload.append(plaintext)
        }
        let box = try AES.GCM.seal(payload, using: chunkKey, authenticating: Data(id.utf8))
        guard let combined = box.combined else { throw VaultError.corrupt("could not seal chunk") }
        return (id, combined)
    }

    public func openChunk(_ sealed: Data, id: String) throws -> Data {
        let box: AES.GCM.SealedBox
        let payload: Data
        do {
            box = try AES.GCM.SealedBox(combined: sealed)
            payload = try AES.GCM.open(box, using: chunkKey, authenticating: Data(id.utf8))
        } catch {
            throw VaultError.corrupt("chunk \(id.prefix(8)) failed authentication")
        }
        guard let flag = payload.first else { throw VaultError.corrupt("empty chunk") }
        let body = payload.dropFirst()
        let plaintext = flag == 1 ? try (Data(body) as NSData).decompressed(using: .lzfse) as Data : Data(body)
        guard chunkID(plaintext) == id else { throw VaultError.corrupt("chunk \(id.prefix(8)) has the wrong contents") }
        return plaintext
    }

    /// Compresses, pads with Padmé and encrypts the index.
    public func sealIndex(_ json: Data) throws -> Data {
        let packed = (try? (json as NSData).compressed(using: .lzfse) as Data) ?? json
        var body = withUnsafeBytes(of: UInt32(packed.count).bigEndian) { Data($0) }
        body.append(packed)
        body.append(Data(count: padme(body.count) - body.count))
        guard let combined = try AES.GCM.seal(body, using: indexKey, authenticating: Data("index".utf8)).combined else {
            throw VaultError.corrupt("could not seal index")
        }
        return combined
    }

    public func openIndex(_ sealed: Data) throws -> Data {
        let body: Data
        do {
            body = try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed), using: indexKey, authenticating: Data("index".utf8))
        } catch {
            throw VaultError.corrupt("index failed authentication")
        }
        guard body.count >= 4 else { throw VaultError.corrupt("index too short") }
        let length = Int(body.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard body.count >= 4 + length else { throw VaultError.corrupt("index length") }
        let packed = body.dropFirst(4).prefix(length)
        return (try? (Data(packed) as NSData).decompressed(using: .lzfse) as Data) ?? Data(packed)
    }
}

/// `.gitdrive/vault.json`: public. The folder key sealed to the owner's public key with
/// post-quantum hybrid HPKE (X-Wing: ML-KEM-768 + X25519, SHA-256, AES-256-GCM).
public struct VaultHeader: Codable, Sendable, Equatable {
    public var format = 1
    public var suite = "XWingMLKEM768X25519_SHA256_AES_GCM_256"
    public var keyID: String
    public var publicKey: String
    public var encapsulatedKey: String
    public var wrappedKey: String

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// The owner's key pair. Only the private half ever decrypts; it lives in the Keychain.
public struct VaultIdentity: Sendable, Equatable {
    /// CryptoKit's integrity-checked private key encoding.
    public let secret: Data
    public let publicKey: Data

    public var keyID: String { SHA256.hash(data: publicKey).prefix(8).hex }

    static let info = Data("GitDrive vault v1".utf8)

    public static func generate() throws -> VaultIdentity {
        guard #available(macOS 26, *) else { throw VaultError.needsNewerMacOS }
        let key = try XWingMLKEM768X25519.PrivateKey.generate()
        return VaultIdentity(secret: key.integrityCheckedRepresentation, publicKey: key.publicKey.rawRepresentation)
    }

    public init(secret: Data, publicKey: Data) {
        self.secret = secret
        self.publicKey = publicKey
    }

    /// Restores an identity from its secret, recomputing the public key.
    public init(secret: Data) throws {
        guard #available(macOS 26, *) else { throw VaultError.needsNewerMacOS }
        let key = try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: secret)
        self.init(secret: secret, publicKey: key.publicKey.rawRepresentation)
    }

    /// Seals a folder key to this identity's public key. Only needs the public half.
    public func wrap(_ folder: FolderKey) throws -> VaultHeader {
        guard #available(macOS 26, *) else { throw VaultError.needsNewerMacOS }
        let recipient = try XWingMLKEM768X25519.PublicKey(rawRepresentation: publicKey)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: Self.info)
        let raw = folder.raw.withUnsafeBytes { Data($0) }
        let sealed = try sender.seal(raw, authenticating: Data(keyID.utf8))
        return VaultHeader(
            keyID: keyID,
            publicKey: publicKey.base64EncodedString(),
            encapsulatedKey: sender.encapsulatedKey.base64EncodedString(),
            wrappedKey: sealed.base64EncodedString()
        )
    }

    public func unwrap(_ header: VaultHeader) throws -> FolderKey {
        guard #available(macOS 26, *) else { throw VaultError.needsNewerMacOS }
        guard header.keyID == keyID else { throw VaultError.wrongKey }
        guard let encapsulated = Data(base64Encoded: header.encapsulatedKey), let wrapped = Data(base64Encoded: header.wrappedKey) else {
            throw VaultError.corrupt("vault header")
        }
        let key = try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: secret)
        var recipient = try HPKE.Recipient(
            privateKey: key, ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: Self.info, encapsulatedKey: encapsulated
        )
        let raw: Data
        do {
            raw = try recipient.open(wrapped, authenticating: Data(keyID.utf8))
        } catch {
            throw VaultError.wrongKey
        }
        return FolderKey(raw: SymmetricKey(data: raw))
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Random lowercase name part, used for encrypted folders' repo names and pack IDs.
func randomToken(bytes: Int) -> String {
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
    return data.hex
}
