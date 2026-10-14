import GitDriveCore
import SwiftUI

/// Confirms and runs "Publish as Website". The warning is the point of this window.
struct PublishView: View {
    let model: AppModel
    let repo: String
    let path: String
    @State private var name: String
    @State private var working = false
    @State private var site: URL?
    @State private var message: String?

    init(model: AppModel, repo: String, path: String) {
        self.model = model
        self.repo = repo
        self.path = path
        let folder = path.isEmpty ? String(repo.dropFirst(Reserved.repoPrefix.count)) : (path as NSString).lastPathComponent
        _name = State(initialValue: folder.lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Publish as a website", systemImage: "globe").font(.headline)
            if let site {
                Text("It's live, or will be within a minute while GitHub Pages builds it.")
                Link(site.absoluteString, destination: site)
                HStack {
                    Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(site.absoluteString, forType: .string) }
                    Button("Open") { NSWorkspace.shared.open(site) }.buttonStyle(.borderedProminent)
                }
                Text("To update it, publish again. Your GitDrive folder stays private.").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Everything in this folder will be copied to a PUBLIC repo that anyone on the internet can see.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Repo name") { TextField("my-site", text: $name).textFieldStyle(.roundedBorder) }
                Text("The site will be at your-username.github.io/\(name.isEmpty ? "name" : name)").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Publish Publicly") { Task { await publish() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.isEmpty || working)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func publish() async {
        working = true
        do {
            let engine = try await model.readyEngine()
            try await engine.syncRepo(repo)
            site = try await engine.publish(repo: repo, path: path, as: name)
        } catch {
            message = (error as? GitHubError)?.message ?? String(describing: error)
        }
        working = false
    }
}
