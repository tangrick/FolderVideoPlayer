import AppKit
import SwiftUI

/// Hands the window this view is in back to the app model, and keeps the
/// model's idea of full screen in step with the window's.
///
/// The window can go full screen four ways — the green button, ⌃⌘F, the menu
/// item, or a double click on the picture — and the app has to react the same
/// to all of them, so it listens to the window rather than to whoever asked.
struct WindowWatcher: NSViewRepresentable {
    let app: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            app.adopt(window: window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard app.playerWindow == nil, let window = view.window else { return }
        // Adopting publishes `fullScreen`, and this runs inside a layout pass:
        // changing state there sends AppKit back around to lay the view out
        // again while it is already doing so, which is the "not legal to call
        // -layoutSubtreeIfNeeded on a view which is already being laid out"
        // warning. It waits for the pass to finish instead.
        DispatchQueue.main.async { [app] in
            guard app.playerWindow == nil else { return }
            app.adopt(window: window)
        }
    }
}

extension AppModel {
    func adopt(window: NSWindow) {
        guard playerWindow !== window else { return }
        playerWindow = window
        let center = NotificationCenter.default
        for (name, entering) in [(NSWindow.didEnterFullScreenNotification, true),
                                 (NSWindow.didExitFullScreenNotification, false)] {
            let token = center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { self.fullScreen = entering }
            }
            fullScreenWatchers.append(token)
        }
        fullScreen = window.styleMask.contains(.fullScreen)

        // Escape leaves full screen, the way every player does it. macOS does
        // not do this for a window that went full screen by itself, and the
        // tag panel is left its own Escape while it is open.
        escapeWatcher = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The event itself does not cross into the isolated block: this
            // closure is not main-actor isolated and NSEvent is not Sendable,
            // so only the answer comes back out.
            guard event.keyCode == 53 else { return event }
            var swallowed = false
            MainActor.assumeIsolated {
                guard self.fullScreen, !self.showTagPanel else { return }
                self.leaveFullScreen()
                swallowed = true
            }
            return swallowed ? nil : event
        }

        // ⌘A selects the whole playlist.
        //
        // The Edit-menu item alone was not enough: ⌘A is a standard AppKit
        // selector, and with no first responder that answers it — the video
        // surface and the playlist rows are plain SwiftUI views, not a
        // responder that implements selectAll(_:) — the key press is simply
        // swallowed by the responder chain before the menu ever sees it.
        //
        // Typing wins. While a text field is editing, ⌘A means "select this
        // text", and taking that away to tick videos would be worse than not
        // having the shortcut at all. `firstResponder` is an NSTextView for a
        // focused SwiftUI TextField (the field editor), which is the check.
        selectAllWatcher = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "a" else { return event }
            var swallowed = false
            MainActor.assumeIsolated {
                // Other windows own their own ⌘A: Duplicates and Tag Profiles
                // have real lists, and this monitor is app-wide.
                guard NSApp.keyWindow === window else { return }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable { return }
                guard let pb = self.playback, !pb.visibleVideos.isEmpty else { return }
                self.selectAll(pb.visibleVideos)
                swallowed = true
            }
            return swallowed ? nil : event
        }
    }

    /// In and out of full screen. The window does the work; the layout follows
    /// from the notification it posts.
    func toggleFullScreen() {
        (playerWindow ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    func leaveFullScreen() {
        guard fullScreen else { return }
        toggleFullScreen()
    }
}

/// The picture on its own: both panels out of the way, and a transport bar
/// that fades with the pointer.
///
/// Full screen is for watching, so anything that is not the video earns its
/// place by being asked for. Move the mouse and the bar comes back; leave it
/// alone for a few seconds and the bar and the pointer both go.
struct FullScreenControls: ViewModifier {
    @ObservedObject var app: AppModel
    let paused: Bool
    @State private var idle: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                if case .active = phase { wake() }
            }
            // A video that is not playing keeps its controls: nothing is
            // happening for them to be in the way of.
            .onChange(of: paused) { if paused { wake(hiding: false) } }
            .onChange(of: app.fullScreen) { wake(hiding: app.fullScreen) }
            .onDisappear { idle?.cancel() }
    }

    private func wake(hiding: Bool = true) {
        idle?.cancel()
        app.controlsVisible = true
        guard hiding, app.fullScreen else { return }
        idle = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, app.fullScreen, !paused else { return }
            app.controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

extension View {
    func fullScreenControls(_ app: AppModel, paused: Bool) -> some View {
        modifier(FullScreenControls(app: app, paused: paused))
    }
}
