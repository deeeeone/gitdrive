import GitDriveCore
import SwiftUI

/// Shown when the ransomware tripwire fires.
struct TripwireView: View {
    let model: AppModel
    var close: () -> Void
    @State private var working = false
    @State private var message: String?

    var body: some View {
        let state = AppConfig.tripwire
        VStack(alignment: .leading, spacing: 12) {
            Label("GitDrive paused uploads", systemImage: "exclamationmark.octagon.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            Text("\(state?.count ?? 0) files turned into random-looking data within 10 minutes. That's what ransomware does when it encrypts files. GitDrive is keeping GitHub's copies and putting them back on this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            if let examples = state?.examples, !examples.isEmpty {
                Text("Recent files: " + examples.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Text("If you just encrypted or compressed files yourself, choose Resume. Otherwise disconnect from the internet, run a malware scan, then roll back.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.caption) }
            HStack {
                Button("Resume, This Was Me") {
                    AppConfig.tripwire = nil
                    model.accessChanged()
                    close()
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Roll Back the Last Hour") { Task { await rollBack(from: state?.trippedAt ?? Date()) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func rollBack(from date: Date) async {
        working = true
        do {
            let changed = try await model.readyEngine().rollBack(to: date.addingTimeInterval(-3600))
            AppConfig.tripwire = nil
            message = changed.isEmpty ? "Nothing on GitHub had changed." : "Rolled back \(changed.count) folder\(changed.count == 1 ? "" : "s"). Earlier versions stay in history."
            model.accessChanged()
        } catch {
            message = String(describing: error)
        }
        working = false
    }
}
