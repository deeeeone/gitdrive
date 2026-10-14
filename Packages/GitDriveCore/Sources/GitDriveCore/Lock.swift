import Foundation

/// How much of the encrypted drive is open on this Mac right now.
public enum VaultAccess: String, Sendable {
    /// Every encrypted folder opens.
    case full
    /// Only folders marked as decoys open (after the duress passcode).
    case decoy
    /// No encrypted folder opens until the user unlocks.
    case locked
}

/// An unlock that lasts until `until`, or until the Mac sleeps.
public struct UnlockSession: Codable, Sendable, Equatable {
    public var until: Date
    public var decoy: Bool
}

/// The Touch ID and passcode gate. Shared by the app (which asks the user) and the extension (which
/// refuses to open folders while locked). It controls access on this Mac; the key stays in iCloud Keychain.
extension AppConfig {
    public static var session: UnlockSession? {
        get {
            (sharedDefaults?.data(forKey: "unlockSession")).flatMap { try? JSONDecoder().decode(UnlockSession.self, from: $0) }
        }
        set {
            sharedDefaults?.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "unlockSession")
        }
    }

    /// Set when a passcode exists. The hashes themselves live in the Keychain.
    public static var passcodeIsSet: Bool {
        get { sharedDefaults?.bool(forKey: "passcodeIsSet") ?? false }
        set { sharedDefaults?.set(newValue, forKey: "passcodeIsSet") }
    }

    public static var lockRequired: Bool {
        isOn(.touchID) || (isOn(.passcode) && passcodeIsSet)
    }

    public static var vaultAccess: VaultAccess {
        guard lockRequired else { return .full }
        guard let session, session.until > Date() else { return .locked }
        return session.decoy ? .decoy : .full
    }

    /// Encrypted repos that open with the duress passcode.
    public static var decoyRepos: Set<String> {
        get { Set(sharedDefaults?.stringArray(forKey: "decoyRepos") ?? []) }
        set { sharedDefaults?.set(Array(newValue).sorted(), forKey: "decoyRepos") }
    }

    public static func canOpen(repo: String) -> Bool {
        switch vaultAccess {
        case .full: true
        case .decoy: decoyRepos.contains(repo)
        case .locked: false
        }
    }

    /// With a passcode, locked folders disappear from Finder instead of showing as "Locked folder",
    /// so the duress passcode shows a believable drive.
    public static var hideLockedFolders: Bool { isOn(.passcode) && passcodeIsSet }

    /// Hours an unlock lasts. Sleep and screen lock end it sooner.
    public static var unlockHours: Int {
        get { (sharedDefaults?.object(forKey: "unlockHours") as? Int) ?? 8 }
        set { sharedDefaults?.set(newValue, forKey: "unlockHours") }
    }

    public static func unlock(decoy: Bool) {
        session = UnlockSession(until: Date().addingTimeInterval(Double(unlockHours) * 3600), decoy: decoy)
    }

    public static func lock() {
        session = nil
    }

    /// Changes whenever what may be opened changes, so the extension knows to re-check folders.
    public static var accessKey: String {
        "\(vaultAccess.rawValue)|\(hideLockedFolders)|\(decoyRepos.sorted().joined(separator: ","))"
    }
}
