import GitDriveCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            EncryptionTab().tabItem { Label("Encryption", systemImage: "lock") }
            ExtrasTab().tabItem { Label("Extras", systemImage: "sparkles") }
            FoldersTab().tabItem { Label("Folders", systemImage: "folder") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 520)
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
                if model.folders.isEmpty {
                    Text("No folders yet.").foregroundStyle(.secondary)
                }
                ForEach(model.folders) { folder in
                    let repo = folder.repo
                    HStack {
                        Image(systemName: folder.encrypted ? "lock.fill" : "folder").frame(width: 18)
                        VStack(alignment: .leading) {
                            Text(folder.name)
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

private struct EncryptionTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: AppModel.Folder?
    @State private var decrypting: AppModel.Folder?
    @State private var confirmingAll = false

    var body: some View {
        Form {
            if !model.encryptionAvailable {
                Section {
                    Text("Encrypted folders need macOS 26 or later.").foregroundStyle(.secondary)
                }
            } else if let keyID = model.encryptionKeyID {
                Section {
                    LabeledContent("Key fingerprint", value: keyID)
                    Toggle("Encrypt new top-level folders", isOn: Binding(
                        get: { model.encryptNewFolders },
                        set: { model.encryptNewFolders = $0 }
                    ))
                } header: {
                    Text("Your key")
                } footer: {
                    Text("The private key is in iCloud Keychain, so your other Macs on the same Apple Account can open encrypted folders. If iCloud Keychain is off, the key exists only on this Mac. Losing it means the encrypted files can't be recovered by anyone.")
                }
                Section {
                    let plain = model.folders.filter { !$0.encrypted }
                    if model.folders.isEmpty { Text("No folders yet.").foregroundStyle(.secondary) }
                    ForEach(model.folders) { folder in
                        HStack {
                            Image(systemName: folder.encrypted ? "lock.fill" : "lock.open").frame(width: 18)
                            Text(folder.name)
                            Spacer()
                            if folder.encrypted {
                                Button("Decrypt…") { decrypting = folder }.disabled(model.encrypting != nil)
                            } else {
                                Button("Encrypt…") { confirming = folder }.disabled(model.encrypting != nil)
                            }
                        }
                    }
                    if plain.count > 1 {
                        Button("Encrypt All Folders…") { confirmingAll = true }.disabled(model.encrypting != nil)
                    }
                    if let job = model.encrypting {
                        ProgressView(value: Double(job.done), total: Double(max(job.total, 1))) {
                            Text("Encrypting \(job.name): \(job.done) of \(job.total) files")
                        }
                    }
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Encrypting copies a folder into a new repo where names, folder layout, file sizes and contents are all hidden, then deletes the readable repo and its history from GitHub.")
                }
            } else {
                Section {
                    Text("Encrypt folders so GitHub only ever sees random data. Names, folders, file sizes and contents are all hidden.")
                    Button("Set Up Encryption") { model.setUpEncryption() }
                        .buttonStyle(.borderedProminent)
                } footer: {
                    Text("Creates a post-quantum key pair (ML-KEM-768 with X25519) and keeps the private key in iCloud Keychain. Each encrypted repo holds only the public key.")
                }
            }
        }
        .formStyle(.grouped)
        .alert(item: $confirming) { folder in
            Alert(
                title: Text("Encrypt \(folder.name)?"),
                message: Text("GitDrive copies it into a new encrypted repo, then permanently deletes the readable repo \(folder.repo.name) and its history. Copies downloaded on this Mac will download again."),
                primaryButton: .destructive(Text("Encrypt")) { Task { await model.encrypt(folder) } },
                secondaryButton: .cancel()
            )
        }
        .alert("Decrypt \(decrypting?.name ?? "")?", isPresented: Binding(
            get: { decrypting != nil }, set: { if !$0 { decrypting = nil } }
        )) {
            Button("Decrypt", role: .destructive) {
                if let folder = decrypting { Task { await model.decrypt(folder) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GitDrive copies it into a normal repo that GitHub can read, then permanently deletes the encrypted repo. File names, folders and contents will be visible to GitHub again.")
        }
        .alert("Encrypt all folders?", isPresented: $confirmingAll) {
            Button("Encrypt All", role: .destructive) { Task { await model.encryptAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each readable repo is copied into a new encrypted repo and then permanently deleted with its history.")
        }
    }
}

/// One switch per optional feature, grouped. Features add their own settings below their switch.
private struct ExtrasTab: View {
    @Environment(AppModel.self) private var model
    @State private var refresh = 0

    var body: some View {
        Form {
            ForEach(Extra.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(Extra.allCases.filter { $0.group == group }) { extra in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: Binding(
                                get: { _ = refresh; return AppConfig.isOn(extra) },
                                set: { AppConfig.set(extra, on: $0); refresh += 1; model.extraChanged(extra) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(extra.title)
                                    Text(extra.summary).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if AppConfig.isOn(extra) { ExtraOptions(extra: extra) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Extra settings shown under a feature's switch when it's on.
private struct ExtraOptions: View {
    @Environment(AppModel.self) private var model
    let extra: Extra

    var body: some View {
        switch extra {
        case .touchID, .passcode:
            Picker("Stay unlocked for", selection: Binding(
                get: { AppConfig.unlockHours }, set: { AppConfig.unlockHours = $0 }
            )) {
                Text("1 hour").tag(1)
                Text("8 hours").tag(8)
                Text("24 hours").tag(24)
            }
            .font(.callout)
            if extra == .passcode { PasscodeOptions() }
        case .codespaces:
            Text("Opens the folder's repo in a new codespace. Free accounts include 120 core hours a month. For quick edits without a codespace, press . on the repo's GitHub page to open github.dev.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .cloudRun:
            Text("Needs a token with the workflow scope. Private repos get 2,000 free Actions minutes a month.")
                .font(.caption).foregroundStyle(.secondary)
        case .bitRot:
            Button("Open Bit-rot Check…") { Tools.showBitRot(model: model) }
        case .duplicates:
            Button("Find Duplicates…") { Tools.showDuplicates(model: model) }
        case .recentlyDeleted:
            Button("Open Recently Deleted…") { Tools.showRecentlyDeleted(model: model) }
        case .backup:
            BackupOptions(backups: model.backups)
        case .notes:
            FolderPicker(title: "Notes folders", selection: Binding(get: { AppConfig.notesRepos }, set: { AppConfig.notesRepos = $0 }))
        case .photos:
            FolderPicker(title: "Photo folders", selection: Binding(get: { AppConfig.photoRepos }, set: { AppConfig.photoRepos = $0 }))
        default:
            EmptyView()
        }
    }
}

/// Folders being backed up, with Back Up Now.
private struct BackupOptions: View {
    @Bindable var backups: Backups

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(backups.sources) { source in
                HStack {
                    VStack(alignment: .leading) {
                        Text(source.name)
                        Text(source.lastRun.map { "Last backup \($0.formatted(.relative(presentation: .named))). " } .map { $0 + (source.lastResult ?? "") } ?? (source.lastResult ?? "Not backed up yet"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if backups.running == source.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Back Up Now") { Task { await backups.run(source.id) } }.disabled(backups.running != nil)
                    }
                    Button { backups.remove(source.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button("Add Folder…") { backups.add() }
            Text("Each folder backs up once a day while GitDrive is running, into a top-level folder named \"Backup of …\". It's encrypted if you've set up encryption.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Choose some top-level folders, for features that work on chosen folders.
struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    let title: String
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(model.folders) { folder in
                Toggle(folder.name, isOn: Binding(
                    get: { selection.contains(folder.repo.name) },
                    set: { on in if on { selection.insert(folder.repo.name) } else { selection.remove(folder.repo.name) } }
                ))
                .font(.callout)
            }
        }
    }
}

/// Set the passcode and duress passcode, and choose decoy folders. Only shown after a full unlock,
/// so someone who used the duress passcode can't see that decoys exist.
private struct PasscodeOptions: View {
    @Environment(AppModel.self) private var model
    @State private var passcode = ""
    @State private var duress = ""
    @State private var saved = false
    @State private var decoys = AppConfig.decoyRepos

    var body: some View {
        if AppConfig.passcodeIsSet, model.access != .full {
            Text("Unlock with your passcode to change these settings.").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SecureField(AppConfig.passcodeIsSet ? "New passcode" : "Passcode", text: $passcode)
                SecureField("Duress passcode (optional)", text: $duress)
                HStack {
                    Button(AppConfig.passcodeIsSet ? "Change Passcode" : "Set Passcode") {
                        try? PasscodeStore().set(passcode: passcode, duress: duress)
                        passcode = ""
                        duress = ""
                        saved = true
                        AppConfig.unlock(decoy: false)
                        model.accessChanged()
                    }
                    .disabled(passcode.count < 4)
                    if AppConfig.passcodeIsSet {
                        Button("Remove Passcode", role: .destructive) {
                            PasscodeStore().clear()
                            model.accessChanged()
                        }
                    }
                    if saved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                }
                Text("At least 4 characters. The duress passcode opens only the decoy folders below; every other encrypted folder disappears from Finder until you unlock with the real passcode.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let encrypted = model.folders.filter(\.encrypted)
                if AppConfig.passcodeIsSet, PasscodeStore().hasDuress, !encrypted.isEmpty {
                    Text("Decoy folders").font(.caption.weight(.semibold))
                    ForEach(encrypted) { folder in
                        Toggle(folder.name, isOn: Binding(
                            get: { decoys.contains(folder.repo.name) },
                            set: { on in
                                if on { decoys.insert(folder.repo.name) } else { decoys.remove(folder.repo.name) }
                                AppConfig.decoyRepos = decoys
                            }
                        ))
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
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
