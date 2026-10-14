import GitDriveCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            FoldersTab().tabItem { Label("Folders", systemImage: "folder") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open GitDrive at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
            Section {
                Picker("Deleting a top-level folder", selection: Binding(
                    get: { model.repoDeletion },
                    set: { model.repoDeletion = $0 }
                )) {
                    Text("Deletes its GitHub repo").tag(RepoDeletion.delete)
                    Text("Archives its GitHub repo").tag(RepoDeletion.archive)
                }
                if model.repoDeletion == .delete, model.canDeleteRepos == false {
                    Label("Your token can't delete repos. Sign out and sign in with a token that has the delete_repo scope, or choose Archive.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Top-level folders")
            } footer: {
                Text(model.repoDeletion == .delete
                    ? "Deleting a repo is permanent, including its history. Finder asks before deleting."
                    : "Archived repos disappear from the drive but stay on GitHub, read-only. Unarchive one on GitHub to bring it back.")
            }
            Section {
                Toggle("Store large files with Git LFS", isOn: Binding(
                    get: { model.lfsEnabled },
                    set: { model.lfsEnabled = $0 }
                ))
                if model.lfsEnabled {
                    Stepper(value: Binding(get: { model.lfsThresholdMB }, set: { model.lfsThresholdMB = $0 }), in: 1...99, step: 5) {
                        LabeledContent("Files larger than", value: "\(model.lfsThresholdMB) MB")
                    }
                }
            } header: {
                Text("Large files")
            } footer: {
                Text(model.lfsEnabled
                    ? "Up to 2 GB per file. GitHub Free includes 10 GiB of LFS storage and 10 GiB of downloads a month, and every file you open counts as a download. Encrypted folders don't need LFS."
                    : "Without LFS, files over 100 MB can't be stored.")
            }
            Section("Account") {
                if case let .signedIn(login) = model.account {
                    LabeledContent("Signed in as", value: login.isEmpty ? "Offline" : "@\(login)")
                    Button("Sign Out and Remove Drive from This Mac", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    Text("Signing out removes the downloaded copies from this Mac. Your files stay on GitHub.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not signed in. Use the menu bar icon to sign in.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FoldersTab: View {
    @Environment(AppModel.self) private var model
    @State private var compacting: Repo?
    @State private var adding: Repo?

    var body: some View {
        Form {
            Section {
                if model.repos.isEmpty {
                    Text("No folders yet.").foregroundStyle(.secondary)
                }
                ForEach(model.repos, id: \.name) { repo in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(repo.displayName)
                            Text("\(repo.owner.login)/\(repo.name) · \(repo.size.kilobytesFormatted)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Compact History…") { compacting = repo }
                    }
                }
            } header: {
                Text("Drive folders")
            } footer: {
                Text("Git keeps every old version, so deleted files still use space on GitHub. Compacting keeps only the current files.")
            }

            Section {
                if model.otherRepos.isEmpty {
                    Text("No other repos.").foregroundStyle(.secondary)
                }
                ForEach(model.otherRepos, id: \.name) { repo in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(repo.name)
                            Text(repo.size.kilobytesFormatted).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add to Drive…") { adding = repo }
                    }
                }
            } header: {
                Text("Your other repos")
            } footer: {
                Text("Adding a repo renames it to drive-<name> so it shows up as a folder. GitHub redirects the old URL.")
            }
        }
        .formStyle(.grouped)
        .alert(item: $compacting) { repo in
            Alert(
                title: Text("Compact history of \(repo.displayName)?"),
                message: Text("This replaces the repo's history with a single commit holding the current files. Old versions and deleted files can't be recovered afterwards."),
                primaryButton: .destructive(Text("Compact")) { Task { await model.compactHistory(repo) } },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $adding) { repo in
            Alert(
                title: Text("Add \(repo.name) to GitDrive?"),
                message: Text("The repo will be renamed to \(Reserved.repoPrefix)\(repo.name) on GitHub. Clones of it keep working through GitHub's redirect, but you may want to update their remote URL."),
                primaryButton: .default(Text("Add")) { Task { await model.addToDrive(repo) } },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("GitDrive").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
            Text("Your private GitHub repos as a drive in Finder.")
            Link("github.com/deeeeone/gitdrive", destination: URL(string: "https://github.com/deeeeone/gitdrive")!)
            Text("MIT License").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Repo: @retroactive Identifiable {
    public var id: String { name }
}
