import SwiftUI
import AppKit

// MARK: - Root (injects localization + reactive locale)

public struct RootView: View {
    @StateObject private var loc = Localizer.shared
    @StateObject private var themeManager = ThemeManager.shared

    public init() {}

    public var body: some View {
        ContentView()
            .environmentObject(loc)
            .environmentObject(themeManager)
            .environment(\.locale, loc.locale)
            .tint(themeManager.theme.accent)
            .preferredColorScheme(themeManager.theme.colorScheme)
    }
}

// MARK: - Navigation model
//
// One flat level: three groups of screens, no tabs inside a screen. Large
// Files and Duplicates live under Cleanup, the Uninstaller group opens with
// Apps, and Settings sits in the sidebar footer rather than in any group.

public enum NavGroup: String, CaseIterable, Identifiable {
    case system, cleanup, uninstaller

    public var id: String { rawValue }
    var titleKey: String { "section.\(rawValue)" }

    var screens: [Screen] {
        switch self {
        case .system:      return [.storage, .systemData, .monitor, .history, .security]
        case .cleanup:     return [.smartCleanup, .systemJunk, .developer, .privacy,
                                   .largeFiles, .duplicates]
        case .uninstaller: return [.apps, .leftovers, .orphans, .startup]
        }
    }
}

public enum Screen: String, CaseIterable, Identifiable {
    // System
    case storage, systemData, monitor, history, security
    // Cleanup
    case smartCleanup, systemJunk, developer, privacy, largeFiles, duplicates
    // Uninstaller
    case apps, leftovers, orphans, startup
    /// Reached from the sidebar footer, not from a group.
    case settings

    public var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .storage:      return "nav.storage"
        case .systemData:   return "nav.systemData"
        case .monitor:      return "nav.monitor"
        case .history:      return "history.show"
        case .security:     return "nav.security"
        case .smartCleanup: return "nav.cleanup"
        case .systemJunk:   return "nav.systemJunk"
        case .developer:    return "nav.developer"
        case .privacy:      return "nav.privacy"
        // These two screens use the existing `nav.largeFiles` / `nav.duplicates`
        // keys, which already hold the same strings, rather than shipping a
        // second copy of each under shorter names.
        case .largeFiles:   return "nav.largeFiles"
        case .duplicates:   return "nav.duplicates"
        case .apps:         return "nav.apps"
        case .leftovers:    return "nav.leftovers"
        case .orphans:      return "nav.orphans"
        case .startup:      return "nav.startup"
        case .settings:     return "settings.title"
        }
    }

    /// The app opens on Storage, and so does the menu-bar "Open" command.
    /// Overridable via CAC_INITIAL_SCREEN for testing and screenshots.
    static var initial: Screen {
        if let raw = ProcessInfo.processInfo.environment["CAC_INITIAL_SCREEN"],
           let screen = Screen(rawValue: raw) {
            return screen
        }
        return .storage
    }
}

// MARK: - ContentView

