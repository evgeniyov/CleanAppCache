import Foundation
import SwiftUI

/// Global app state that survives tab switches
@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()
    
    @Published public var dashboardViewModel  = DashboardViewModel()
    @Published public var appsViewModel       = AppsViewModel()
    @Published public var storageViewModel    = StorageViewModel()
    /// Built on the first visit to Monitor rather than at launch: its init
    /// reads the machine facts and the saved graphs, work the app has no use
    /// for until that screen opens. Never replaced, so nothing needs
    /// `@Published` to announce a new instance.
    public private(set) lazy var monitorViewModel = MonitorViewModel()
    @Published public var startupViewModel    = StartupViewModel()
    @Published public var leftoversViewModel  = LeftoversViewModel()
    @Published public var privacyViewModel    = PrivacyViewModel()
    @Published public var systemJunkViewModel = SystemJunkViewModel()
    @Published public var securityViewModel   = SecurityViewModel()
    @Published public var systemDataViewModel = SystemDataViewModel()
    @Published public var orphansViewModel    = OrphansViewModel()
    // These three live here rather than as `@StateObject` inside their views:
    // leaving the tab tears a view down and would throw away the scan with it,
    // bringing the user back to an empty screen and a search to re-run.
    @Published public var developerViewModel  = DeveloperViewModel()
    @Published public var largeFilesViewModel = LargeFilesViewModel()
    @Published public var duplicatesViewModel = DuplicatesViewModel()

    /// Which screen is on. Navigation is one level deep, so a single value is
    /// enough — there is no separate section/tab pair.
    ///
    /// Shared here rather than kept as `@State` private to `ContentView`: without
    /// that no screen could send the user anywhere, and Storage's "go and clean
    /// up" button would have nothing to write to. Sharing the selection is what
    /// lets a screen end in a next step instead of a dead end.
    @Published public var screen: Screen = Screen.initial

    /// Show a specific screen.
    public func open(_ screen: Screen) {
        self.screen = screen
    }

    private init() {}
}
