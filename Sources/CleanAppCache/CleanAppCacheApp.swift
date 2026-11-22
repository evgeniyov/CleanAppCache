import CleanAppCacheLib
import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running after the window closes so the menu-bar widget stays
        // alive. The widget's popover has an explicit Quit button.
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // Without this, macOS 14+ logs "Secure coding is not enabled for
        // restorable state" on every launch and window restoration falls back
        // to legacy unarchiving. Nothing here restores custom state, so opting
        // into secure coding costs nothing.
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        StorageBackgroundMeasurement.shared.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        StorageBackgroundMeasurement.shared.start()
        // When the main window closes, fold the app into the menu bar (hide the
        // Dock icon). It comes back when the window is reopened.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { Self.updateDockVisibility() }
        }
        // Come up with a window. Granting Full Disk Access makes macOS quit and
        // reopen the app; because it keeps running after its window closes and
        // drops to `.accessory`, it could relaunch into that same state — alive,
        // menu-bar readout ticking, no window and no Dock icon. That is
        // indistinguishable from "it never started".
        DispatchQueue.main.async { Self.ensureMainWindow() }
    }

    /// Reopen (Dock click, `open -a`, Finder) with no window on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.ensureMainWindow() }
        return true
    }

    /// Shows the main window, creating one if the scene has none.
    static func ensureMainWindow() {
        // The policy flip must settle before activation. On macOS 14+
        // activation is cooperative, and flipping out of `.accessory` and
        // calling `activate` in the same runloop turn is a known way to get a
        // frontmost window without menu-bar ownership — the previous app's
        // menus stay up. Flip now; activate and order the window front one
        // turn later (the same deferral `applicationDidFinishLaunching` uses).
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            // An existing window may merely be ordered out; prefer reviving it
            // over asking the scene for a second one.
            if let existing = NSApp.windows.first(where: {
                $0.styleMask.contains(.titled) && $0.canBecomeMain
            }) {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            // No window at all — the menu-bar scene is still alive and owns an
            // `openWindow` action, so ask it.
            NotificationCenter.default.post(name: .cacShowMainWindow, object: nil)
        }
    }

    /// Show the Dock icon only while a real app window is open; otherwise run as
    /// a menu-bar accessory.
    static func updateDockVisibility() {
        let hasMainWindow = NSApp.windows.contains { w in
            w.isVisible && w.styleMask.contains(.titled) && w.canBecomeMain
        }
        NSApp.setActivationPolicy(hasMainWindow ? .regular : .accessory)
    }
}

@main
struct CleanAppCacheApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // `Window`, not `WindowGroup`. This is a single-instance utility: there
        // is no document, and two copies of the same disk view are never useful.
        // `WindowGroup` also opens two windows at launch here, and makes
        // `openWindow(id:)` from the menu bar mint another one every time; a
        // `Window` scene brings the one instance forward instead.
        Window(Text(verbatim: "CleanAppCache"), id: "main") {
            RootView()
                // The list-and-detail layouts — a 236pt sidebar, a table and a
                // 288–300pt detail panel beside it — stop fitting below 1100.
                .frame(minWidth: Metric.minWindowWidth, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        // Live system monitor in the macOS menu bar.
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(Localizer.shared)
                .environmentObject(ThemeManager.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        // Without a `Settings` scene ⌘, does nothing and the menu bar carries no
        // action of its own. The scene is what makes the shortcut real; without
        // it a ⌘, shortcut badge in the UI would advertise a dead key.
        Settings {
            SettingsView()
                .environmentObject(Localizer.shared)
                .environmentObject(ThemeManager.shared)
                .frame(width: 720, height: 560)
                .overlay { ToastOverlay() }
        }
    }
}
