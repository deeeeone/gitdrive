import GitDriveCore
import SwiftUI

/// Routes Finder requests to feature windows. Each Extra registers its window here.
@MainActor
enum Tools {
    static func open(_ request: ToolRequest, model: AppModel) {
        switch request.kind {
        default:
            break
        }
    }
}
