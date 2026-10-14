import Foundation
import Security

/// Values both targets read from their Info.plist. They come from `Config/*.xcconfig`.
public enum AppConfig {
    public static var appGroup: String { value("GitDriveAppGroup") }
    public static var keychainGroup: String { value("GitDriveKeychainGroup") }
    public static var oauthClientID: String { value("GitDriveOAuthClientID") }

    /// Settings shared by the app and the extension.
    public static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    public static let repoDeletionKey = "repoDeletion"
    public static let lfsEnabledKey = "lfsEnabled"
    public static let lfsThresholdKey = "lfsThresholdMB"

    /// Off by default. LFS has its own GitHub quota (10 GiB storage and 10 GiB download a month on Free).
    public static var lfsEnabled: Bool {
        get { sharedDefaults?.bool(forKey: lfsEnabledKey) ?? false }
        set { sharedDefaults?.set(newValue, forKey: lfsEnabledKey) }
    }

    /// Files larger than this many MB go to LFS when it's on. Capped below GitHub's 100 MB file limit.
    public static var lfsThresholdMB: Int {
        get { min(sharedDefaults?.object(forKey: lfsThresholdKey) as? Int ?? 50, 99) }
        set { sharedDefaults?.set(max(1, min(newValue, 99)), forKey: lfsThresholdKey) }
    }

    /// The threshold in bytes, or nil when LFS is off.
    public static var lfsThresholdBytes: Int64? {
        lfsEnabled ? Int64(lfsThresholdMB) * 1024 * 1024 : nil
    }

    /// Defaults to deleting, which matches what deleting a folder in Finder means.
    public static var repoDeletion: RepoDeletion {
        get { sharedDefaults?.string(forKey: repoDeletionKey).flatMap(RepoDeletion.init) ?? .delete }
        set { sharedDefaults?.set(newValue.rawValue, forKey: repoDeletionKey) }
    }

    public static var sharedContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static func value(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}

/// Stores the GitHub token in the data protection Keychain, shared by the app and the extension.
public struct TokenStore: Sendable {
    public let service = "com.diwan.gitdrive"
    public let account = "github"
    public let accessGroup: String

    public init(accessGroup: String = AppConfig.keychainGroup) {
        self.accessGroup = accessGroup
    }

    private var baseQuery: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if !accessGroup.isEmpty { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        delete()
        var q = baseQuery
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not save the GitHub token to the Keychain (\(status))",
            ])
        }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// GitHub's OAuth device flow. Needs only a public Client ID, no secret.
public struct DeviceFlow: Sendable {
    public struct Code: Decodable, Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURI: URL
        public let expiresIn: Int
        public let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
            case expiresIn = "expires_in", interval
        }
    }

    public let clientID: String
    /// `delete_repo` lets deleting a top-level folder delete its repo.
    public var scope = "repo delete_repo workflow"
    private let session: URLSession

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    public func start() async throws -> Code {
        try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": scope])
    }

    /// Polls until the user approves the code in the browser. Returns the access token.
    public func waitForToken(_ code: Code) async throws -> String {
        struct Reply: Decodable { let access_token: String?; let error: String?; let interval: Int? }
        var interval = max(code.interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let reply: Reply = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = reply.access_token { return token }
            switch reply.error {
            case "authorization_pending": continue
            case "slow_down": interval = reply.interval ?? interval + 5
            case "access_denied": throw GitHubError(.unauthorized, "Sign-in was cancelled on GitHub")
            case "expired_token": throw GitHubError(.unauthorized, "The sign-in code expired. Try again.")
            default: throw GitHubError(.unauthorized, "GitHub sign-in failed: \(reply.error ?? "unknown error")")
            }
        }
        throw GitHubError(.unauthorized, "The sign-in code expired. Try again.")
    }

    private func post<T: Decodable>(_ url: String, _ form: [String: String]) async throws -> T {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension GitHubClient {
    /// Replaces a repo's history with a single commit holding the current files, then force-pushes it.
    /// Deleted files stop counting toward the repo's size once GitHub garbage-collects.
    public func compactHistory(owner: String, repo: String, branch: String) async throws {
        let head = try await headSHA(owner: owner, repo: repo, branch: branch)
        let tree = try await treeSHA(owner: owner, repo: repo, commit: head)
        let commit = try await createCommit(owner: owner, repo: repo, message: "Compact history (GitDrive)", tree: tree, parents: [])
        try await updateRef(owner: owner, repo: repo, branch: branch, sha: commit, force: true)
    }
}

/// Keeps the vault private key in the data protection Keychain with iCloud Keychain sync on,
/// so every Mac signed in to the same iCloud account can open encrypted folders.
public struct IdentityStore: Sendable {
    public let service = "com.diwan.gitdrive.vault"
    public let account = "identity"
    public let accessGroup: String

    public init(accessGroup: String = AppConfig.keychainGroup) {
        self.accessGroup = accessGroup
    }

    private func query(synchronizable: CFTypeRef) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        if !accessGroup.isEmpty { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func load() -> VaultIdentity? {
        var q = query(synchronizable: kSecAttrSynchronizableAny)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? VaultIdentity(secret: data)
    }

    /// Saves the key with iCloud sync. Never overwrites an existing key, since that would lock every folder made with it.
    public func save(_ identity: VaultIdentity) throws {
        guard load() == nil else { return }
        var q = query(synchronizable: kCFBooleanTrue)
        q[kSecValueData as String] = identity.secret
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecAttrLabel as String] = "GitDrive encryption key"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Could not save the encryption key to the Keychain (\(status))",
            ])
        }
    }

    /// Loads the key, creating and saving one the first time.
    public func loadOrCreate() throws -> VaultIdentity {
        if let existing = load() { return existing }
        let identity = try VaultIdentity.generate()
        try save(identity)
        return identity
    }
}

extension AppConfig {
    public static let encryptNewFoldersKey = "encryptNewFolders"

    /// Off by default. When on, new top-level folders are created encrypted.
    public static var encryptNewFolders: Bool {
        get { sharedDefaults?.bool(forKey: encryptNewFoldersKey) ?? false }
        set { sharedDefaults?.set(newValue, forKey: encryptNewFoldersKey) }
    }
}
