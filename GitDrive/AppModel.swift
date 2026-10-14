import AppKit
@preconcurrency import FileProvider
import LocalAuthentication
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
    /// False when the token is known to lack `delete_repo`. Nil when GitHub doesn't say.
    var canDeleteRepos: Bool?
    var repoDeletion = AppConfig.repoDeletion {
        didSet { AppConfig.repoDeletion = repoDeletion }
    }
    var lfsEnabled = AppConfig.lfsEnabled {
        didSet { AppConfig.lfsEnabled = lfsEnabled }
    }
    var lfsThresholdMB = AppConfig.lfsThresholdMB {
        didSet { AppConfig.lfsThresholdMB = lfsThresholdMB }
    }

    /// A top-level folder as shown in the UI. Encrypted folders get their real name from the sealed index.
    struct Folder: Identifiable, Equatable {
        let repo: Repo
        let name: String
        let encrypted: Bool
        var id: String { repo.name }
    }

    var folders: [Folder] = []
    var access = AppConfig.vaultAccess
    var conflictCount = 0
    var encryptionKeyID: String? = IdentityStore().load()?.keyID
    var encryptNewFolders = AppConfig.encryptNewFolders {
        didSet { AppConfig.encryptNewFolders = encryptNewFolders }
    }
    /// Progress of an "Encrypt" job: folder name, files done, total files.
    var encrypting: (name: String, done: Int, total: Int)?
    var encryptionAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    @ObservationIgnored private let tokens = TokenStore()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.diwan.gitdrive", category: "app")
    /// The app's own engine with an in-memory index. Used to read encrypted folder names and to
    /// encrypt folders; the extension keeps the real index.
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var bridgeToken: Int32 = 0

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
        #if DEBUG
        Snapshot.applyDefaultsIfRequested()
        Snapshot.setUpKeyIfRequested()
        Snapshot.sendRequestIfAsked()
        #endif
        Task { await start() }
        bridgeToken = Bridge.observe { Task { @MainActor in self.handleRequests() } }
        watchForSleep()
        #if DEBUG
        Snapshot.renderIfRequested(model: self)
        #endif
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
        if #available(macOS 26, *) { Self.domain.supportsStringSearchRequest = AppConfig.isOn(.search) }
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
        if access != AppConfig.vaultAccess { access = AppConfig.vaultAccess }
        status = .syncing
        do {
            try await manager?.signalEnumerator(for: .workingSet)
            if includeSizes {
                let all = try await client.ownedRepos()
                repos = all.filter { $0.isDrive && !$0.archived }
                otherRepos = all.filter { !$0.isDrive && !$0.archived }
            }
            if includeSizes {
                canDeleteRepos = try await client.tokenScopes().map { $0.contains("delete_repo") }
                await loadFolders(client: client)
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

    /// The app's engine, synced with GitHub, for feature windows.
    func readyEngine() async throws -> SyncEngine {
        guard let client, let engine = appEngine(client) else { throw GitHubError(.unauthorized, "Sign in to GitHub first") }
        if try engine.store.repos().isEmpty { try await engine.syncAll() }
        return engine
    }

    /// Requests from Finder right-click actions. Each feature adds its own case.
    func handleRequests() {
        for request in Bridge.drain() {
            log.info("Request \(request.kind.rawValue, privacy: .public)")
            Tools.open(request, model: self)
        }
    }

    private func appEngine(_ client: GitHubClient) -> SyncEngine? {
        if let engine { return engine }
        guard let store = try? ItemStore(url: nil) else { return nil }
        let engine = SyncEngine(
            client: client, store: store,
            repoDeletion: { .delete },
            lfsThreshold: { AppConfig.lfsThresholdBytes },
            identity: { IdentityStore().load() },
            makeThumbnails: { AppConfig.isOn(.thumbnails) },
            canOpen: { AppConfig.canOpen(repo: $0) },
            hideLocked: { AppConfig.hideLockedFolders },
            accessKey: { AppConfig.accessKey }
        )
        self.engine = engine
        return engine
    }

    private func loadFolders(client: GitHubClient) async {
        guard let engine = appEngine(client) else { return }
        do {
            try await engine.syncAll()
        } catch {
            log.notice("Folder names not refreshed: \(String(describing: error), privacy: .public)")
        }
        var list: [Folder] = []
        for repo in repos {
            let name = (try? engine.store.item(repo: repo.name, path: "")?.filename) ?? repo.displayName
            list.append(Folder(repo: repo, name: name, encrypted: await engine.isEncrypted(repo: repo.name)))
        }
        folders = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        conflictCount = (try? await engine.conflicts().count) ?? 0
    }

    /// Called when an Extra is switched on or off in Settings.
    func extraChanged(_ extra: Extra) {
        Task {
            // Search support is a property of the domain, so the domain is added again to apply it.
            if extra == .search, case .signedIn = account { try? await addDomain() }
            try? await manager?.signalEnumerator(for: .workingSet)
        }
    }

    // MARK: Locking

    /// Locks encrypted folders when the Mac sleeps or the screen locks.
    private func watchForSleep() {
        let lockNow: @Sendable (Notification) -> Void = { _ in Task { @MainActor in self.lock() } }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockNow)
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lockNow)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockNow
        )
    }

    var hasEncryptedFolders: Bool { encryptionKeyID != nil }

    func lock() {
        guard AppConfig.lockRequired, AppConfig.session != nil else { return }
        AppConfig.lock()
        accessChanged()
    }

    /// Touch ID, or the Mac password when Touch ID isn't available.
    func unlockWithTouchID() async {
        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your encrypted GitDrive folders")
            AppConfig.unlock(decoy: false)
            accessChanged()
        } catch {
            log.notice("Unlock cancelled: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts the unlock the settings call for. The passcode Extra adds its own prompt.
    func beginUnlock() {
        Task { await unlockWithTouchID() }
    }

    func accessChanged() {
        access = AppConfig.vaultAccess
        Task {
            try? await manager?.signalEnumerator(for: .workingSet)
            if let client { await loadFolders(client: client) }
        }
    }

    // MARK: Encryption

    /// Creates the post-quantum key pair and saves it to iCloud Keychain. Never replaces an existing key.
    func setUpEncryption() {
        do {
            encryptionKeyID = try IdentityStore().loadOrCreate().keyID
        } catch {
            status = .error((error as? VaultError)?.description ?? error.localizedDescription)
        }
    }

    /// Copies a plain folder into a new encrypted repo, then deletes the plain repo.
    func encrypt(_ folder: Folder) async {
        guard let client, let engine = appEngine(client), encryptionKeyID != nil else { return }
        guard canDeleteRepos != false else {
            status = .error("Encrypting deletes the readable repo afterwards, which needs a token with the delete_repo scope. Sign out and sign in with a new token first.")
            return
        }
        encrypting = (folder.name, 0, 0)
        do {
            _ = try await engine.encrypt(repo: folder.repo.name) { done, total in
                Task { @MainActor in self.encrypting = (folder.name, done, total) }
            }
        } catch {
            status = .error("Couldn't encrypt \(folder.name): \((error as? GitHubError)?.message ?? String(describing: error))")
        }
        encrypting = nil
        await refresh()
    }

    /// Copies an encrypted folder back into a normal readable repo, then deletes the encrypted repo.
    func decrypt(_ folder: Folder) async {
        guard let client, let engine = appEngine(client) else { return }
        guard canDeleteRepos != false else {
            status = .error("Decrypting deletes the encrypted repo afterwards, which needs a token with the delete_repo scope. Sign out and sign in with a new token first.")
            return
        }
        encrypting = (folder.name, 0, 0)
        do {
            _ = try await engine.decrypt(repo: folder.repo.name) { done, total in
                Task { @MainActor in self.encrypting = (folder.name, done, total) }
            }
        } catch {
            let message = (error as? GitHubError)?.message ?? (error as? DriveError)?.description ?? String(describing: error)
            status = .error("Couldn't decrypt \(folder.name): \(message)")
        }
        encrypting = nil
        await refresh()
    }

    func encryptAll() async {
        for folder in folders where !folder.encrypted {
            await encrypt(folder)
            if case .error = status { return }
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
        folders = []
        engine = nil
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
        if self == 0 { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: Int64(self) * 1024, countStyle: .file)
    }
}
