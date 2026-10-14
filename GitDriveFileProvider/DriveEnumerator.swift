import FileProvider
import GitDriveCore
import os

/// Lists a folder, the root, or the working set, and reports changes since a sync anchor.
final class DriveEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let container: NSFileProviderItemIdentifier
    private let engine: SyncEngine
    private let log = Logger(subsystem: "com.diwan.gitdrive", category: "enumerator")

    init(container: NSFileProviderItemIdentifier, engine: SyncEngine) {
        self.container = container
        self.engine = engine
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Unchecked(observer)
        Task {
            do {
                let items = try await self.listing()
                for chunk in stride(from: 0, to: items.count, by: 200) {
                    observer.value.didEnumerate(items[chunk..<min(chunk + 200, items.count)].map(DriveItem.init))
                }
                observer.value.finishEnumerating(upTo: nil)
            } catch {
                self.log.error("Listing failed: \(String(describing: error), privacy: .public)")
                observer.value.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    private func listing() async throws -> [ItemRecord] {
        let store = engine.store
        switch container {
        case .workingSet:
            try await syncQuietly()
            return try store.allItems()
        case .rootContainer:
            try await engine.syncRepoListIfStale()
            return try store.children(of: ItemStore.rootID)
        default:
            guard let folder = try store.item(id: container.rawValue) else { throw NSFileProviderError(.noSuchItem) }
            try await engine.syncRepo(folder.repo)
            return try store.children(of: folder.id)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        let observer = Unchecked(observer)
        let since = syncAnchor.seq
        let parent: String?
        switch container {
        case .workingSet: parent = nil
        case .rootContainer: parent = ItemStore.rootID
        default: parent = container.rawValue
        }
        let isWorkingSet = container == .workingSet
        Task {
            await self.reportChanges(to: observer, since: since, parent: parent, sync: isWorkingSet)
        }
    }

    private func reportChanges(to observer: Unchecked<NSFileProviderChangeObserver>, since: Int64, parent: String?, sync: Bool) async {
        do {
            if sync { try await syncQuietly() }
            let extras = AppConfig.extrasVersion
            if extras != UserDefaults.standard.integer(forKey: "seenExtrasVersion") {
                try engine.store.reannounceAll()
                UserDefaults.standard.set(extras, forKey: "seenExtrasVersion")
            }
            let changes = try engine.store.changes(since: since, parentID: parent)
            if !changes.updated.isEmpty { observer.value.didUpdate(changes.updated.map(DriveItem.init)) }
            if !changes.deleted.isEmpty {
                observer.value.didDeleteItems(withIdentifiers: changes.deleted.map { NSFileProviderItemIdentifier($0) })
            }
            observer.value.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(changes.anchor), moreComing: false)
        } catch {
            observer.value.finishEnumeratingWithError(fileProviderError(error))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor((try? engine.store.currentAnchor()) ?? 0))
    }

    /// Network trouble shouldn't hide what is already known locally. Only sign-in problems are reported.
    private func syncQuietly() async throws {
        do {
            try await engine.syncAll()
        } catch let e as GitHubError where e.kind == .unauthorized {
            throw e
        } catch {
            log.notice("Sync skipped: \(String(describing: error), privacy: .public)")
        }
    }
}

extension NSFileProviderSyncAnchor {
    init(_ seq: Int64) {
        self.init(withUnsafeBytes(of: seq.bigEndian) { Data($0) })
    }

    var seq: Int64 {
        guard rawValue.count == 8 else { return 0 }
        return Int64(bigEndian: rawValue.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
    }
}

/// Carries a non-Sendable File Provider object into a Task. The system allows calling observers from any thread.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Maps GitDrive errors onto the errors Finder knows how to show.
func fileProviderError(_ error: Error) -> Error {
    if error is NSFileProviderError { return error }
    if let e = error as? GitHubError {
        switch e.kind {
        case .unauthorized: return NSFileProviderError(.notAuthenticated)
        case .transport, .rateLimited, .server: return NSFileProviderError(.serverUnreachable)
        case .notFound: return NSFileProviderError(.noSuchItem)
        case .conflict, .emptyRepo, .tooLarge: return withMessage(e.message)
        }
    }
    if let e = error as? DriveError {
        switch e {
        case .noSuchItem: return NSFileProviderError(.noSuchItem)
        case .filenameCollision: return NSFileProviderError(.filenameCollision)
        default: return withMessage(e.description)
        }
    }
    return error
}

private func withMessage(_ message: String) -> Error {
    NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [NSLocalizedDescriptionKey: message])
}
