import CommonCrypto
import Foundation
import Security

/// The GitDrive passcode and optional duress passcode, kept as salted PBKDF2-SHA256 hashes in a
/// Keychain item that never leaves this Mac.
public struct PasscodeStore: Sendable {
    struct Stored: Codable {
        var salt: Data
        var real: Data
        var duress: Data?
    }

    static let iterations: UInt32 = 310_000
    let service = "com.diwan.gitdrive.passcode"
    let accessGroup: String

    public init(accessGroup: String = AppConfig.keychainGroup) {
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "passcode",
            kSecUseDataProtectionKeychain as String: true,
        ]
        if !accessGroup.isEmpty { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    private func load() -> Stored? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private func save(_ stored: Stored) throws {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = try JSONEncoder().encode(stored)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not save the passcode (\(status))"])
        }
        AppConfig.passcodeIsSet = true
    }

    /// Sets both passcodes. A nil or empty duress passcode turns decoys off.
    public func set(passcode: String, duress: String?) throws {
        precondition(!passcode.isEmpty)
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let duress = duress.flatMap { $0.isEmpty || $0 == passcode ? nil : $0 }
        try save(Stored(salt: salt, real: Self.hash(passcode, salt: salt), duress: duress.map { Self.hash($0, salt: salt) }))
    }

    public var hasDuress: Bool { load()?.duress != nil }

    /// `.full` for the passcode, `.decoy` for the duress passcode, nil for anything else.
    /// Both hashes are always computed, so timing doesn't reveal whether a duress passcode exists.
    public func check(_ attempt: String) -> VaultAccess? {
        guard let stored = load() else { return nil }
        let hash = Self.hash(attempt, salt: stored.salt)
        let real = Self.equal(hash, stored.real)
        let duress = Self.equal(hash, stored.duress ?? Data(count: hash.count))
        if real { return .full }
        if duress, stored.duress != nil { return .decoy }
        return nil
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
        AppConfig.passcodeIsSet = false
    }

    static func hash(_ passcode: String, salt: Data) -> Data {
        var out = Data(count: 32)
        let password = Array(passcode.utf8).map { Int8(bitPattern: $0) }
        _ = out.withUnsafeMutableBytes { outBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    outBytes.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        return out
    }

    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
