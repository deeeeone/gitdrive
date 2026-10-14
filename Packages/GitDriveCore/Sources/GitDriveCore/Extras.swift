import Foundation

/// Optional features. Each has a switch in Settings → Extras, so the core app stays simple.
public enum Extra: String, CaseIterable, Sendable, Identifiable {
    case syncBadges, quickLook, search, thumbnails
    case versions, recentlyDeleted, conflictViewer, duplicates, bitRot
    case touchID, passcode, tripwire
    case photos, notes, backup
    case publish, cloudRun, codespaces

    public enum Group: String, CaseIterable, Sendable {
        case finder = "Finder"
        case history = "History and files"
        case safety = "Privacy and safety"
        case modes = "Modes"
        case github = "GitHub"
    }

    public var id: String { rawValue }

    public var group: Group {
        switch self {
        case .syncBadges, .quickLook, .search, .thumbnails: .finder
        case .versions, .recentlyDeleted, .conflictViewer, .duplicates, .bitRot: .history
        case .touchID, .passcode, .tripwire: .safety
        case .photos, .notes, .backup: .modes
        case .publish, .cloudRun, .codespaces: .github
        }
    }

    public var title: String {
        switch self {
        case .syncBadges: "Sync badges"
        case .quickLook: "Quick Look without downloading"
        case .search: "Search files that aren't downloaded"
        case .thumbnails: "Thumbnails without downloading"
        case .versions: "Show Versions"
        case .recentlyDeleted: "Recently Deleted"
        case .conflictViewer: "Conflict viewer"
        case .duplicates: "Duplicate finder"
        case .bitRot: "Monthly bit-rot check"
        case .touchID: "Require Touch ID for encrypted folders"
        case .passcode: "Passcode and decoy folders"
        case .tripwire: "Ransomware tripwire"
        case .photos: "Photos"
        case .notes: "Notes"
        case .backup: "Backups"
        case .publish: "Publish as website"
        case .cloudRun: "Run in the cloud"
        case .codespaces: "Open in Codespaces"
        }
    }

    public var summary: String {
        switch self {
        case .syncBadges: "Marks conflict copies in Finder."
        case .quickLook: "Previews large files by downloading only the parts Quick Look needs."
        case .search: "Finder and Spotlight find files by name before they're downloaded, including names in encrypted folders."
        case .thumbnails: "Saves a small thumbnail with each new photo or video, so icon view works without downloading. Encrypted with the folder in encrypted folders."
        case .versions: "Right-click a file to see and restore earlier versions from git history."
        case .recentlyDeleted: "See files deleted in the last 30 days and put them back."
        case .conflictViewer: "Compare a conflict copy with the original side by side and choose which to keep."
        case .duplicates: "Finds files stored more than once across your folders."
        case .bitRot: "Once a month, checks that downloaded files still match what's on GitHub."
        case .touchID: "Encrypted folders stay locked until you unlock them with Touch ID or your Mac password, and lock again when the Mac sleeps."
        case .passcode: "A GitDrive passcode unlocks encrypted folders. A second passcode unlocks only the folders you mark as decoys."
        case .tripwire: "If many files suddenly turn into random-looking data, GitDrive pauses syncing and offers to roll back the last hour."
        case .photos: "A timeline, map and albums for folders of photos."
        case .notes: "Markdown folders as a simple notes app with [[links]] and backlinks."
        case .backup: "Scheduled, versioned backups of Mac folders into GitDrive."
        case .publish: "Right-click a folder to copy it to a public repo served by GitHub Pages."
        case .cloudRun: "Right-click a video or document to compress or convert it with GitHub Actions."
        case .codespaces: "Right-click a folder to open its repo in a cloud editor."
        }
    }

    /// Features that cost nothing until used are on by default; anything that changes behaviour is off.
    public var defaultOn: Bool {
        switch self {
        case .syncBadges, .quickLook, .search, .thumbnails, .versions, .recentlyDeleted, .conflictViewer, .duplicates, .tripwire:
            true
        default:
            false
        }
    }
}

extension AppConfig {
    public static func isOn(_ extra: Extra) -> Bool {
        (sharedDefaults?.object(forKey: "extra." + extra.rawValue) as? Bool) ?? extra.defaultOn
    }

    public static func set(_ extra: Extra, on: Bool) {
        sharedDefaults?.set(on, forKey: "extra." + extra.rawValue)
    }
}
