import AppKit
import SwiftUI

/// Taking a folder out of the open profile's library, and putting it back.
/// The work is `Library.removeFolderFromLibrary`; this is the question asked
/// first and the tidying of the player after.
extension AppModel {

    /// Ask, then remove. From the sidebar's folder menus and from the Library
    /// Folders list; both come here, so both ask the same thing.
    /// True when the folder was removed; false when it was not (no profile,
    /// nothing to remove, or Cancel).
    @discardableResult
    func removeFromLibrary(_ folder: String) -> Bool {
        guard let library, library.profileOpen else {
            say("No profile is open", "A library belongs to a profile. Open one from the File menu first.")
            return false
        }
        let plan = library.folderPlan(folder)
        let name = (folder as NSString).lastPathComponent
        guard plan.videos > 0 || plan.sidebarEntries > 0 else {
            say("Nothing to remove", "“\(name)” holds nothing in \(library.person)’s library and is not "
                + "pinned or in Recent.")
            return false
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(name)” from \(library.person)’s library?"
        alert.informativeText = Self.removalText(plan, profile: library.person)
        // Cancel is the one Return presses: this is not something to do by
        // reflex.
        alert.addButton(withTitle: "Cancel")
        let remove = alert.addButton(withTitle: "Remove from Library")
        remove.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return false }

        guard library.removeFolderFromLibrary(folder) != nil else { return false }
        // What was on screen from that folder cannot stay: a list of videos the
        // library no longer holds. A tag list just loses the members.
        if let playback {
            let showing = [playback.root, playback.currentPath].compactMap { $0 }
            if showing.contains(where: { LibraryFolders.contains(folder, $0) }) {
                playback.closePlaylist()
            } else {
                playback.refreshMembership()
            }
        }
        return true
    }

    func undoFolderRemoval() {
        guard let library, library.undoFolderRemoval() else { return }
        playback?.refreshMembership()
    }

    /// What the question says it will do, and what it leaves alone.
    static func removalText(_ plan: Library.FolderPlan, profile: String) -> String {
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var holds: [String] = []
        if plan.tagged > 0 { holds.append("\(plan.tagged) with tags or stars") }
        if plan.withReadings > 0 { holds.append("\(plan.withReadings) with readings") }
        if plan.withHistory > 0 { holds.append("\(plan.withHistory) with watch history or a resume point") }
        var text = plan.videos == 0
            ? "It is pinned or in Recent, and that is all. "
            : "\(count(plan.videos, "video")) under it \(plan.videos == 1 ? "is" : "are") held in this "
              + "profile" + (holds.isEmpty ? ". " : ": \(holds.joined(separator: ", ")). ")
        text += "Those, their suggestions and moments, and the folder’s place in Pinned and Recent "
            + "are taken out. Tags also come off this profile’s copy on the shares, so other devices "
            + "and the Apple TV stop showing them.\n\n"
            + "The video files are not touched, and other profiles keep what they hold. Resume "
            + "points belong to this Mac, so they go for every profile. Transcripts and the AI’s "
            + "reading of the videos stay.\n\n"
            + "You can undo this until you quit."
        return text
    }
}