public struct ContentView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var appState = AppState.shared
    // Observed directly: `AppState` publishes its view-model *references*, not
    // their contents, so reading `appState.storageViewModel.storageInfo` never
    // re-rendered — the sidebar's disk figure stayed frozen at whatever it
    // showed on first load.
    @ObservedObject private var storage = AppState.shared.storageViewModel
    @State private var showFDABanner = false
    /// CAC_HIDE_FDA_BANNER hides the banner for screenshots taken on a Mac
    /// without Full Disk Access; otherwise it shows whenever access is missing.
    private static let hidesAccessBanner = ProcessInfo.processInfo.environment["CAC_HIDE_FDA_BANNER"] != nil
    @AppStorage("app.onboarded") private var onboarded = false

    public init() {}

    // Custom split layout (plain HStack) instead of NavigationSplitView — this
    // avoids the unified-toolbar safe-area issues that caused content to slide
    // under the title bar, and works identically on macOS 13 through 27.
    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Metric.sidebar)

            Rectangle().fill(Palette.borderStrong).frame(width: 1)

            VStack(spacing: 0) {
                if showFDABanner {
                    FullDiskAccessBanner {
                        withAnimation(Motion.content) { showFDABanner = false }
                    }
                    .padding(.horizontal, Metric.gutter)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The content area owns the horizontal budget and never lets a
            // wide table push the window out.
            .frame(minWidth: 0)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background.ignoresSafeArea())
        .overlay { ToastOverlay() }
        .sheet(isPresented: Binding(
            get: { !onboarded },
            set: { if !$0 { onboarded = true } }
        )) {
            OnboardingView { onboarded = true }
                .environmentObject(loc)
        }
        .task {
            showFDABanner = !FullDiskAccess.isGranted() && !Self.hidesAccessBanner
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Re-check when the user returns (e.g. after granting access in
            // System Settings) so the banner disappears on its own.
            let granted = FullDiskAccess.isGranted()
            withAnimation(Motion.content) { showFDABanner = !granted && !Self.hidesAccessBanner }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        GeometryReader { geometry in
            // Fifteen navigation rows plus three headings, identity and disk
            // footer need about 850pt at the regular density. The minimum
            // window is 680pt: use 28pt targets there so every section fits.
            let compact = geometry.size.height < 850
            VStack(spacing: 0) {
                identityHeader(compact: compact)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(NavGroup.allCases.enumerated()), id: \.element) { index, group in
                            SidebarGroupHeader(title: loc.s(group.titleKey), isFirst: index == 0,
                                               compact: compact) {
                                if let first = group.screens.first { appState.screen = first }
                            }
                            ForEach(group.screens) { screen in
                                SidebarItemRow(title: loc.s(screen.titleKey),
                                               isSelected: appState.screen == screen,
                                               rowHeight: compact ? Metric.tapTarget : Metric.sidebarRow) {
                                    appState.screen = screen
                                } badge: {
                                    counter(for: screen)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                sidebarFooter(compact: compact)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surfaceRaised.ignoresSafeArea())
    }

    /// The app monogram at 20pt beside the name.
    private func identityHeader(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Monogram(size: 20)
            Text(loc.s("app.name"))
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.top, compact ? 12 : 20)
        .padding(.horizontal, 18)
        .padding(.bottom, compact ? 12 : 18)
    }

    /// Disk gauge and the Settings row.
    private func sidebarFooter(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            if let info = storage.storageInfo {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(loc.s("sidebar.disk"))
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 4)
                    Text(Fmt.percent(info.usedPercent * 100, decimals: 0))
                        .font(Typo.numeric(12))
                        .foregroundStyle(Palette.textPrimary)
                }

                GaugeBar(fraction: info.usedPercent, height: 6)

                Text(diskFigure(info))
                    .font(Typo.numeric(11, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }

            SidebarItemRow(title: loc.s("settings.title"),
                           isSelected: appState.screen == .settings, rowHeight: Metric.sidebarSettingsRow) {
                appState.screen = .settings
            }
            .padding(.top, 2)
        }
        .padding(.top, compact ? 10 : 14)
        .padding(.horizontal, 18)
        .padding(.bottom, compact ? 10 : 16)
        // A hairline, not the card border: the footer is part of the sidebar,
        // not a panel sitting on it.
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.borderHairline).frame(height: 1)
        }
    }

    /// "379.4 / 500.3 GB" — one unit, printed once, at the end.
    private func diskFigure(_ info: StorageInfo) -> String {
        Fmt.bytesPair(info.usedBytes, info.totalBytes)
    }

    // MARK: Counters
    //
    // "Where is the space" answered before anything is opened. Every counter is
    // nil until its section has been scanned — the sidebar shows nothing rather
    // than a zero that would read as "already clean".

    @ViewBuilder
    private func counter(for screen: Screen) -> some View {
        // Closure signatures are spelled out: an inferred many-branch switch
        // over as many different generic instantiations is exactly the shape
        // that makes the type-checker crawl.
        switch screen {
        case .storage:
            SidebarCounter(vm: appState.storageViewModel) { (vm: StorageViewModel) -> String? in
                vm.storageInfo?.formattedFree
            }
        case .systemData:
            SidebarCounter(vm: appState.systemDataViewModel) { (vm: SystemDataViewModel) -> String? in
                guard vm.hasScanned else { return nil }
                let total = vm.components.compactMap(\.bytes).reduce(UInt64(0), +)
                guard total > 0 else { return nil }
                return Fmt.bytes(total)
            }
        case .security:
            SidebarCounter(vm: appState.securityViewModel) { (vm: SecurityViewModel) -> String? in
                vm.hasRun ? String(vm.score) : nil
            }
        case .smartCleanup:
            SidebarCounter(vm: appState.dashboardViewModel) { (vm: DashboardViewModel) -> String? in
                vm.scanResult?.formattedTotalSize
            }
        case .systemJunk:
            SidebarCounter(vm: appState.systemJunkViewModel) { (vm: SystemJunkViewModel) -> String? in
                vm.hasScanned ? vm.formattedTotalSize : nil
            }
        case .privacy:
            SidebarCounter(vm: appState.privacyViewModel) { (vm: PrivacyViewModel) -> String? in
                vm.hasScanned ? vm.formattedTotalSize : nil
            }
        case .apps:
            SidebarCounter(vm: appState.appsViewModel) { (vm: AppsViewModel) -> String? in
                vm.hasScanned ? String(vm.apps.count) : nil
            }
        case .leftovers:
            SidebarCounter(vm: appState.leftoversViewModel) { (vm: LeftoversViewModel) -> String? in
                vm.hasScanned ? vm.formattedTotal : nil
            }
        case .orphans:
            SidebarCounter(vm: appState.orphansViewModel) { (vm: OrphansViewModel) -> String? in
                vm.hasScanned ? String(vm.items.count) : nil
            }
        case .startup:
            SidebarCounter(vm: appState.startupViewModel) { (vm: StartupViewModel) -> String? in
                vm.hasScanned ? String(vm.items.count) : nil
            }
        case .monitor, .history, .developer, .largeFiles, .duplicates, .settings:
            EmptyView()
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            switch appState.screen {
            case .storage:      StorageView().environmentObject(appState.storageViewModel)
            case .systemData:   SystemDataView().environmentObject(appState.systemDataViewModel)
            case .monitor:      MonitorView().environmentObject(appState.monitorViewModel)
            case .history:      HistoryPane()
            case .security:     SecurityView().environmentObject(appState.securityViewModel)
            case .smartCleanup: DashboardView().environmentObject(appState.dashboardViewModel)
            case .systemJunk:   SystemJunkView().environmentObject(appState.systemJunkViewModel)
            case .developer:    DeveloperView().environmentObject(appState.developerViewModel)
            case .privacy:      PrivacyView().environmentObject(appState.privacyViewModel)
            case .largeFiles:   LargeFilesView().environmentObject(appState.largeFilesViewModel)
            case .duplicates:   DuplicatesView().environmentObject(appState.duplicatesViewModel)
            case .apps:         AppsView().environmentObject(appState.appsViewModel)
            case .leftovers:    LeftoversView().environmentObject(appState.leftoversViewModel)
            case .orphans:      OrphansView().environmentObject(appState.orphansViewModel)
            case .startup:      StartupView().environmentObject(appState.startupViewModel)
            case .settings:     SettingsView()
            }
        }
        // `appState` is injected once, around the switch. Attached to each case
        // separately, one case can miss it, and opening that screen crashes on
        // `EnvironmentObject.error()` — a missing injection is a trap, not a
        // compile error.
        .environmentObject(appState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(appState.screen)
        .transition(.opacity)
        .animation(Motion.tabSwitch, value: appState.screen)
    }
}
