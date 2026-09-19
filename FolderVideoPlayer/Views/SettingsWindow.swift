import AppKit
import SwiftUI

/// The Settings window — ⌘, — the things a person is entitled to be able to
/// change without being told where.
///
/// Five tabs, macOS's own layout: General, Appearance, AI & Privacy, Library,
/// Advanced. Every control here writes to something that already existed
/// (`library`, `Paths`, the engine) — this window introduces no second way to
/// store a preference.
///
/// Rules carried from the rest of the app: a control that cannot do anything
/// right now is DISABLED WITH A REASON rather than hidden, every switch says
/// what turning it off means, and nothing here scans, analyses or trains.
///
/// Which tab is showing lives in `AppModel`, because SwiftUI's `Settings` scene
/// gives no way to open a named tab: a control that means "take me to the AI
/// page" sets `app.settingsTab` and then calls `openSettings()`. Before that,
/// "Set Up AI Features…" opened Settings on **General** — the same window with
/// nothing about AI on it — which is what a user reported as "there is set up ai
/// feature... i check and nothing i can do to get the feature" (2026-09-12).
enum SettingsTab: Hashable {
    case general, appearance, ai, privacy, library, advanced
}

struct SettingsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var engine: AnalysisEngine
    @Environment(\.openWindow) private var openWindow

    /// Said in THIS window, not over the player. `app.say` puts an alert on
    /// the player window, which is the wrong place for "backup written".
    @State private var status: String?

    /// Which engine command is being tried, so the row can say so.
    @State private var checking = false

    var body: some View {
        TabView(selection: $app.settingsTab) {
            GeneralSettings(library: library)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AppearanceSettings(library: library)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
            AISettings(library: library, app: app, downloads: app.downloads)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
            PrivacySettings(library: library, status: $status)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(SettingsTab.privacy)
            LibrarySettings(library: library, status: $status, openProfiles: {
                openWindow(id: "profiles")
            })
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(SettingsTab.library)
            AdvancedSettings(engine: engine, checking: $checking)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)
        }
        // Minimum, not fixed: at 580x470 the window was exactly its content,
        // so it could not be dragged larger either.
        .frame(minWidth: 580, minHeight: 470)
    }
}

// MARK: - the pieces every tab is built from

/// A settings row, macOS's own shape: what it is on the left (name over one
/// line of explanation), the control itself on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .controlSize(.regular)
                .fixedSize()
        }
        .padding(.vertical, 7)
    }
}

