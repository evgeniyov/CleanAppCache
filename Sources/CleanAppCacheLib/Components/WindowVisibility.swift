import SwiftUI
import AppKit

// MARK: - Window visibility
//
// `onAppear` / `onDisappear` follow the view tree, not the screen. A view stays
// appeared while its window is minimized, while the app is hidden, and while
// another window covers it completely, so work that exists only to be looked
// at — a sampler redrawing graphs every two seconds — keeps running for nobody.
// The window itself knows, so this asks it.

extension View {
    /// Calls `action` with whether the window holding this view can be seen:
    /// once when the view lands in a window, then on every change.
    func onWindowVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        background(WindowVisibilityReader(onChange: action))
    }
}

private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowVisibilityView, context: Context) {
        view.onChange = onChange
    }
}

private final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    /// The last value handed to `onChange`; nil until the first report in the
    /// current window, so that one always goes out.
    private var reported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        reported = nil
        guard let window else { return }
        // Occlusion already turns off for a minimized window and a hidden app;
        // the explicit notifications are there because those two are certain,
        // while the occlusion change can arrive a moment after the animation.
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            center.addObserver(self, selector: #selector(visibilityMayHaveChanged(_:)),
                               name: name, object: window)
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(visibilityMayHaveChanged(_:)),
                               name: name, object: nil)
        }
        report()
    }

    /// A reader, not a control: clicks go to whatever is drawn over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func visibilityMayHaveChanged(_ note: Notification) {
        report()
    }

    private func report() {
        guard let window else { return }
        let visible = !NSApp.isHidden
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        guard visible != reported else { return }
        reported = visible
        onChange?(visible)
    }
}
