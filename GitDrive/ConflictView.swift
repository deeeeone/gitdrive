import GitDriveCore
import SwiftUI

/// Every conflict copy, with a side-by-side diff for text files and Keep Mine / Keep Theirs / Keep Both.
struct ConflictView: View {
    let model: AppModel
    var focus: String?
    @State private var conflicts: [Conflict] = []
    @State private var selection: Conflict?
    @State private var theirs: [String] = []
    @State private var mine: [String] = []
    @State private var isText = true
    @State private var message: String?

    var body: some View {
        NavigationSplitView {
            List(conflicts, selection: $selection) { conflict in
                VStack(alignment: .leading) {
                    Text(conflict.original?.filename ?? conflict.copy.filename)
                    Text(conflict.copy.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(conflict)
            }
            .overlay { if conflicts.isEmpty { ContentUnavailableView("No conflicts", systemImage: "checkmark.circle") } }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let selection {
                VStack(spacing: 10) {
                    if isText {
                        HStack(alignment: .top, spacing: 1) {
                            column("On GitHub (theirs)", theirs, changed: changed(theirs, against: mine), tint: .red)
                            column("This Mac (mine)", mine, changed: changed(mine, against: theirs), tint: .green)
                        }
                    } else {
                        ContentUnavailableView(
                            "Can't compare this file", systemImage: "doc",
                            description: Text("Open both from Finder to compare them, then choose which to keep.")
                        )
                    }
                    HStack {
                        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Keep Both") { Task { await resolve(selection, .both) } }
                        Button("Keep Theirs") { Task { await resolve(selection, .theirs) } }
                        Button("Keep Mine") { Task { await resolve(selection, .mine) } }.buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .task(id: selection) { await loadSides(selection) }
            } else {
                Text("Choose a conflict").foregroundStyle(.secondary)
            }
        }
        .task { await load() }
    }

    private func column(_ title: String, _ lines: [String], changed: Set<Int>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .background(changed.contains(index) ? tint.opacity(0.18) : .clear)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    /// Line numbers in `lines` that the other side doesn't have.
    private func changed(_ lines: [String], against other: [String]) -> Set<Int> {
        var out = Set<Int>()
        for change in lines.difference(from: other) {
            if case let .insert(offset, _, _) = change { out.insert(offset) }
        }
        return out
    }

    private func load() async {
        do {
            let engine = try await model.readyEngine()
            try await engine.syncAll()
            conflicts = try await engine.conflicts().sorted { $0.copy.path < $1.copy.path }
            selection = conflicts.first { $0.copy.path == focus } ?? conflicts.first
        } catch {
            message = String(describing: error)
        }
    }

    private func loadSides(_ conflict: Conflict) async {
        message = nil
        do {
            let engine = try await model.readyEngine()
            let copy = try await engine.download(id: conflict.copy.id).0
            let mineText = (try? String(contentsOf: copy, encoding: .utf8)).flatMap { conflict.copy.size < 2_000_000 ? $0 : nil }
            var theirsText = ""
            if let original = conflict.original {
                theirsText = (try? String(contentsOf: try await engine.download(id: original.id).0, encoding: .utf8)) ?? ""
            }
            isText = mineText != nil
            mine = (mineText ?? "").components(separatedBy: "\n")
            theirs = theirsText.components(separatedBy: "\n")
        } catch {
            message = String(describing: error)
        }
    }

    private func resolve(_ conflict: Conflict, _ choice: ConflictChoice) async {
        do {
            try await model.readyEngine().resolve(conflict, keeping: choice)
            conflicts.removeAll { $0 == conflict }
            selection = conflicts.first
            await model.refresh()
        } catch {
            message = String(describing: error)
        }
    }
}
