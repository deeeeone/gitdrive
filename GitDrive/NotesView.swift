import GitDriveCore
import SwiftUI

/// Markdown files in chosen folders as a notes app: list, editor, [[links]] and backlinks.
/// Notes stay ordinary .md files in git.
struct NotesView: View {
    let model: AppModel
    @State private var notes: [Note] = []
    @State private var texts: [String: String] = [:]
    @State private var selection: Note.ID?
    @State private var draft = ""
    @State private var search = ""
    @State private var dirty = false
    @State private var message: String?

    struct Note: Identifiable, Hashable {
        let item: ItemRecord
        var id: String { item.id }
        var title: String { (item.filename as NSString).deletingPathExtension }
    }

    private var current: Note? { notes.first { $0.id == selection } }
    private var visible: [Note] {
        search.isEmpty ? notes : notes.filter { $0.title.localizedStandardContains(search) || (texts[$0.id] ?? "").localizedStandardContains(search) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search notes", text: $search).textFieldStyle(.roundedBorder)
                    Button { Task { await newNote(named: "Untitled") } } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless)
                        .help("New note")
                }
                .padding(8)
                List(visible, selection: $selection) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).lineLimit(1)
                        Text(preview(note)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)

            if let current {
                VStack(spacing: 0) {
                    HStack {
                        Text(current.title).font(.headline)
                        Spacer()
                        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        Button("Save") { Task { await save(current) } }
                            .keyboardShortcut("s")
                            .disabled(!dirty)
                    }
                    .padding(8)
                    Divider()
                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .padding(6)
                        .onChange(of: draft) { dirty = draft != (texts[current.id] ?? "") }
                }
                .frame(minWidth: 320)
                links(for: current).frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
            } else {
                ContentUnavailableView("No note selected", systemImage: "note.text",
                                       description: Text(notes.isEmpty ? "Choose notes folders in Settings → Extras → Notes." : ""))
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selection) { draft = selection.flatMap { texts[$0] } ?? "" ; dirty = false }
        .task { await load() }
    }

    private func links(for note: Note) -> some View {
        let outgoing = Self.wikiLinks(in: draft)
        let backlinks = notes.filter { $0.id != note.id && Self.wikiLinks(in: texts[$0.id] ?? "").contains { $0.caseInsensitiveCompare(note.title) == .orderedSame } }
        return List {
            Section("Links") {
                if outgoing.isEmpty { Text("Type [[Note name]] to link").font(.caption).foregroundStyle(.secondary) }
                ForEach(outgoing, id: \.self) { name in
                    Button(name) { Task { await follow(name) } }.buttonStyle(.link)
                }
            }
            Section("Backlinks") {
                if backlinks.isEmpty { Text("None yet").font(.caption).foregroundStyle(.secondary) }
                ForEach(backlinks) { other in
                    Button(other.title) { selection = other.id }.buttonStyle(.link)
                }
            }
        }
        .listStyle(.sidebar)
    }

    static func wikiLinks(in text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let open = rest.range(of: "[["), let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            let name = rest[open.upperBound..<close.lowerBound].split(separator: "|").first.map(String.init) ?? ""
            if !name.isEmpty, !out.contains(name) { out.append(name) }
            rest = rest[close.upperBound...]
        }
        return out
    }

    private func preview(_ note: Note) -> String {
        (texts[note.id] ?? "").split(separator: "\n").first { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
    }

    private func load() async {
        do {
            let engine = try await model.readyEngine()
            try await engine.syncAll()
            let chosen = AppConfig.notesRepos
            let items = try engine.store.allItems().filter {
                chosen.contains($0.repo) && !$0.isDirectory && ["md", "markdown"].contains(($0.filename as NSString).pathExtension.lowercased())
            }
            notes = items.map(Note.init).sorted { $0.item.modified > $1.item.modified }
            for note in notes {
                if let url = try? await engine.download(id: note.id).0 { texts[note.id] = try? String(contentsOf: url, encoding: .utf8) }
            }
            if selection == nil { selection = notes.first?.id }
            draft = selection.flatMap { texts[$0] } ?? ""
        } catch {
            message = String(describing: error)
        }
    }

    private func save(_ note: Note) async {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(draft.utf8).write(to: url)
            let saved = try await model.readyEngine().modify(id: note.id, newName: nil, newParentID: nil, contents: url)
            texts[saved.id] = draft
            dirty = false
            message = "Saved"
        } catch {
            message = String(describing: error)
        }
    }

    /// Opens a linked note, creating it next to the current one if it doesn't exist yet.
    private func follow(_ name: String) async {
        if let match = notes.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            selection = match.id
        } else {
            await newNote(named: name)
        }
    }

    private func newNote(named name: String) async {
        do {
            let engine = try await model.readyEngine()
            let parentID = current?.item.parentID ?? AppConfig.notesRepos.sorted().compactMap { try? engine.store.item(repo: $0, path: "")?.id }.first
            guard let parentID else { message = "Choose a notes folder in Settings first"; return }
            var title = name
            var n = 2
            while notes.contains(where: { $0.title == title }) { title = "\(name) \(n)"; n += 1 }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("# \(title)\n\n".utf8).write(to: url)
            let item = try await engine.createFile(parentID: parentID, name: "\(title).md", contents: url)
            let note = Note(item: item)
            notes.insert(note, at: 0)
            texts[note.id] = "# \(title)\n\n"
            selection = note.id
        } catch {
            message = String(describing: error)
        }
    }
}

extension AppConfig {
    /// Top-level folders shown in Notes.
    static var notesRepos: Set<String> {
        get { Set(sharedDefaults?.stringArray(forKey: "notesRepos") ?? []) }
        set { sharedDefaults?.set(Array(newValue).sorted(), forKey: "notesRepos") }
    }
}
