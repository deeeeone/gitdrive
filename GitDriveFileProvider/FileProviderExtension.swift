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
    let log = Logger(subsystem: "com.diwan.gitdrive", category: "extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        manager = NSFileProviderManager(for: domain)
        super.init()
    }

    func invalidate() {}

    func engine() throws -> SyncEngine {
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
                encryptNewFolders: { AppConfig.encryptNewFolders },
                makeThumbnails: { AppConfig.isOn(.thumbnails) }
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
    func moveToTemporaryDirectory(_ url: URL) throws -> URL {
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
                // After a conflict the item holds GitHub's version and the local edit lives on as the
                // conflict copy, so macOS must download the original again.
                let refetch = await engine.takeConflict(id: id)
                done.value(DriveItem(record), [], refetch, nil)
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

// MARK: Thumbnails

/// Icon view thumbnails from the small previews saved at upload, so nothing has to download.
extension FileProviderExtension: NSFileProviderThumbnailing {
    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let each = Unchecked(perThumbnailCompletionHandler)
        let done = Unchecked(completionHandler)
        Task {
            let engine = try? self.engine()
            for id in itemIdentifiers {
                let data = AppConfig.isOn(.thumbnails) ? await engine?.thumbnail(id: id.rawValue) : nil
                each.value(id, data, nil)
                progress.completedUnitCount += 1
            }
            done.value(nil)
        }
        return progress
    }
}

// MARK: Partial downloads

/// Lets Quick Look and other readers fetch only the byte ranges they need from large plain files.
extension FileProviderExtension: NSFileProviderPartialContentFetching {
    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest,
        minimalRange requestedRange: NSRange,
        aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions = [],
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Unchecked(completionHandler)
        Task {
            do {
                let engine = try self.engine()
                if AppConfig.isOn(.quickLook),
                   let part = try await engine.partialContents(
                       id: itemIdentifier.rawValue, offset: Int64(requestedRange.location),
                       length: Int64(requestedRange.length), alignment: Int64(alignment)
                   ) {
                    let url = try self.moveToTemporaryDirectory(part.url)
                    done.value(url, DriveItem(part.item), NSRange(location: Int(part.offset), length: Int(part.length)), [], nil)
                } else {
                    let (downloaded, record) = try await engine.download(id: itemIdentifier.rawValue)
                    let url = try self.moveToTemporaryDirectory(downloaded)
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int(record.size)
                    done.value(url, DriveItem(record), NSRange(location: 0, length: size), [], nil)
                }
            } catch {
                self.log.error("Partial download failed: \(String(describing: error), privacy: .public)")
                done.value(nil, nil, NSRange(location: 0, length: 0), [], fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }
}

// MARK: Finder actions

/// Right-click actions declared in Info.plist (NSExtensionFileProviderActions). Anything with a window
/// is handed to the app, which owns all UI.
extension FileProviderExtension: NSFileProviderCustomAction {
    static let actionPrefix = "com.diwan.gitdrive.action."

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let raw = actionIdentifier.rawValue.replacingOccurrences(of: Self.actionPrefix, with: "")
        guard let kind = ToolRequest.Kind(rawValue: raw) else {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return Progress()
        }
        do {
            let store = try engine().store
            for id in itemIdentifiers {
                guard let record = try store.item(id: id.rawValue) else { continue }
                Bridge.send(ToolRequest(kind: kind, repo: record.repo, path: record.path))
            }
            completionHandler(nil)
        } catch {
            completionHandler(fileProviderError(error))
        }
        return Progress()
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
