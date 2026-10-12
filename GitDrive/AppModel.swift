import AppKit
import FileProvider
import GitDriveCore
import Observation
import os
import ServiceManagement

/// App state behind the menu bar UI: sign-in, the File Provider domain, polling and folder sizes.
@MainActor
@Observable
final class AppModel {
    enum Account: Equatable {
        case unknown
        case signedOut
        case waitingForApproval(code: String, url: URL)
        case signedIn(login: String)
    }

    enum Status: Equatable {
        case idle
        case syncing
        case paused
        case error(String)
    }

    var account: Account = .unknown
    var status: Status = .idle
    var repos: [Repo] = []
    var otherRepos: [Repo] = []
    var lastSync: Date?
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let tokens = TokenStore()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.diwan.gitdrive", category: "app")

    static let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("github"), displayName: "GitHub")
    private var manager: NSFileProviderManager? { NSFileProviderManager(for: Self.domain) }
    private var client: GitHubClient? { tokens.read().map { GitHubClient(token: $0) } }

    var hasOAuthClientID: Bool { !AppConfig.oauthClientID.isEmpty }
    var totalSizeKB: Int { repos.reduce(0) { $0 + $1.size } }

    var menuBarSymbol: String {
        switch (account, status) {
        case (.signedIn, .syncing): "arrow.triangle.2.circlepath.icloud"
        case (.signedIn, .error): "exclamationmark.icloud"
        case (.signedIn, .paused): "icloud.slash"
        case (.signedIn, .idle): "checkmark.icloud"
        default: "icloud"
        }
    }

    init() {
        Task { await start() }
    }

    // MARK: Lifecycle

    func start() async {
        guard let client else {
            account = .signedOut
            return
        }
        do {
            let user = try await client.currentUser()
            account = .signedIn(login: user.login)
            try await addDomain()
            startPolling()
        } catch let e as GitHubError where e.kind == .unauthorized {
            tokens.delete()
            account = .signedOut
        } catch {
            // Offline at launch: stay signed in and keep retrying through the poller.
            account = .signedIn(login: "")
            status = .error(error.localizedDescription)
            startPolling()
        }
    }

    private func addDomain() async throws {
        try await NSFileProviderManager.add(Self.domain)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.refresh(includeSizes: tick % 5 == 0)
                tick += 1
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Asks the extension to pull remote changes and refreshes the folder list.
    func refresh(includeSizes: Bool = true) async {
        guard case .signedIn = account, status != .paused, let client else { return }
        status = .syncing
        do {
            try await manager?.signalEnumerator(for: .workingSet)
            if includeSizes {
                let all = try await client.ownedRepos()
                repos = all.filter { $0.isDrive && !$0.archived }
                otherRepos = all.filter { !$0.isDrive && !$0.archived }
            }
            if case let .signedIn(login) = account, login.isEmpty {
                account = .signedIn(login: try await client.currentUser().login)
            }
            lastSync = Date()
            status = .idle
        } catch {
            log.error("Refresh failed: \(String(describing: error), privacy: .public)")
            status = .error((error as? GitHubError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: Sign-in

    func signInWithBrowser() {
        signInTask?.cancel()
        signInTask = Task {
            do {
                let flow = DeviceFlow(clientID: AppConfig.oauthClientID)
                let code = try await flow.start()
                account = .waitingForApproval(code: code.userCode, url: code.verificationURI)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(code.verificationURI)
                let token = try await flow.waitForToken(code)
                try await finishSignIn(token: token)
            } catch is CancellationError {
                account = .signedOut
            } catch {
                account = .signedOut
                status = .error((error as? GitHubError)?.message ?? error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        account = .signedOut
    }

    /// For people who prefer a fine-grained or classic personal access token with repo access.
    func signIn(withToken token: String) async {
        do {
            try await finishSignIn(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            status = .error((error as? GitHubError)?.message ?? error.localizedDescription)
        }
    }

    private func finishSignIn(token: String) async throws {
        let user = try await GitHubClient(token: token).currentUser()
        try tokens.save(token)
        account = .signedIn(login: user.login)
        status = .idle
        try await addDomain()
        startPolling()
    }

    /// Removes the drive from this Mac. Everything stays on GitHub.
    func signOut() async {
        pollTask?.cancel()
        try? await NSFileProviderManager.remove(Self.domain)
        tokens.delete()
        repos = []
        otherRepos = []
        account = .signedOut
        status = .idle
    }

    // MARK: Actions

    func openInFinder() async {
        do {
            guard let url = try await manager?.getUserVisibleURL(for: .rootContainer) else { return }
            // The URL is security-scoped; the sandbox blocks it until access is started.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Removes downloaded copies. Files stay listed and download again when opened.
    func freeUpSpace() async {
        guard let manager, let root = try? await manager.getUserVisibleURL(for: .rootContainer) else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var failed = 0
        for folder in folders {
            do { try FileManager.default.evictUbiquitousItem(at: folder) } catch { failed += 1 }
        }
        if failed > 0 { status = .error("Some files are open or not synced yet, so they were kept") }
    }

    func togglePause() async {
        guard let manager else { return }
        do {
            if status == .paused {
                try await manager.reconnect()
                status = .idle
                await refresh()
            } else {
                try await manager.disconnect(reason: "GitDrive is paused", options: .temporary)
                status = .paused
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = .error(error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Adds an existing repo to the drive by renaming it to `drive-<name>`.
    func addToDrive(_ repo: Repo) async {
        guard let client else { return }
        do {
            _ = try await client.renameRepo(owner: repo.owner.login, name: repo.name, to: Reserved.repoPrefix + repo.name)
            await refresh()
        } catch {
            status = .error((error as? GitHubError)?.message ?? error.localizedDescription)
        }
    }

    func compactHistory(_ repo: Repo) async {
        guard let client else { return }
        do {
            try await client.compactHistory(owner: repo.owner.login, repo: repo.name, branch: repo.defaultBranch ?? "main")
            await refresh()
        } catch {
            status = .error((error as? GitHubError)?.message ?? error.localizedDescription)
        }
    }
}

extension Int {
    /// Formats a size given in KB, the unit GitHub reports repo sizes in.
    var kilobytesFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(self) * 1024, countStyle: .file)
    }
}
