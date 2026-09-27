import AppKit
import SwiftUI

/// The macOS share picker (AirDrop, Messages, Mail…) for files, shown where the
/// pointer is in the key window — the place a right-click or a menu command
/// was just made.
///
/// A service that refuses a file (too big for Mail, a type Messages will not
/// take) is reported rather than failing silently; the file itself is never
/// touched, so a prepared copy is still there to try another way.
@MainActor
final class SharePresenter: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    static let shared = SharePresenter()

    /// Where refusals are reported. Set by the app model when it attaches.
    var report: ((String, String) -> Void)?

    func share(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty, let window = NSApp.keyWindow, let view = window.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let anchor = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        picker.show(relativeTo: view.bounds.contains(point) ? anchor : NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                    of: view, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker,
                                          delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        let names = items.compactMap { ($0 as? URL)?.lastPathComponent }
        let why = error.localizedDescription
        let cancelled = (error as NSError).code == NSUserCancelledError
        Task { @MainActor in
            guard !cancelled else { return }
            self.report?("Could not share",
                         "\(sharingService.title) did not accept \(names.isEmpty ? "the file" : names.joined(separator: ", ")): \(why)\n\n"
                         + "Nothing was deleted. A smaller copy (File ▸ Prepare for Sharing…) may get through.")
        }
    }
}
