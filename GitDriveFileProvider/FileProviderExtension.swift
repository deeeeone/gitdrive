import FileProvider
import GitDriveCore
import os
import UniformTypeIdentifiers

/// Entry point the system loads for the GitHub domain. All real work happens in `SyncEngine`.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let manager: NSFileProviderManager?
    private let lock = NSLock()
    private var cachedEngine: SyncEngine?
    private let log = Logger(subsystem: "com.diwan.gitdrive", category: "extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        manager = NSFileProviderManager(for: domain)
        super.init()
    }

    func invalidate() {}

    private func engine() throws -> SyncEngine {
        try lock.withLock {
            if let cachedEngine { return cachedEngine }
            guard let token = TokenStore().read() else { throw NSFileProviderError(.notAuthenticated) }
            let db = AppConfig.sharedContainer?
                .appendingPathComponent("Library/Application Support/GitDrive", isDirectory: true)
                .appendingPathComponent("\(domain.identifier.rawValue).sqlite")
            let engine = SyncEngine(
                client: GitHubClient(token: token),
                store: try ItemStore(url: db),
                repoDeletion: { AppConfig.repoDeletion },
                lfsThreshold: { AppConfig.lfsThresholdBytes },
                identity: { IdentityStore().load() },
                encryptNewFolders: { AppConfig.encryptNewFolders }
            )
            cachedEngine = engine
            return engine
        }
    }

    // MARK: Items

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        if identifier == .rootContainer {
            completionHandler(DriveItem.root, nil)
        } else {
            do {
                guard let record = try engine().store.item(id: identifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
                completionHandler(DriveItem(record), nil)
            } catch {
                completionHandler(nil, fileProviderError(error))
            }
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        // GitDrive deletes straight to git history instead of a trash, so the trash is always empty.
        if containerItemIdentifier == .trashContainer { return EmptyEnumerator() }
        return DriveEnumerator(container: containerItemIdentifier, engine: try engine())
    }

    // MARK: Contents

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Unchecked(completionHandler)
        Task {
            do {
                let (downloaded, record) = try await self.engine().download(id: itemIdentifier.rawValue)
                let url = try self.moveToTemporaryDirectory(downloaded)
                done.value(url, DriveItem(record), nil)
            } catch {
                self.log.error("Download failed: \(String(describing: error), privacy: .public)")
                done.value(nil, nil, fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    /// The system clones the file from here, so it must live on the same volume as the domain.
    private func moveToTemporaryDirectory(_ url: URL) throws -> URL {
        guard let dir = try manager?.temporaryDirectoryURL() else { return url }
        let target = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    // MARK: Changes from Finder

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Unchecked(completionHandler)
        let name = itemTemplate.filename
        let parent = itemTemplate.parentItemIdentifier.storeID
        let type = itemTemplate.contentType ?? .data
        let modified = itemTemplate.contentModificationDate ?? nil
        let contents = url
        Task {
            do {
                if Reserved.isIgnored(filename: name) || type.conforms(to: .symbolicLink) {
                    throw NSFileProviderError(.excludedFromSync)
                }
                let engine = try self.engine()
                let record: ItemRecord
                if type.conforms(to: .folder) || type.conforms(to: .directory) {
                    record = try await engine.createFolder(parentID: parent, name: name)
                } else {
                    record = try await engine.createFile(
                        parentID: parent, name: name, contents: contents ?? Self.emptyFile(), modified: modified
                    )
                }
                done.value(DriveItem(record), [], false, nil)
            } catch {
                self.log.error("Create \(name, privacy: .private) failed: \(String(describing: error), privacy: .public)")
                done.value(nil, [], false, fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Unchecked(completionHandler)
        let id = item.itemIdentifier.rawValue
        let newName = changedFields.contains(.filename) ? item.filename : nil
        let newParent = changedFields.contains(.parentItemIdentifier) ? item.parentItemIdentifier.storeID : nil
        let contents = changedFields.contains(.contents) ? newContents : nil
        let modified = changedFields.contains(.contentModificationDate) ? (item.contentModificationDate ?? nil) : nil
        Task {
            do {
                let engine = try self.engine()
                let record: ItemRecord
                if newName == nil, newParent == nil, contents == nil {
                    // Only fields GitDrive doesn't store changed, such as tags or last-used date.
                    guard let existing = try engine.store.item(id: id) else { throw NSFileProviderError(.noSuchItem) }
                    record = existing
                } else {
                    record = try await engine.modify(
                        id: id, newName: newName, newParentID: newParent, contents: contents, modified: modified
                    )
                }
                done.value(DriveItem(record), [], false, nil)
            } catch {
                self.log.error("Modify failed: \(String(describing: error), privacy: .public)")
                done.value(nil, [], false, fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Unchecked(completionHandler)
        Task {
            do {
                try await self.engine().delete(id: identifier.rawValue)
                done.value(nil)
            } catch {
                self.log.error("Delete failed: \(String(describing: error), privacy: .public)")
                done.value(fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    private static func emptyFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        return url
    }
}

extension NSFileProviderItemIdentifier {
    /// The ID used in `ItemStore`, where the root has its own fixed name.
    var storeID: String { self == .rootContainer ? ItemStore.rootID : rawValue }
}

/// Lists nothing and never changes. Used for the trash.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Int64(0)))
    }
}
