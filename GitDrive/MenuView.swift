import GitDriveCore
import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            switch model.account {
            case .unknown:
                ProgressView().frame(maxWidth: .infinity)
            case .signedOut:
                SignInView()
            case let .waitingForApproval(code, url):
                ApprovalView(code: code, url: url)
            case .signedIn:
                FolderList()
                Divider()
                actions
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("GitDrive").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
    }

    private var statusText: String {
        switch model.status {
        case .syncing: return "Checking GitHub for changes"
        case .paused: return "Paused"
        case let .error(message): return message
        case .idle:
            guard case let .signedIn(login) = model.account else { return "Not signed in" }
            let who = login.isEmpty ? "" : "@\(login) · "
            if let last = model.lastSync {
                return "\(who)Up to date, checked \(last.formatted(.relative(presentation: .named)))"
            }
            return "\(who)Up to date"
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuButton("Open in Finder", symbol: "folder") { Task { await model.openInFinder() } }
            MenuButton("Check for Changes", symbol: "arrow.clockwise") { Task { await model.refresh() } }
            MenuButton("Free Up Space", symbol: "icloud.and.arrow.up") { Task { await model.freeUpSpace() } }
            if AppConfig.isOn(.recentlyDeleted) {
                MenuButton("Recently Deleted…", symbol: "trash") { Tools.showRecentlyDeleted(model: model) }
            }
            MenuButton(model.status == .paused ? "Resume Syncing" : "Pause Syncing",
                       symbol: model.status == .paused ? "play" : "pause") { Task { await model.togglePause() } }
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink { Text("Settings…") }
                .buttonStyle(.borderless)
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.callout)
    }
}

private struct FolderList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Folders").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.totalSizeKB.kilobytesFormatted) on GitHub").font(.caption).foregroundStyle(.secondary)
            }
            if let job = model.encrypting {
                ProgressView(value: Double(job.done), total: Double(max(job.total, 1))) {
                    Text("Encrypting \(job.name)").font(.caption)
                }
            }
            if model.folders.isEmpty {
                Text("No folders yet. Open GitDrive in Finder and make a folder at the top level. Each one becomes a private repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.folders) { folder in
                    let repo = folder.repo
                    HStack {
                        Image(systemName: folder.encrypted ? "lock.fill" : "folder.fill").foregroundStyle(.tint)
                            .frame(width: 18)
                            .help(folder.encrypted ? "Encrypted" : "Not encrypted")
                        Text(folder.name).lineLimit(1)
                        Spacer()
                        if repo.size > 1_000_000 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("GitHub recommends keeping repos under 1 GB")
                        }
                        Text(repo.size.kilobytesFormatted).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}

private struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to use your private GitHub repos as a drive in Finder.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if model.hasOAuthClientID {
                Button {
                    model.signInWithBrowser()
                } label: {
                    Label("Sign in with GitHub", systemImage: "person.badge.key").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Or use a personal access token").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                SecureField("Token with repo access", text: $token)
                    .textFieldStyle(.roundedBorder)
                Button("Sign In") { Task { await model.signIn(withToken: token); token = "" } }
                    .disabled(token.isEmpty)
            }
            Link("Create a token on GitHub", destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo,delete_repo&description=GitDrive")!)
                .font(.caption)
        }
    }
}

private struct ApprovalView: View {
    @Environment(AppModel.self) private var model
    let code: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter this code on GitHub. It's already copied.").font(.callout)
            Text(code)
                .font(.system(.title, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
            HStack {
                Button("Open GitHub") { NSWorkspace.shared.open(url) }
                Spacer()
                Button("Cancel") { model.cancelSignIn() }
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for approval").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MenuButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(title)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
