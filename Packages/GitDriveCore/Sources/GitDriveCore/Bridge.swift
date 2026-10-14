import Foundation
import notify

/// Something the File Provider extension asks the app to do, usually from a Finder right-click action.
/// The extension has no UI, so anything with a window happens in the app.
public struct ToolRequest: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case versions, recentlyDeleted, conflict, publish, codespaces, compressVideo, convertPDF, tripwire
    }

    public var id = UUID()
    public let kind: Kind
    /// Repo and path of the item the action was used on, as the extension's index knows them.
    public let repo: String
    public let path: String

    public init(kind: Kind, repo: String, path: String) {
        self.kind = kind
        self.repo = repo
        self.path = path
    }
}

/// Hands requests from the extension to the app through the shared App Group folder and a Darwin notification.
public enum Bridge {
    static let notification = "com.diwan.gitdrive.request"

    static var folder: URL? {
        AppConfig.sharedContainer?.appendingPathComponent("Library/Application Support/GitDrive/Requests", isDirectory: true)
    }

    public static func send(_ request: ToolRequest) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(request) else { return }
        try? data.write(to: folder.appendingPathComponent("\(request.id.uuidString).json"), options: .atomic)
        notify_post(notification)
    }

    /// Reads and removes every waiting request, oldest first.
    public static func drain() -> [ToolRequest] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        return sorted.compactMap { url in
            defer { try? FileManager.default.removeItem(at: url) }
            return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ToolRequest.self, from: $0) }
        }
    }

    /// Calls `handler` on the main queue whenever the extension sends something. Keep the token alive.
    public static func observe(_ handler: @escaping @Sendable () -> Void) -> Int32 {
        var token: Int32 = 0
        notify_register_dispatch(notification, &token, .main) { _ in handler() }
        return token
    }
}
