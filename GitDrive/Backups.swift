import AppKit
import GitDriveCore
import Observation

/// Mac folders backed up into GitDrive once a day while the app runs, plus Back Up Now.
@MainActor
@Observable
final class Backups {
    struct Source: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        /// Security-scoped bookmark, so the sandboxed app can read the folder after restarts.
        var bookmark: Data
        var repo: String?
        var lastRun: Date?
        var lastResult: String?
    }

    var sources: [Source] = []
    var running: UUID?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        sources = (UserDefaults.standard.data(forKey: "backupSources")).flatMap { try? JSONDecoder().decode([Source].self, from: $0) } ?? []
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in Task { @MainActor in await self.runDue() } }
        Task { try? await Task.sleep(for: .seconds(120)); await runDue() }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(sources), forKey: "backupSources")
    }

    func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Back Up"
        panel.message = "Choose a folder to back up to GitDrive every day"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        sources.append(Source(name: url.lastPathComponent, bookmark: bookmark))
        save()
        Task { await run(sources[sources.count - 1].id) }
    }

    func remove(_ id: UUID) {
        sources.removeAll { $0.id == id }
        save()
    }

    func runDue() async {
        guard AppConfig.isOn(.backup) else { return }
        for source in sources where (source.lastRun.map { Date().timeIntervalSince($0) > 86_000 } ?? true) {
            await run(source.id)
        }
    }

    func run(_ id: UUID) async {
        guard running == nil, let index = sources.firstIndex(where: { $0.id == id }), let model else { return }
        var source = sources[index]
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: source.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            source.lastResult = "Can't open the folder any more. Remove it and add it again."
            sources[index] = source
            save()
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        running = id
        do {
            let engine = try await model.readyEngine()
            let result = try await engine.backup(url, into: source.repo, name: source.name, encrypt: model.encryptionKeyID != nil)
            source.repo = result.repo
            source.lastRun = Date()
            var parts = ["\(result.uploaded) uploaded", "\(result.deleted) removed", "\(result.unchanged) unchanged"]
            if result.skipped > 0 { parts.append("\(result.skipped) too large without Git LFS") }
            source.lastResult = parts.joined(separator: ", ")
        } catch {
            source.lastResult = "Failed: \(String(describing: error))"
        }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            source.bookmark = fresh
        }
        if let i = sources.firstIndex(where: { $0.id == id }) { sources[i] = source }
        save()
        running = nil
        await model.refresh()
    }
}
