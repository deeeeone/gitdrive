#if DEBUG
import AppKit
import GitDriveCore
import SwiftUI

/// Shows the live menu panel in a plain window so it can be captured for the README.
/// Run a Debug build with GITDRIVE_SNAPSHOT=light or GITDRIVE_SNAPSHOT=dark, then
/// `screencapture -l <window id>` the window. The app quits after 20 seconds.
@MainActor
enum Snapshot {
    private static var window: NSWindow?

    /// GITDRIVE_DEFAULTS="lfsEnabled=true,lfsThresholdMB=1" writes shared settings and quits.
    /// The App Group container is closed to other processes, so this is the only way to script them.
    static func applyDefaultsIfRequested() {
        guard let spec = ProcessInfo.processInfo.environment["GITDRIVE_DEFAULTS"], let defaults = AppConfig.sharedDefaults else { return }
        for pair in spec.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if let int = Int(parts[1]) { defaults.set(int, forKey: parts[0]) }
            else if let bool = Bool(parts[1]) { defaults.set(bool, forKey: parts[0]) }
            else { defaults.set(parts[1], forKey: parts[0]) }
        }
        defaults.synchronize()
        exit(0)
    }

    /// GITDRIVE_SETUP_KEY=1 does what Settings → Encryption → Set Up Encryption does, prints the
    /// fingerprint and quits. Never replaces an existing key.
    static func setUpKeyIfRequested() {
        guard ProcessInfo.processInfo.environment["GITDRIVE_SETUP_KEY"] != nil else { return }
        do {
            print("key", try IdentityStore().loadOrCreate().keyID)
            exit(0)
        } catch {
            print("error", error)
            exit(1)
        }
    }

    /// GITDRIVE_REQUEST="versions|drive-repo|path/in/repo" sends a Finder action request to the running app and quits.
    static func sendRequestIfAsked() {
        guard let spec = ProcessInfo.processInfo.environment["GITDRIVE_REQUEST"] else { return }
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let kind = ToolRequest.Kind(rawValue: parts[0]) else { exit(1) }
        Bridge.send(ToolRequest(kind: kind, repo: parts[1], path: parts[2]))
        exit(0)
    }

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
