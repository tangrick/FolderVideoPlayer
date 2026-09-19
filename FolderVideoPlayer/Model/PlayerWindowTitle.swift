import Foundation

/// The player window's title, as a document app would say it.
///
/// The profile part is the point of the file-system feel: whether the TV is
/// looking at what you are is the one thing the title is FOR. `Published X ago`
/// claims only what this Mac did — the published *file* is per device and the
/// TV merges them, so "the TV has it" is not knowable from here (plan §6).
enum PlayerWindowTitle {

    /// Python mode returns the plain title: that is the normal app, and a
    /// permanent badge on the shipping build would be noise.
    ///
    /// Core ML mode names the library as well as the engine, because the two
    /// engines write DIFFERENT embedding spaces (768-dim SigLIP 2 vs the
    /// engine's 768-dim ViT-L/14 — same width, different space). A Core ML run
    /// pointed at the real library is the
    /// expensive mistake, so the support directory is on the title bar where it
    /// cannot be missed.
    static func windowTitle(playlistEmpty: Bool,
                            sessionLabel: String,
                            mode: CoreMLClassifier.Mode,
                            support: String) -> String {
        let base = playlistEmpty ? "FolderVideoPlayer" : sessionLabel
        guard mode == .coreml else { return base }
        return "\(base) — Core ML [\((support as NSString).lastPathComponent)]"
    }

    /// The profile document's half of the title: `name — Published 2 min ago`,
    /// `name — Edited`, `name — Publishing…`, or nothing when no profile is
    /// open (then the playlist half speaks for the window).
    ///
    /// `publishedClean` decides between the timestamp and Edited — see the
    /// property's comment for why one refused share keeps the title honest.
    static func profilePart(name: String, open: Bool, publishing: Bool,
                            publishedClean: Bool, lastPublishedAt: Double,
                            now: Double = Date().timeIntervalSince1970) -> String? {
        guard open, !name.isEmpty else { return nil }
        if publishing { return "\(name) — Publishing…" }
        if !publishedClean { return "\(name) — Edited" }
        guard lastPublishedAt > 0 else { return name }
        let gap = max(0, now - lastPublishedAt)
        let words: String
        switch gap {
        case ..<60: words = gap < 10 ? "just now" : "\(Int(gap)) sec ago"
        case ..<3600: words = "\(Int(gap / 60)) min ago"
        case ..<86_400: words = "\(Int(gap / 3600)) h ago"
        default: words = "\(Int(gap / 86_400)) d ago"
        }
        return "\(name) — Published \(words)"
    }
}
