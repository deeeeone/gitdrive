import AppKit
import SwiftUI

/// Opens small feature windows (Versions, Recently Deleted and so on) from anywhere in the app,
/// including from requests that arrive from Finder while no other window is open.
@MainActor
enum ToolWindows {
    private static var windows: [String: NSWindow] = [:]

    static func show<Content: View>(_ title: String, id: String, size: CGSize = CGSize(width: 560, height: 420), @ViewBuilder content: () -> Content) {
        NSApp.activate()
        if let existing = windows[id], existing.isVisible {
            existing.contentViewController = NSHostingController(rootView: content())
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[id] = window
    }
}
