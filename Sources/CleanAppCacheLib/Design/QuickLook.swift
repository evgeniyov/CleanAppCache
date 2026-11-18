import SwiftUI
import AppKit
import Quartz

// MARK: - Quick Look preview controller
//
// Lets any list preview the currently-selected file with the system Quick Look
// panel (the same panel Finder shows when you press Space). Call
// `QuickLook.shared.toggle(url:)` to open/close it.

@MainActor
public final class QuickLook: NSObject {
    public static let shared = QuickLook()

    // The Quick Look panel only ever talks to us on the main thread, so this is
    // safe. `nonisolated(unsafe)` lets the nonisolated data-source methods read
    // it without crossing actor isolation (which the protocol requires).
    nonisolated(unsafe) private var url: URL?

    private override init() { super.init() }

    /// Open the panel for `url`, or close it if it's already showing this url.
    public func toggle(url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, self.url == url {
            panel.orderOut(nil)
            return
        }
        self.url = url
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public func close() {
        QLPreviewPanel.shared()?.orderOut(nil)
    }
}

// Conform via a nonisolated extension so it satisfies the protocol's
// nonisolated requirements without main-actor isolation warnings.
extension QuickLook: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        url == nil ? 0 : 1
    }

    nonisolated public func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        (url as NSURL?) ?? NSURL()
    }
}

// MARK: - View helpers

public extension View {
    /// Attaches a hidden Space-key handler that previews `url` when present.
    /// Apply this to the *list container* and drive `url` from the current
    /// selection — that way Space only triggers when a row is selected, and
    /// never while a different control (like the search field) is focused,
    /// because the hidden button is disabled when `url` is nil.
    func quickLookOnSpace(_ url: URL?) -> some View {
        background(
            Button("") {
                if let url { QuickLook.shared.toggle(url: url) }
            }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
            .allowsHitTesting(false)
            .disabled(url == nil)
        )
    }
}
