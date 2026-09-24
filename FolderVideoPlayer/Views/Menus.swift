import AppKit
import SwiftUI

struct MainMenu: Commands {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var playback: PlaybackController? { app.playback }

    /// What Reveal and Trash act on: the ticked videos, or the one playing
    /// when nothing is ticked. Never the whole playlist — the same rule the
    /// playlist's own Files menu follows, so ⌘⌫ can never mean more than the
    /// button of the same name.
    private var fileTargets: [String] {
        if !app.selection.isEmpty { return Array(app.selection) }
        if let path = playback?.currentPath { return [path] }
        return []
    }

    // MARK: - updates

    /// App ▸ Check for Updates…: this build's version against the newest
    /// release on the public repo. Only ever on request — nothing checks on
    /// its own. With a newer one, Install and Relaunch downloads the DMG,
    /// checks the app inside (same signing team, Gatekeeper, the version
    /// offered), swaps it in once this one has quit, and reopens it. A copy
    /// that cannot replace itself (an Xcode build, a read-only folder) gets
    /// the download in the browser instead.
    private func checkForUpdates() {
        Task { @MainActor in
            let current = UpdateCheck.running
            let alert = NSAlert()
            let release: UpdateCheck.Release
            do {
                release = try await UpdateCheck.latest()
            } catch {
                alert.alertStyle = .warning
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "GitHub could not be reached (\(error.localizedDescription)). "
                    + "You have version \(current)."
                alert.runModal()
                return
            }
            guard UpdateCheck.isNewer(release.version, than: current) else {
                alert.messageText = "You're up to date"
                alert.informativeText = "FolderVideoPlayer \(current) is the newest version."
                alert.runModal()
                return
            }
            let notes = URL(string: release.html_url)
            let installed = Bundle.main.bundlePath
            let blocked = release.dmg == nil ? "that release has no disk image"
                : UpdateCheck.cannotInstallInPlace(bundlePath: installed)
            alert.messageText = "FolderVideoPlayer \(release.version) is available"
            if let blocked {
                alert.informativeText = "You have \(current). It can't update itself here — \(blocked) — "
                    + "so Download opens the disk image in your browser; drag the new app into "
                    + "Applications to replace this one. Your tags and settings are kept."
                alert.addButton(withTitle: "Download")
            } else {
                alert.informativeText = "You have \(current). FolderVideoPlayer will download the new "
                    + "version, check it is signed by the same developer, then quit, update itself "
                    + "and reopen. Your tags and settings are kept."
                alert.addButton(withTitle: "Install and Relaunch")
            }
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if blocked != nil {
                    if let url = release.dmg ?? notes { NSWorkspace.shared.open(url) }
                } else {
                    await install(release, over: installed, notes: notes)
                }
            case .alertSecondButtonReturn:
                if let notes { NSWorkspace.shared.open(notes) }
            default: break
            }
        }
    }

    /// Download, check, stage, hand the swap to the script, quit.
    private func install(_ release: UpdateCheck.Release, over installed: String, notes: URL?) async {
        app.say("Downloading FolderVideoPlayer \(release.version)…",
                "The app will quit and reopen by itself once the new version is checked. "
                + "You can keep using it until then.")
        do {
            let staged = try await UpdateCheck.prepare(release, installedAt: installed)
            try UpdateCheck.launchSwap(installed: installed, staged: staged)
            // The normal quit: the analysis store's flush and every other
            // willTerminate duty run before the script swaps the app.
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The update was not installed"
            alert.informativeText = "\(error.localizedDescription.prefix(1).uppercased() + error.localizedDescription.dropFirst()). "
                + "This version is unchanged. You can download \(release.version) from the release page instead."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn, let notes { NSWorkspace.shared.open(notes) }
        }
    }

    // MARK: - the profile document

    /// File ▸ New Profile…: a new person, with their own folder on the shares.
    ///
    /// A name already in use is refused OUT LOUD. The window's own flow simply
    /// did nothing, which reads as a broken button rather than as a name being
    /// taken — and the name decides a folder on the share, so two profiles
    /// sharing one would publish over each other.
    private func newProfile() {
        let count = library.tagCounts.count
        let kept = count == 0
            ? ""
            : " Your \(count) tags stay with “\(library.person)” and come back when you "
              + "choose it again."
        guard let typed = ask("New Profile",
                              "A profile is one person's tags, readings, people and trained "
                              + "heads, kept together and published to its own folder on the "
                              + "shares. A new profile starts empty." + kept,
                              "") else { return }
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard !library.profiles.contains(where: { slug($0) == slug(name) }) else {
            app.say("That name is taken",
                    "A profile is already called “\(name)”. Choose another name.")
            return
        }
        library.createProfile(name)
        // Nothing from the old profile stays on screen. Its playlist was built
        // from ITS tags, and its ticked rows point at ITS videos.
        playback?.closePlaylist()
        app.selectNone()
        Task { await library.adoptProfileOnShares() }
    }

    /// File ▸ Close Profile: the empty state. Said before it happens, because
    /// "everything emptied" arriving unannounced reads as data loss.
    private func closeProfile() {
        let count = library.tagCounts.count
        guard count > 0 else {
            library.closeProfile()
            playback?.closePlaylist()
            app.selectNone()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close “\(library.person)”?"
        alert.informativeText = "Its \(count) tags, readings and people stay in their "
            + "own folder and come back when you open it. The player keeps working; "
            + "tagging is off until a profile is open."
        alert.addButton(withTitle: "Close Profile")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.closeProfile()
        playback?.closePlaylist()
        app.selectNone()
    }

    /// File ▸ Publish: the explicit push. The same alert the old Tags ▸
    /// Publish Tags Now reported with — per share, written or refused — because
    /// a silent success is indistinguishable from a click that did nothing.
    private func publishNow() {
        Task {
            await library.claimName()
            let (written, skipped) = await library.publishTags()
            let lines = written.map { "✓ \($0.0): \($0.1) videos" }
                + skipped.map { "✗ \($0.0): \($0.1)" }
            app.say(skipped.isEmpty ? "Tags published" : "Some shares were not written",
                    lines.isEmpty
                        ? "This profile has no tags on any mounted share, so there "
                          + "was nothing to publish."
                        : lines.joined(separator: "\n\n"))
        }
    }

    /// File ▸ Export Profile…: the whole document, folder and all, copied
    /// wherever the user points. Replaces "Save a copy of your tags" — a single
    /// tags file stopped being a backup the moment a profile became a bundle.
    private func exportProfile() {
        let panel = NSSavePanel()
        panel.title = "Export Profile"
        panel.nameFieldStringValue = "\(library.person).\(ProfileBundle.extensionName)"
        panel.allowedContentTypes = [.folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.copyItem(atPath: ProfileBundle.dir(library.person),
                                             toPath: url.path)
            app.say("Profile exported",
                    "A complete copy of “\(library.person)” — tags, readings, people, "
                    + "trained heads — is at \(url.path).")
        } catch {
            app.say("Could not export the profile", error.localizedDescription)
        }
    }

    /// File ▸ Open Profile…: what this Mac has, then what the shares have.
    ///
    /// The two are worth telling apart before opening: a name found on a share
    /// and not here has no tags on this Mac yet, and takes what it has already
    /// published when it is adopted.
    private func openProfile() {
        Task {
            let onShares = await library.sharePeople()
            let mine = Set(library.profiles.map { slug($0) })
            var names = library.profiles
            for person in onShares
            where !mine.contains(slug(person.name))
                && !library.hiddenProfiles.contains(slug(person.name)) {
                names.append(person.name)
            }
            guard !names.isEmpty else {
                app.say("No profiles yet",
                        "File ▸ New Profile makes one. It is kept on this Mac and published "
                        + "to your shares for the other devices.")
                return
            }
            let labels = names.map { name in
                mine.contains(slug(name))
                    ? name + "  —  on this Mac"
                    : name + "  —  found on your shares"
            }
            guard let picked = chooseProfile(
                "Open Profile",
                "Opening a profile keeps the profile you are in where it is — its tags stay "
                + "in its own folder and come back when you choose it again.",
                labels), names.indices.contains(picked) else { return }
            switchToProfile(names[picked])
        }
    }

    /// Put a profile in force from the menu.
    ///
    /// The same steps the Tag Profiles window takes, including its share side:
    /// a profile this Mac has never seen takes what its other devices have
    /// already published, and one that is new here says who it is on the share
    /// before anything is merged or written.
    private func switchToProfile(_ name: String) {
        guard !library.isOpen(name) else { return }
        playback?.closePlaylist()
        app.selectNone()
        Task {
            await library.openProfile(name)
            playback?.rebuildRows()
        }
    }

    /// A picker made of one popup, in the alert shape `ask` already uses. There
    /// is no document browser to put a list of profiles in yet — that is P4's
    /// window — and a menu item that opens nothing is worse than a plain list.
    private func chooseProfile(_ title: String, _ detail: String,
                               _ options: [String]) -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 25))
        popup.addItems(withTitles: options)
        alert.accessoryView = popup
        alert.window.initialFirstResponder = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let picked = popup.indexOfSelectedItem
        return picked >= 0 ? picked : nil
    }

    /// The playing video's stars, 0 when unrated or nothing plays.
    private var currentRating: Int {
        playback.flatMap { library.rating($0.currentPath ?? "") } ?? 0
    }

    private func rate(_ stars: Int) {
        if let path = playback?.currentPath { library.setRating(stars, for: path) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // File leads with the profile, because that is what a profile is
            // now: one document holding one person's tags, readings, people and
            // trained heads. The folder verbs below are what you point it AT,
            // so they keep their own wording and move one modifier over.
            //
            // The old ⌘N/⌘O are not free: ⌘N was Hide/Show Library and ⌘O was
            // Open Folder…, and the maintainer chose the document verbs for
            // both on 2026-09-17.
            Button("New Profile…") { newProfile() }
                .keyboardShortcut("n")

            Button("Open Profile…") { openProfile() }
                .keyboardShortcut("o")

            Menu("Open Recent Profile") {
                ForEach(library.recentProfiles, id: \.self) { name in
                    Button(name) { switchToProfile(name) }
                        .disabled(library.isOpen(name))
                }
            }
            .disabled(library.recentProfiles.isEmpty)

            Divider()

            Button("Open Folder…") {
                if let playback { chooseFolder(playback: playback) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            // Named for what it lists. There are two recent lists in this menu
            // now, and "Open Recent" alone would not say which.
            Menu("Open Recent Folder") {
                ForEach(library.recent, id: \.self) { root in
                    Button((root as NSString).lastPathComponent) {
                        playback?.openFolder(root)
                    }
                }
                if !library.recent.isEmpty {
                    Divider()
                    Button("Clear Menu") { library.recent = []; library.save() }
                }
            }
            .disabled(library.recent.isEmpty)

            // Duplicates act on the folders above; two items did not earn a
            // top-level menu of their own. The count goes before the ellipsis.
            Button(library.groupCount == 0
                   ? "Find Duplicates…"
                   : "Find Duplicates (\(library.groupCount))…") {
                openWindow(id: "duplicates")
            }
            Button(library.sparedDupes.isEmpty
                   ? "Put Removed Copies Back"
                   : "Put Removed Copies Back (\(library.sparedDupes.count))") {
                app.duplicates?.restoreRemoved()
            }
            .disabled(library.sparedDupes.isEmpty)

            Divider()

            // The one entry for this window. It used to be here as "Profile
            // Settings…" and in Tags as "Tag Profiles…" — one window, two names.
            Button("Tag Profiles…") { openWindow(id: "profiles") }

            Button(app.showLibrary ? "Hide Library" : "Show Library") {
                app.showLibrary.toggle()
            }
            // Off ⌘N, which New Profile took. Kept, not dropped: this is how
            // the sidebar comes back after being hidden.
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            // The document verbs sit after the folder verbs: New/Open/Recent
            // above are about profiles, this block is about the one in hand.
            Button("Publish") { publishNow() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!library.profileOpen)
                .help("Write this profile's share-keyed tags to every mounted share")

            // Publish's other half: Publish pushes this device's tags out,
            // this pulls the other devices' in. Next to each other so the
            // sync verbs are in one place.
            Button("Refresh Tags") {
                Task {
                    let adopted = await library.mergeShared()
                    app.say("Tags refreshed", adopted == 0
                            ? "Nothing changed on your other devices."
                            : "\(adopted) videos' tags changed on your other devices.")
                }
            }

            Button("Export Profile…") { exportProfile() }
                .disabled(!library.profileOpen)
                .help("Copy the whole profile — tags, readings, people, heads — somewhere else")

            Button("Close Profile") { closeProfile() }
                .disabled(!library.profileOpen)
                // Deliberately no ⌘W: that closes the player window, and has
                // for years. Overloading it would change what it means to
                // someone mid-video. See the plan, §5.
                .help("Empty the tagging surfaces; the profile stays in its own folder")
        }

        CommandMenu("Playback") {
            Button(playback?.playing == true ? "Pause" : "Play") {
                playback?.togglePlayPause()
            }
            // One row each. ⌘→ / ⌘← do the same and are handled by the key
            // monitor in FullScreen.swift — a second visible "Next" row was
            // the only way SwiftUI menus could carry a second key.
            Button("Next") { playback?.next() }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("Previous") { playback?.previous() }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Skip Forward \(library.skipSeconds)s") {
                playback?.skip(Double(library.skipSeconds))
            }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Skip Back \(library.skipSeconds)s") {
                playback?.skip(-Double(library.skipSeconds))
            }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Divider()
            // 5 stars IS the Favorite tag, so this is an ordinary tag
            // playlist — the same one an Apple TV's favourites land in.
            Button("Play 5-Star Videos") { playback?.playTag(favoriteTag) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(library.countRated(5) == 0 || !library.profileOpen)
            Divider()
            Picker("Order", selection: Binding(
                get: { library.order },
                set: { library.order = $0 }
            )) {
                ForEach(PlayOrder.allCases) { Text($0.title).tag($0) }
            }
            Picker("Speed", selection: Binding(
                get: { library.speed },
                set: { playback?.setSpeed($0) }
            )) {
                ForEach(Tuning.speeds, id: \.self) { speed in
                    Text(speed == 1 ? "Normal" : "\(speed.formatted())×").tag(speed)
                }
            }
            Divider()
            Button("Rotate Right") {
                if let path = playback?.currentPath { app.rotation.rotate(path, clockwise: true) }
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(playback?.currentPath == nil)
            Button("Rotate Left") {
                if let path = playback?.currentPath { app.rotation.rotate(path, clockwise: false) }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(playback?.currentPath == nil)
            Divider()
            Button("Stop") { playback?.stop() }
                .keyboardShortcut(".", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button(app.fullScreen ? "Leave Full Screen" : "Full Screen") {
                app.toggleFullScreen()
            }
            .keyboardShortcut("f")
            Divider()
            Button(app.showPlaylist ? "Hide Playlist" : "Show Playlist") {
                app.showPlaylist.toggle()
            }
            .keyboardShortcut("l")
            Button("Show Hidden Videos…") { app.showHiddenVideos() }
                .disabled(library.hidden.isEmpty)
                .help(library.hidden.isEmpty
                      ? "Nothing is hidden yet"
                      : "Asks for the password, then plays only the hidden videos")
            Divider()
            Toggle("Poster Frames", isOn: $library.showThumbnails)
            Button(PlaylistStyle.icons.title) { library.playlistStyle = .icons }
                .keyboardShortcut("1")
            Button(PlaylistStyle.list.title) { library.playlistStyle = .list }
                .keyboardShortcut("2")
            Divider()
        }

        // Select All / Delete where every Mac app keeps them. The playlist's
        // own selection bar still carries All and None — this is the same
        // thing reachable without moving the hand off the keyboard.
        CommandGroup(after: .pasteboard) {
            Divider()
            // Not disabled on `visibleVideos`: `playback` is reached through
            // `app` and is not observed here, so a disabled state computed from
            // it sticks at whatever was true when the menu was first built —
            // which is launch, when the playlist is still empty, leaving ⌘A
            // permanently grey. The guard in the action is the real check.
            Button("Select All") {
                guard let playback, !playback.visibleVideos.isEmpty else { return }
                app.selectAll(playback.visibleVideos)
            }
            .keyboardShortcut("a")

            Button("Deselect All") { app.selectNone() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(app.selection.isEmpty)

            Divider()

            Button("Get Info") {
                openWindow(id: "info")
            }
            .keyboardShortcut("i")
            .disabled(app.infoTarget == nil)
            .help(app.selection.count > 1
                  ? "Pick one video to see its details"
                  : "Everything known about this video")

            Divider()

            Button(app.selection.isEmpty
                   ? "Reveal in Finder"
                   : "Reveal \(app.selection.count) in Finder") {
                let paths = fileTargets
                guard !paths.isEmpty else { return }
                NSWorkspace.shared.activateFileViewerSelecting(
                    paths.map { URL(fileURLWithPath: $0) })
            }
            .keyboardShortcut("r")
            .disabled(fileTargets.isEmpty)

            Button(app.selection.isEmpty
                   ? "Move to Trash…"
                   : "Move \(app.selection.count) to Trash…") {
                app.trashFiles(fileTargets)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(fileTargets.isEmpty)

            Divider()

            // App-only and reversible: the file is untouched, so this needs
            // no confirmation and sits apart from Trash for that reason.
            if !fileTargets.isEmpty, fileTargets.allSatisfy({ library.isHidden($0) }) {
                Button(app.selection.isEmpty ? "Unhide Video"
                                             : "Unhide \(app.selection.count) Videos") {
                    app.unhideVideos(fileTargets)
                }
            } else {
                Button(app.selection.isEmpty ? "Hide Video"
                                             : "Hide \(app.selection.count) Videos") {
                    app.hideVideos(fileTargets)
                }
                // Not ⌥⌘H: that is the app menu's Hide Others, which comes
                // first in the menu bar and wins.
                .keyboardShortcut("h", modifiers: [.command, .control])
                .disabled(fileTargets.isEmpty)
                .help("Keep this out of the app's sight. The file itself is untouched.")
            }
        }

        CommandMenu("Tags") {
            Button("Tag This Video…") { app.showTagPanel.toggle() }
                .keyboardShortcut("t")
                .disabled(!library.profileOpen)
            // Stars on what is playing, straight from the menu. The tick
            // tracks the current rating. Star tags are tags, so a closed
            // profile refuses them like every other tagging surface.
            //
            // Built here rather than with StarRatingMenuItems so the five-star
            // row can carry ⌘⇧D — a Picker's rows cannot hold a shortcut, and
            // a separate "Rate 5 Stars" row said the same thing twice.
            // Choosing a star always sets it (⌘⇧D on a 5-star video stays 5);
            // No Rating takes it away.
            Menu("Stars") {
                if currentRating > 0 {
                    Button("No Rating") { rate(0) }
                    Divider()
                }
                ForEach(1...4, id: \.self) { star in
                    Toggle(String(repeating: "★", count: star), isOn: Binding(
                        get: { currentRating == star }, set: { _ in rate(star) }))
                }
                Toggle("★★★★★", isOn: Binding(
                    get: { currentRating == 5 }, set: { _ in rate(5) }))
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            .disabled(!library.profileOpen)
            Divider()
            Button("People…") { openWindow(id: "people") }
                .disabled(!library.facesEnabled || !library.profileOpen)
                .help(!library.facesEnabled
                      ? "Face Recognition is off — turn it on in Settings → AI"
                      : library.profileOpen
                      ? "Name the people in your videos"
                      : "Open a profile to see its people")
            // The switch itself lives in Settings → AI. One setting,
            // one control: two toggles on one flag is how they drift apart.
            Button("Face Recognition…") {
                app.settingsTab = .ai
                openSettings()
            }
                .help(library.facesEnabled
                      ? "On. Change it in Settings → AI."
                      : "Off. Turn it on in Settings → AI.")
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { checkForUpdates() }
        }

        CommandGroup(replacing: .help) {
            Button("Quick Start") {
                app.helpPage = .quickStart
                openWindow(id: "help")
            }
            Button("Keyboard Shortcuts") {
                app.helpPage = .shortcuts
                openWindow(id: "help")
            }
            Button("Where My Data Lives") {
                app.helpPage = .data
                openWindow(id: "help")
            }
        }
    }
}
