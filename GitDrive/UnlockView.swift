import GitDriveCore
import SwiftUI

/// Asks for the GitDrive passcode. The duress passcode opens only decoy folders and looks the same.
struct UnlockView: View {
    let model: AppModel
    var close: () -> Void
    @State private var passcode = ""
    @State private var wrong = 0
    @State private var waitUntil: Date?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.tint)
            Text("Unlock encrypted folders").font(.headline)
            SecureField("Passcode", text: $passcode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(attempt)
            if wrong > 0 { Text("Wrong passcode").font(.caption).foregroundStyle(.red) }
            HStack {
                if AppConfig.isOn(.touchID) {
                    Button("Use Touch ID") { Task { await model.unlockWithTouchID(); close() } }
                }
                Button("Unlock", action: attempt)
                    .buttonStyle(.borderedProminent)
                    .disabled(passcode.isEmpty || (waitUntil.map { $0 > Date() } ?? false))
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    private func attempt() {
        if let waitUntil, waitUntil > Date() { return }
        guard let access = PasscodeStore().check(passcode) else {
            wrong += 1
            passcode = ""
            // After five wrong tries, wait longer each time.
            if wrong >= 5 { waitUntil = Date().addingTimeInterval(pow(2, Double(wrong - 4))) }
            return
        }
        AppConfig.unlock(decoy: access == .decoy)
        model.accessChanged()
        close()
    }
}
