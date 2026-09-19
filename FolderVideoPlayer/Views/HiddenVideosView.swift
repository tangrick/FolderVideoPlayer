import SwiftUI

/// The password form for the hidden videos.
///
/// One sheet, three jobs — create, unlock, change — so the wording about what
/// the password does and does not protect can be written once and be true in
/// all three. `.create` also arrives when a hidden list exists but no password
/// does: a library carried over from a build that could hide without one.
///
/// The sheet knows nothing about what it was opened for beyond that. Success
/// calls `onSuccess` and the caller decides whether that means hiding the
/// selection, revealing the list, or recording a status line.
struct HiddenPasswordSheet: View {
    let kind: AppModel.HiddenSheetKind
    let onSuccess: () -> Void

    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirm = ""
    @State private var current = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(titleThatSaysWhatItMeans)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            fields

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The one thing a password prompt must never do is imply
            // protection it does not provide. Said plainly, every time.
            Text(honesty)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !canSubmit)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    // MARK: - the words

    private var titleThatSaysWhatItMeans: String {
        switch kind {
        case .create: return "Choose a password for hidden videos"
        case .unlock: return "Password"
        case .change: return "Change the password"
        }
    }

    private var actionTitle: String {
        switch kind {
        case .create: return "Set Password"
        case .unlock: return "Unlock"
        case .change: return "Change"
        }
    }

    private var honesty: String {
        switch kind {
        case .create:
            return "This keeps the videos out of this app's sight — nothing else. "
                 + "The files stay exactly where they are, and Finder or any other app can still open them. "
                 + "There is no way to recover a forgotten password; removing the hidden list is."
        case .unlock:
            return "Only this app's view of the videos is locked. The files themselves are untouched."
        case .change:
            return "The videos stay hidden; only the password changes."
        }
    }

    // MARK: - the fields

    @ViewBuilder
    private var fields: some View {
        if kind == .change {
            SecureField("Current password", text: $current)
            Divider().padding(.vertical, 2)
        }
        SecureField(kind == .unlock ? "Password" : "New password", text: $password)
        if kind != .unlock {
            SecureField("Again", text: $confirm)
        }
    }

    private var canSubmit: Bool {
        switch kind {
        case .create, .change:
            guard !password.isEmpty else { return false }
            return password == confirm && (kind == .create || !current.isEmpty)
        case .unlock:
            return !password.isEmpty
        }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                switch kind {
                case .create:
                    try await library.lock.setPassword(password)
                case .unlock:
                    guard await library.lock.unlock(password) else {
                        error = "That password does not match."
                        return
                    }
                case .change:
                    try await library.lock.changePassword(from: current, to: password)
                }
                onSuccess()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A reminder that the list on screen is the hidden one, with a way out.
///
/// The Hidden view is the only place these videos appear, so the banner exists
/// to make that state impossible to mistake for the ordinary library — and to
/// offer the one action that ends it.
struct HiddenBanner: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash.fill")
            Text("Hidden — unlocked for this session")
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Lock Now") { app.lockHidden() }
                .font(.caption)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .help("These videos are hidden from the rest of the app. Locking asks for the password again next time.")
    }
}
