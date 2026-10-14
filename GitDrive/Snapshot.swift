#if DEBUG
import AppKit
import SwiftUI

/// Shows the live menu panel in a plain window so it can be captured for the README.
/// Run a Debug build with GITDRIVE_SNAPSHOT=light or GITDRIVE_SNAPSHOT=dark, then
/// `screencapture -l <window id>` the window. The app quits after 20 seconds.
@MainActor
enum Snapshot {
    private static var window: NSWindow?

    static func renderIfRequested(model: AppModel) {
        guard let mode = ProcessInfo.processInfo.environment["GITDRIVE_SNAPSHOT"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            let host = NSHostingView(rootView: MenuView().environment(model))
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: host.fittingSize),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.title = "GitDrive Snapshot"
            panel.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
            panel.contentView = host
            panel.center()
            panel.orderFrontRegardless()
            window = panel
            try? await Task.sleep(for: .seconds(20))
            NSApp.terminate(nil)
        }
    }
}
#endif
