import AppKit
import Combine
import SwiftUI

/// Starting, running and ending a triage session: the part of the mode that
/// lives between the player and the model (`TriageSession`). The state it uses
/// is on `AppModel` itself, which an extension in another file cannot declare.
extension AppModel {

    /// Asked of the field when `T` is pressed.
    static let triageFocusFieldNotification = Notification.Name("FolderVideoPlayer.triageFocusField")

    /// Why triage cannot start now, in words, or nil when it can. The menu
    /// item stays enabled and says this when it is chosen, rather than greying
    /// out with nothing to read.
    var triageUnavailable: String? {
        guard let library, library.profileOpen else {
            return "Tags belong to a profile. Open one from the File menu first."
        }
        guard let playback else { return "Open a folder first." }
        if playback.mode == .hidden {
            return "Triage is not offered in the Hidden view, so a hidden video's name "
                + "never reaches its suggestions."
        }
        if playback.visibleVideos.isEmpty { return "There are no videos in this list to go through." }
        if transcriptEditDirty { return "Save or discard the transcript edit in progress first." }
        return nil
    }

    func startTriage(filter: TriageFilter = .needsTags) {
        guard triage == nil else { return }
        if let why = triageUnavailable {
            say("Triage can't start", why)
            return
        }
        guard let playback else { return }
        // Triage takes the place the panels share.
        showTagPanel = false
        showTranscriptPanel = false
        showMomentsPanel = false
        selectNone()
        triagePlaylist = playback.visibleVideos
        playback.beginTriage { [weak self] delta in
            guard let session = self?.triage else { return }
            if delta > 0 { session.skip() } else { session.back() }
        }
        // Anything that takes the player away from triage — a click on a row,
        // a new folder, a profile switch — ends the session with it.
        triageObservers = [
            playback.$triaging.dropFirst().filter { !$0 }.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.tearDownTriage() }
            },
            // A video that would not open is passed over. Deferred a turn: the
            // next video's load edits `problems` and this is its own callback.
            playback.$problems.sink { [weak self] problems in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let session = self?.triage, let path = session.current,
                              problems[path] != nil else { return }
                        session.skip()
                    }
                }
            },
        ]
        openTriageSession(filter)
    }

    /// Open a list in the player and start triage over it — the Library
    /// Overview's way in. The player window is brought forward, since the
    /// keys only work when it is the one that has the keyboard.
    func triageList(_ title: String, _ paths: [String], filter: TriageFilter) {
        guard !paths.isEmpty, let playback else { return }
        playback.playList(title, paths)
        startTriage(filter: filter)
        if triage != nil { playerWindow?.makeKeyAndOrderFront(nil) }
    }

    /// Begin the queue again over the same videos with another filter. What
    /// was answered stays answered; the undo list starts afresh.
    func setTriageFilter(_ filter: TriageFilter) {
        guard triage != nil, triage?.queue.filter != filter else { return }
        openTriageSession(filter)
    }

    private func openTriageSession(_ filter: TriageFilter) {
        guard let library, let suggestions else { return }
        let session = TriageSession(
            library: library, suggestions: suggestions, playlist: triagePlaylist, filter: filter,
            unavailable: { [weak self] path in self?.playback?.problems[path] != nil })
        triage = session
        triageShown = nil
        triageQueueWatch = session.$queue.sink { [weak self] queue in
            MainActor.assumeIsolated { self?.showInTriage(queue.current) }
        }
        showInTriage(session.current)
    }

    /// Put the cursor's video on screen, unless it is already there.
    private func showInTriage(_ path: String?) {
        guard path != triageShown else { return }
        triageShown = path
        if let path { playback?.triage(path) } else { playback?.pauseTriage() }
    }

    /// The Exit button, Esc, and Tags ▸ Stop Triage.
    func endTriage() {
        guard triage != nil else { return }
        let landing = triageShown
        playback?.endTriage(landingOn: landing)
        tearDownTriage()
        if let landing { selection = [landing] }
    }

    /// The session is over, however it ended. The tag write held back for speed
    /// is made now.
    func tearDownTriage() {
        triageObservers = []
        triageQueueWatch = nil
        triageShown = nil
        triage = nil
        library?.flushTags()
    }

    /// One key press while triage may be on. True when it was triage's, and so
    /// is not passed on to the menu or the window.
    func triageKey(code: UInt16, characters: String, flags: NSEvent.ModifierFlags,
                   in window: NSWindow) -> Bool {
        guard let session = triage, NSApp.keyWindow === window else { return false }
        let typing = (window.firstResponder as? NSTextView)?.isEditable == true
        let mods = flags.intersection([.command, .option, .control, .shift])

        // Esc first leaves the tag field, then leaves triage.
        if code == 53, mods.isEmpty {
            if typing { window.makeFirstResponder(nil) } else { endTriage() }
            return true
        }
        // While a field has the keyboard, it keeps every key, ⌘Z included.
        if typing { return false }

        if mods == .command, characters.lowercased() == "z" {
            session.undo()
            return true
        }
        if mods.isEmpty, code == 36 || code == 76 {          // Return, keypad Enter
            session.done()
            return true
        }
        if mods.isEmpty || mods == .option, let number = Int(characters), (1...9).contains(number) {
            if mods == .option { session.reject(key: number) } else { session.toggle(key: number) }
            return true
        }
        guard mods.isEmpty else { return false }
        switch characters.lowercased() {
        case "a": session.acceptAll()
        case "x": session.rejectAll()
        case "t", "/": NotificationCenter.default.post(name: Self.triageFocusFieldNotification, object: nil)
        case "m": playback?.toggleTriageMute()
        default: return false
        }
        return true
    }
}
