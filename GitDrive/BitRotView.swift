import GitDriveCore
import SwiftUI

/// Results of the bit-rot check, with Check Now and Download Again.
struct BitRotView: View {
    let model: AppModel
    @State private var report: BitRotReport?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Bit-rot check").font(.headline)
                    if let last = UserDefaults.standard.object(forKey: "lastBitRotCheck") as? Date {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button("Check Now") { Task { await run() } }.disabled(running)
            }
            if let report {
                if report.damaged.isEmpty {
                    Label("All \(report.checked) downloaded files match GitHub.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("\(report.damaged.count) of \(report.checked) files no longer match GitHub.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    List(report.damaged, id: \.self) { url in
                        HStack {
                            Text(url.lastPathComponent)
                            Spacer()
                            Button("Download Again") { try? FileManager.default.evictUbiquitousItem(at: url) }
                        }
                    }
                }
                Text("\(report.skipped) files aren't downloaded, so there was nothing on this Mac to check. GitHub verifies its own copies.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !running {
                Text("Checks that files downloaded to this Mac still match their hashes in git.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private func run() async {
        running = true
        report = await model.checkForBitRot()
        running = false
    }
}
