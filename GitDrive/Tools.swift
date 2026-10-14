import GitDriveCore
import SwiftUI

/// Routes Finder requests to feature windows. Each Extra registers its window here.
@MainActor
enum Tools {
    static func open(_ request: ToolRequest, model: AppModel) {
        switch request.kind {
        case .versions:
            ToolWindows.show("Versions", id: "versions-\(request.repo)-\(request.path)") {
                VersionsView(model: model, repo: request.repo, path: request.path)
            }
        case .photos:
            showPhotos(model: model)
        case .notes:
            showNotes(model: model)
        case .conflict:
            showConflicts(model: model, focus: request.path)
        case .recentlyDeleted:
            showRecentlyDeleted(model: model, repo: request.repo.isEmpty ? nil : request.repo)
        default:
            break
        }
    }

    static func showNotes(model: AppModel) {
        ToolWindows.show("Notes", id: "notes", size: CGSize(width: 900, height: 600)) { NotesView(model: model) }
    }

    static func showPhotos(model: AppModel) {
        ToolWindows.show("Photos", id: "photos", size: CGSize(width: 860, height: 600)) { PhotosView(model: model) }
    }

    static func showConflicts(model: AppModel, focus: String? = nil) {
        ToolWindows.show("Conflicts", id: "conflicts", size: CGSize(width: 820, height: 520)) {
            ConflictView(model: model, focus: focus)
        }
    }

    static func showRecentlyDeleted(model: AppModel, repo: String? = nil) {
        ToolWindows.show("Recently Deleted", id: "deleted-\(repo ?? "all")") {
            RecentlyDeletedView(model: model, repo: repo)
        }
    }

    /// Gives a temporary download a readable name, so the opening app shows the right title.
    static func named(_ url: URL, _ filename: String, suffix date: Date? = nil) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = filename
        if let date {
            let stamp = date.formatted(.iso8601.year().month().day())
            let ext = (filename as NSString).pathExtension
            let base = (filename as NSString).deletingPathExtension
            name = ext.isEmpty ? "\(base) (\(stamp))" : "\(base) (\(stamp)).\(ext)"
        }
        let target = dir.appendingPathComponent(name)
        try? FileManager.default.moveItem(at: url, to: target)
        return target
    }
}
