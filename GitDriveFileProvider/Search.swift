import FileProvider
import GitDriveCore
import UniformTypeIdentifiers

/// Finder and Spotlight search for files that aren't downloaded, answered from the local index.
@available(macOS 26.0, *)
extension FileProviderExtension: NSFileProviderSearching {
    func searchEnumerator(for request: NSFileProviderStringSearchRequest) -> any NSFileProviderSearchEnumerator {
        SearchEnumerator(query: request.query, limit: max(request.desiredNumberOfResults, 20), store: try? engine().store)
    }
}

@available(macOS 26.0, *)
final class SearchEnumerator: NSObject, NSFileProviderSearchEnumerator, @unchecked Sendable {
    private let query: String
    private let limit: Int
    private let store: ItemStore?

    init(query: String, limit: Int, store: ItemStore?) {
        self.query = query
        self.limit = limit
        self.store = store
    }

    func invalidate() {}

    func enumerateSearchResults(for observer: any NSFileProviderSearchEnumerationObserver, startingAt page: NSFileProviderPage?) {
        guard AppConfig.isOn(.search), let store else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        do {
            let items = try store.search(query, limit: min(limit, observer.maximumNumberOfResultsPerPage))
            observer.didEnumerate(items.map { SearchResult(DriveItem($0)) })
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }
}

@available(macOS 26.0, *)
final class SearchResult: NSObject, NSFileProviderSearchResult {
    let itemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let creationDate: Date?
    let contentModificationDate: Date?
    let lastUsedDate: Date? = nil
    let contentType: UTType
    let documentSize: NSNumber?

    init(_ item: DriveItem) {
        itemIdentifier = item.itemIdentifier
        filename = item.filename
        creationDate = item.creationDate ?? nil
        contentModificationDate = item.contentModificationDate ?? nil
        contentType = item.contentType
        documentSize = item.documentSize ?? nil
    }
}