/// One tab's worth of rows, with macOS's roomy padding, in a scroll view.
///
/// This said "no scrolling — the window is sized so nothing here is off the
/// bottom", and that held until the AI pane grew a fourth capability. A
/// Settings window cannot grow past its content, so the last rows were simply
/// unreachable: no scroll bar, no resize, nothing to drag. Scrolling is the
/// honest fix — the window keeps its size and the pane keeps its rows.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                content()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A line that appears only when there is something to report.
private struct StatusLine: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var library: Library

    var body: some View {
        SettingsPage {
            SettingRow(title: "Skip step",
                       detail: "How far the ← and → keys jump") {
                Picker("", selection: $library.skipSeconds) {
                    ForEach(Library.skipChoices, id: \.self) { seconds in
                        Text("\(seconds)s").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
            SettingRow(title: "Default speed",
                       detail: "What a video starts at; the transport bar can change it while playing") {
                Picker("", selection: $library.speed) {
                    ForEach(Tuning.speeds, id: \.self) { speed in
                        Text(speed == 1 ? "Normal" : "\(speed.formatted())×").tag(speed)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            SettingRow(title: "Play a folder in",
                       detail: "Folder order keeps the order the files came in") {
                Picker("", selection: $library.order) {
                    ForEach(PlayOrder.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            SettingRow(title: "Resume where I left off",
                       detail: "Skips the first 30 seconds and the last 30 — at either end, starting over is the right thing") {
                Toggle("", isOn: $library.resumeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingRow(title: "Ask which profile at startup",
                       detail: "Only matters on a Mac holding more than one profile. You can always switch in Tag Profiles.") {
                Toggle("", isOn: $library.askProfileAtStartup)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @ObservedObject var library: Library

    var body: some View {
        SettingsPage {
            SettingRow(title: "Default view",
                       detail: "⌘1 and ⌘2 switch it while you work; this is what a new session opens with") {
                Picker("", selection: $library.playlistStyle) {
                    Text("List").tag(PlaylistStyle.list)
                    Text("Poster frames").tag(PlaylistStyle.icons)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            SettingRow(title: "Poster frames in the list",
                       detail: "A thumbnail on every row. Turning this off makes rows shorter and a big list faster to scan.") {
                Toggle("", isOn: $library.showThumbnails)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingRow(title: "Panel widths",
                       detail: "Library \(Int(library.librarySidebarWidth ?? 250)) pt · Playlist \(Int(library.playlistWidth)) pt — drag either edge to change them") {
                Button("Reset") {
                    library.librarySidebarWidth = nil
                    library.playlistWidth = 320
                    library.save()
                }
            }
        }
    }
}

// MARK: - AI & Privacy

private struct PrivacySettings: View {
    @ObservedObject var library: Library
    @Binding var status: String?

    /// Settings runs its own copy of the password sheet: a `Settings` scene is
    /// its own window, and sharing one sheet binding with the player would put
    /// the same form on screen twice whenever both windows are open.
    @EnvironmentObject private var app: AppModel
    @State private var hiddenSheet: AppModel.HiddenSheetKind?

    private var hiddenDetail: String {
        let count = library.hidden.count
        let what = count == 0
            ? "Nothing is hidden."
            : "\(count) video\(count == 1 ? " is" : "s are") hidden from the app."
        return what + " This keeps videos out of the app's sight only — the files stay "
             + "where they are, and Finder can still open them."
    }

    var body: some View {
        SettingsPage {
            Text("Everything the app works out — tags, faces, duplicates — is computed on this Mac. Nothing is uploaded, and no model leaves the computer it was downloaded to.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)

            SettingRow(title: "Face Recognition",
                       detail: "Find faces, and offer the people you have named. Off means no face is detected, embedded or stored anywhere in the app — and your named people stay, as ordinary tags.") {
                Toggle("", isOn: $library.facesEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingRow(title: "Work on the video while it plays",
                       detail: "Classifies it and offers tag ideas once, a few seconds of model time per video. Off means nothing starts on its own — right-click Classify and the tag panel still work.") {
                Toggle("", isOn: $library.autoWorkWhilePlaying)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text("A video that has been worked on keeps its verdict and its chips. Playing one starts a Safe/NSFW classification and a few tag ideas, which appear in the tag panel with the moments they were seen at. Right-click videos in the playlist to classify a batch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingRow(title: "Fingerprint while playing",
                       detail: "Remembers a file's identity so a copy that moved can be found again. Costs a disk read per video played.") {
                Toggle("", isOn: $library.watchDupes)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingRow(title: "Read duplicates end to end",
                       detail: "In the duplicate finder: compares the survivors in full instead of two samples, so a match is certain — and slower to get.") {
                Toggle("", isOn: $library.verifyDupes)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingRow(title: "Hidden videos",
                       detail: hiddenDetail) {
                HStack(spacing: 8) {
                    if library.hidden.isEmpty {
                        Button("Set Password…") { hiddenSheet = .create }
                            .disabled(library.lock.hasPassword)
                    } else {
                        Button("Show…") { app.showHiddenVideos() }
                            .disabled(library.lock.isUnlocked)
                        if library.lock.hasPassword {
                            Button("Change Password…") { hiddenSheet = .change }
                            Button("Remove") { removeHiddenPassword() }
                        } else {
                            Button("Set Password…") { hiddenSheet = .create }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Open Tags Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Paths.support))
                }
                Button("Open Models Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: AnalysisEngine.modelsDir))
                }
            }
            .padding(.top, 8)
            StatusLine(text: status)
        }
        .sheet(item: $hiddenSheet) { kind in
            HiddenPasswordSheet(kind: kind) { hiddenSheetDone(kind) }
                .environmentObject(library)
                .environmentObject(app)
        }
    }

    /// What the sheet was opened for, once it has succeeded.
    private func hiddenSheetDone(_ kind: AppModel.HiddenSheetKind) {
        switch kind {
        case .create, .change:
            status = "Password set. The \(library.hidden.count) hidden "
                   + "video\(library.hidden.count == 1 ? "" : "s") stay hidden until it is given."
        case .unlock:
            break
        }
    }

    /// Forget the password. The hidden list is deliberately untouched: the
    /// videos stay hidden and can be brought back one at a time, which is the
    /// honest outcome for app-only hiding — anyone who can click this can also
    /// open the file in Finder.
    private func removeHiddenPassword() {
        let alert = NSAlert()
        alert.messageText = "Remove the hidden-videos password?"
        alert.informativeText = """
        The \(library.hidden.count) hidden video\(library.hidden.count == 1 ? "" : "s") stay hidden \
        and can be brought back from the menu. Nothing on disk is touched.

        Anyone using this Mac can then reveal the list without a password.
        """
        alert.addButton(withTitle: "Remove Password")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.lock.removePassword()
        status = "Password removed. The hidden list is unchanged."
    }
}

// MARK: - Library

private struct LibrarySettings: View {
    @ObservedObject var library: Library
    @Binding var status: String?
    let openProfiles: () -> Void

    var body: some View {
        SettingsPage {
            SettingRow(title: "This profile",
                       detail: "Whose tags are in force. Other profiles keep their own and are not merged with yours.") {
                HStack(spacing: 8) {
                    Text(library.person).fontWeight(.medium)
                    Button("Profiles…", action: openProfiles)
                }
            }
            SettingRow(title: "Recent folders to keep",
                       detail: "Pinned folders are not counted — they stay until you unpin them") {
                HStack(spacing: 8) {
                    Stepper(value: $library.recentLimit, in: 3...20) {
                        Text("\(library.recentLimit)")
                            .monospacedDigit()
                            .frame(width: 22, alignment: .trailing)
                    }
                    .fixedSize()
                }
            }
            SettingRow(title: "Recent list",
                       detail: library.recent.isEmpty
                           ? "Nothing yet — open a folder and it will appear here"
                           : "\(library.recent.count) folder\(library.recent.count == 1 ? "" : "s") remembered") {
                Button("Forget Recent") {
                    library.recent = []
                    library.save()
                    status = "Recent folders cleared."
                }
                .disabled(library.recent.isEmpty)
            }
            SettingRow(title: "Tags",
                       detail: "\(library.knownTags().count) tags across \(library.tags.count) videos") {
                // A one-file copy stopped being a backup the moment a profile
                // became a bundle — the readings, people and heads would all
                // be left behind. Export Profile… (File menu) copies the whole
                // document; this row keeps a plain tags file for hand-off.
                Button("Save a Copy…") { saveTagsCopy() }
                    .disabled(library.knownTags().isEmpty)
            }
            StatusLine(text: status)
            Spacer(minLength: 0)
        }
    }

    /// Copy tags.json out to wherever the user says. Tags are the one thing
    /// here that took real work to make and cannot be regenerated by the app.
    private func saveTagsCopy() {
        let panel = NSSavePanel()
        panel.title = "Save a copy of your tags"
        panel.nameFieldStringValue = "tags-backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: Paths.tagsFile))
            try data.write(to: url)
            status = "Saved \(library.knownTags().count) tags to \(url.lastPathComponent)."
        } catch {
            status = "Could not write that file: \(error.localizedDescription)"
        }
    }
}

// MARK: - AI

/// What the AI half of the app needs, what is missing, and how to get it.
///
/// This is the screen a stranger sees after installing: the app works without
/// any of it, each feature says what it would add and what it costs to
/// download, and nothing is fetched until they press a button.
private struct AISettings: View {
    @ObservedObject var library: Library
    @ObservedObject var app: AppModel
    @ObservedObject var downloads: ModelDownloader
    @State private var footprint: Int64 = 0
    @State private var note: String?

    var body: some View {
        SettingsPage {
            Text(app.ai.anythingWorks
                 ? "These run entirely on this Mac. Nothing is uploaded and no account is needed."
                 : "The player, tags, stars and the duplicate finder all work without these. "
                   + "Add only what you want.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            ForEach(AICapability.Feature.allCases) { feature in
                featureRow(feature)
                Divider()
            }

            catalogueLine

            if let ledger = app.jobs {
                AnalysisJobHistory(ledger: ledger, app: app)
            }

            HStack {
                Text(footprint > 0
                     ? "Models are using \(humanSize(footprint))."
                     : "No models downloaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") {
                    app.refreshAICapability()
                    Task { footprint = await measure() }
                    note = nil
                }
            }
            .padding(.top, 8)

            // Which engine is actually running. `coreml` is what a downloaded
            // DMG runs; `python` means a dev override is in force, and that is
            // worth seeing here rather than deducing from behaviour.
            HStack(spacing: 4) {
                Text("Engine:")
                Text(CoreMLClassifier.mode.rawValue).monospaced()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            StatusLine(text: note)
        }
        .task {
            footprint = await measure()
            await downloads.refreshCatalogue()
        }
        // An install or a removal changes what the machine can do, so the
        // probe is re-run on the spot — the point of the whole phase is that a
        // feature lights up without a relaunch.
        .onChange(of: downloads.revision) {
            app.refreshAICapability()
            Task { footprint = await measure() }
        }
    }

    /// Where the download list came from, and what to do when it did not come.
    ///
    /// This is the pitfall-0 rule applied to a whole tab: a catalogue that could
    /// not be fetched must say so, or the rows look like features that simply
    /// have no Install button — which reads as a broken app rather than as an
    /// offline one.
    @ViewBuilder
    private var catalogueLine: some View {
        if case .unavailable(let why) = downloads.state {
            HStack(alignment: .top, spacing: 8) {
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Try Again") { Task { await downloads.refreshCatalogue() } }
            }
            .padding(.top, 4)
        } else if downloads.manifest == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking what can be downloaded…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func featureRow(_ feature: AICapability.Feature) -> some View {
        let working = app.ai.works(feature)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.symbol)
                .font(.system(size: 15))
                .foregroundStyle(working ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(feature.title).fontWeight(.medium)
                    if working {
                        Text("Ready")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: .rect(cornerRadius: 4))
                    }
                }
                Text(feature.what)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Every blocker is named. A feature that cannot run must say
                // which thing is missing, not merely that it is unavailable.
                ForEach(app.ai.blockers[feature] ?? [], id: \.reason) { blocker in
                    Text("• " + blocker.reason)
                        .font(.caption)
                        .foregroundStyle(blocker.fixableInApp ? .secondary : .tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The model files this feature is actually running on.
                //
                // Read from the support directory rather than a constant, so
                // the line cannot outlive the model it names — the vision
                // tower has been swapped once already (MobileCLIP S2 →
                // SigLIP 2) and a hardcoded label would have gone on claiming
                // the old one. Selectable, because the point is to be able to
                // copy it into a bug report.
                let models = feature.installedModelNames()
                if !models.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Model:")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(models.joined(separator: ", "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Which pack this feature is SET TO USE, and which of the
                // catalogue's packs it could use instead.
                //
                // The "Using:" line is read from the choice record rather than
                // from the catalogue, so it still names the pack after the
                // catalogue has moved on and stopped offering it.
                //
                // The pop-up is shown whenever the catalogue offers anything for
                // this feature, even a single pack: it names the pack, its
                // revision and its licence in one place, which is what the line
                // it replaced did — and the moment a second pack is published it
                // is already the control that chooses between them. Showing it
                // only when there were two meant a user who was told a picker
                // exists could not see one.
                let offered = downloads.bundles(for: feature)
                if let chosen = downloads.chosenPack(for: feature) {
                    Text("Using: " + chosen.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !offered.isEmpty {
                    packPicker(feature, offered: offered)
                }
                // Which versions of this feature's pack are kept on this Mac,
                // ready to switch back to without a download.
                //
                // This is the half of a model choice that an install used to
                // destroy: installing revision 2 overwrote revision 1, so
                // "try the new one" was a one-way door. Selecting a copy here
                // re-installs it from the store — the same transaction, no
                // network — and the bin beside it reclaims that copy's disk
                // without touching the version in use.
                let kept = downloads.keptVersions(for: feature)
                if !kept.isEmpty {
                    keptRow(kept)
                }
                if let why = downloads.note(for: feature) {
                    Text("• " + why)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            installControl(feature)
        }
        .padding(.vertical, 7)
    }

    /// Pick which of the catalogue's packs a capability uses.
    ///
    /// Names the pack, its revision and its licence — the questions a user asks
    /// of a model — and lets them change it the moment the catalogue offers more
    /// than one. An incompatible pack stays IN the list with its reason attached:
    /// hiding a pack the user was told about would leave them wondering where it
    /// went, and choosing it is refused out loud by `choose`.
    private func packPicker(_ feature: AICapability.Feature, offered: [AIBundle]) -> some View {
        let current = downloads.bundle(for: feature)?.id ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Pack:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Picker("", selection: Binding(
                get: { current },
                set: { id in
                    guard let bundle = offered.first(where: { $0.id == id }) else { return }
                    downloads.choose(bundle)
                }
            )) {
                ForEach(offered) { bundle in
                    Text(packLabel(bundle)).tag(bundle.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.caption2)
            .fixedSize()
        }
    }

    /// Which kept versions of a feature's pack are on this Mac.
    ///
    /// Selecting one puts it back in force — reinstalled from the store, with no
    /// network and no compiler — and the bin discards the copy that is selected.
    /// The version in use is marked, because "which of these am I running" is
    /// the question this row exists to answer.
    private func keptRow(_ kept: [StoredVersion]) -> some View {
        let shown = kept.first { downloads.isLive($0) } ?? kept[0]
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Kept:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Picker("", selection: Binding(
                get: { shown.token },
                set: { token in
                    // Selecting the one already in use is not a switch: it would
                    // reinstall identical bytes and rewrite the receipt for it.
                    guard let version = kept.first(where: { $0.token == token }),
                          !downloads.isLive(version) else { return }
                    Task { await downloads.activate(version) }
                }
            )) {
                ForEach(kept, id: \.token) { version in
                    Text(keptLabel(version, live: downloads.isLive(version))).tag(version.token)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.caption2)
            .fixedSize()
            Button {
                Task { await downloads.discard(shown) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .help(downloads.isLive(shown)
                  ? "Forget this copy — the version in use stays installed"
                  : "Forget this copy")
        }
    }

    /// "Safe / NSFW · revision r1 · 164 MB · in use".
    private func keptLabel(_ version: StoredVersion, live: Bool) -> String {
        version.summary + " · " + humanSize(version.bytes) + (live ? " · in use" : "")
    }

    /// One line per pack in the picker: what it is, whether it is installed, and
    /// why it cannot run here when it cannot.
    private func packLabel(_ bundle: AIBundle) -> String {
        var label: String
        if let pack = bundle.pack {
            let revision = pack.revision.isEmpty ? "" : " · revision \(String(pack.revision.prefix(12)))"
            label = pack.modelID + revision + " · " + pack.license
        } else {
            // A legacy bundle with no descriptor: the catalogue's title, and no
            // invented revision or licence.
            label = bundle.title
        }
        if downloads.isInstalled(bundle) { label += " (installed)" }
        if let why = bundle.incompatibility { label += " — \(why)" }
        return label
    }

    /// Install, progress or Remove — whichever is true right now.
    ///
    /// Nothing is hidden: a feature the catalogue has no bundle for says "Not
    /// available yet" instead of showing an Install button that would fetch
    /// nothing, and a bundle that is installed offers Remove rather than a
    /// second Install it would ignore. All three features have bundles as of
    /// Phase 6.5 — faces included — so that branch is now the answer for a
    /// catalogue that is older than this build, not for faces.
    @ViewBuilder
    private func installControl(_ feature: AICapability.Feature) -> some View {
        let bundle = downloads.bundle(for: feature)
        switch downloads.state {
        case .downloading(let id, let progress) where id == bundle?.id:
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: progress.fraction)
                    .frame(width: 130)
                Text("\(humanSize(progress.received)) of \(humanSize(progress.total))")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        case .installing(let id) where id == bundle?.id:
            // Only removal sets this state — an install reports through
            // .downloading until it lands, and a switch has its own state below
            // — so the label says what is actually happening.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Removing…").font(.caption)
            }
        case .switching(let id) where id == bundle?.id:
            // No download: a kept copy is being put back. Saying "Removing…"
            // here was the previous behaviour and it was a lie — and one the
            // user could act on wrongly, by quitting mid-switch.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Switching…").font(.caption)
            }
        default:
            if let bundle, downloads.isInstalled(bundle) {
                Button("Remove") { Task { await downloads.remove(bundle) } }
            } else if let bundle, bundle.incompatibility != nil {
                Text("Not compatible")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let bundle {
                Button("Install (\(humanSize(bundle.bytes)))") {
                    Task { await downloads.install(bundle) }
                }
            } else if !app.ai.works(feature) {
                // "Not available yet" means "this catalogue has no bundle for
                // the feature", and it is a lie when the real reason is that no
                // download list arrived at all. The row above says which, so
                // this one has to agree with it: with a 404 catalogue, every row
                // read "Not available yet" and the user had nothing to press and
                // no statement of why.
                Text(catalogueUnavailable ? "Needs the download list"
                                          : "Not available yet")
                    .font(.caption).foregroundStyle(.tertiary)
                    .help(catalogueUnavailable
                          ? "The list of downloads could not be read — see the line above."
                          : "This feature has no download yet.")
            }
        }
    }

    /// Is the catalogue missing (a fetch that failed) as opposed to pending?
    /// Both leave every row without a bundle; only one of them is worth a
    /// sentence, and the tab already prints it above the rows.
    private var catalogueUnavailable: Bool {
        if case .unavailable = downloads.state { return true }
        return false
    }

    private func measure() async -> Int64 {
        await Task.detached(priority: .utility) { AICapability.modelsFootprint() }.value
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @ObservedObject var engine: AnalysisEngine
    @Binding var checking: Bool
    @State private var result: String?

    var body: some View {
        SettingsPage {
            Text("The engine")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            SettingRow(title: engine.phase.title,
                       detail: engine.longStatus) {
                Button(checking ? "Checking…" : "Check") { check() }
                    .disabled(checking)
            }
            SettingRow(title: "Where things live",
                       detail: Paths.support) {
                Button("Reveal") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Paths.support))
                }
            }
            SettingRow(title: "Engine log",
                       detail: engineLogSummary) {
                Button("Open Log") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: AnalysisEngine.logPath))
                }
                .disabled(!FileManager.default.fileExists(atPath: AnalysisEngine.logPath))
            }
            SettingRow(title: "Model files",
                       detail: "Downloaded once, kept beside the tags") {
                Button("Show") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: AnalysisEngine.modelsDir))
                }
            }
            StatusLine(text: result)
            Spacer(minLength: 0)
        }
    }

    private var engineLogSummary: String {
        let path = AnalysisEngine.logPath
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? Int else {
            return "Nothing written yet"
        }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) so far"
    }

    /// Ask the engine to start and load its model, and report honestly what
    /// happened. The one thing this does that matters: it turns "engine
    /// stopped" into a sentence naming the reason.
    private func check() {
        checking = true
        result = nil
        Task {
            await engine.warm()
            checking = false
            switch engine.phase {
            case .broken(let why):
                result = "The engine could not start: \(why)"
            case .idle:
                result = "Engine ready — \(engine.modelText.isEmpty ? "model loaded" : engine.modelText)"
            default:
                result = "Engine is \(engine.phase.title.lowercased()) right now; try again when it is idle."
            }
        }
    }
}

// MARK: - the engine's own words, for the detail line

private extension AnalysisEngine {
    /// One honest line about what the engine is doing or why it stopped.
    var longStatus: String {
        if case .broken(let why) = phase { return why }
        if !modelText.isEmpty { return modelText }
        if !statusText.isEmpty { return statusText }
        if isBusy, let name = currentName { return "Working on \(name)" }
        return installedSummary
    }

    private var installedSummary: String {
        var parts: [String] = []
        parts.append(FileManager.default.fileExists(atPath: Self.installedScript)
                     ? "engine installed" : "engine not installed yet")
        let models = (try? FileManager.default.contentsOfDirectory(atPath: Self.modelsDir)) ?? []
        parts.append(models.isEmpty ? "no models downloaded" : "\(models.count) model folders")
        return parts.joined(separator: " · ")
    }
}


/// Read-only history on open; retry always requires an explicit button press.
private struct AnalysisJobHistory: View {
    @ObservedObject var ledger: JobLedger
    @ObservedObject var app: AppModel

    var body: some View {
        DisclosureGroup("Analysis history") {
            if let problem = ledger.persistenceError ?? app.jobNotice {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            let recent = ledger.jobs.values.sorted { $0.createdAt > $1.createdAt }.prefix(10)
            if recent.isEmpty {
                Text("No analysis jobs in this profile yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(recent), id: \.id) { job in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(job.paths.count) videos · \(job.phase.rawValue.capitalized)")
                        Text(Date(timeIntervalSince1970: job.createdAt), style: .date)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if job.phase == .running {
                        Button("Stop") { app.stopAnalysis() }
                    } else if job.phase == .failed || job.phase == .requested || job.phase == .cancelled {
                        Button("Retry unfinished") {
                            let paths = job.paths.filter { job.outcomes[$0] != "done" }
                            Task { await app.classify(paths: paths) }
                        }
                        .disabled(app.engine?.isBusy == true)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 8)
    }
}
