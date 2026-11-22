import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Settings
//
// One 620pt column of cards, 10pt apart: three switches, the menu-bar widget
// with its live preview, table density, appearance, alert thresholds and
// maintenance. A single column, not two: a two-column split ranks Maintenance
// and Appearance as peers and puts the two irreversible actions above the fold
// on the right.
//
// The preview is the centrepiece. Every other control on this screen describes
// something the user cannot see while they are setting it; the widget is the
// one thing the app draws into someone else's surface, so the screen draws that
// surface — monogram, app menu, the widget on `accentTint`, the system's own
// items and the clock — and the widget inside it renders the **live** readings
// from `MenuBarController`, not a sample.

// MARK: - Preferences other screens read

/// Row height in Monitor and the Uninstaller. Both bind
/// `@AppStorage(TableDensity.storageKey)` and lay their rows out at
/// `rowHeight`, so the segments here really do swap 40 for 32.
public enum TableDensity: String, CaseIterable, Identifiable, Sendable {
    case regular, compact

    /// The one key. Named here because this screen owns the setting.
    public static let storageKey = "app.tableDensity"

    public var id: String { rawValue }
    var labelKey: String { "settings.density.\(rawValue)" }

    /// Switches the row height between 40 and 32.
    public var rowHeight: CGFloat { self == .compact ? Metric.rowCompact : Metric.row }
}

/// Layout of the menu-bar widget.
///
/// More than the three basic layouts, because at the menu bar's real 22pt the
/// stacked layout leaves each tier about 9pt and the digits stop being
/// readable. The raw values are stored preferences, so they must not be
/// renamed.
public enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    /// Just the first metric — "17%".
    case value
    /// Every pinned metric, space-separated — "46° 17%".
    case inline
    /// Every pinned metric, separated by a middle dot — "17% · 58%".
    case dotted
    /// A dimmed caption before the value — "CPU 17%".
    case labeled
    /// Two tiers inside the width of one value.
    case stack
    /// A sparkline of the last minute, then the value.
    case graph
    /// A vertical gauge left of the value.
    case gauge
    /// One micro-bar per logical core, then the total.
    case cores

    public static let storageKey = "app.menuBarStyle"

    public var id: String { rawValue }
    var labelKey: String { "settings.menubar.style.\(rawValue)" }

    /// Layouts that draw only the first pinned metric. The rest lay out every
    /// pinned metric side by side.
    var showsSingleMetric: Bool {
        switch self {
        case .value, .labeled, .graph, .cores: return true
        case .inline, .dotted, .stack, .gauge: return false
        }
    }
}

/// The Monitor's "external address" row — the app's only outbound request, and
/// the reason this switch exists at all: a lookup that contacts a third-party
/// server must be possible to switch off.
///
/// **Default off.** `@AppStorage` reads a missing key as `false`, so a fresh
/// install asks nothing of the network until the user turns this on, and the
/// Monitor row honestly reads "—" until then. Named here because Settings owns
/// the preference; `MonitorView` binds the same key to decide whether to look
/// the address up at all.
public enum ExternalIPLookup {
    public static let storageKey = "app.externalIpLookup"
}

// MARK: - Screen

public struct SettingsView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var loginItems = LoginItemsManager.shared
    @ObservedObject private var history = CleanupHistory.shared
    @ObservedObject private var cleanup = AppState.shared.dashboardViewModel

    // These survive a relaunch (the menu-bar style lives in `MenuBarCard`).
    @AppStorage(TableDensity.storageKey) private var density: TableDensity = .regular

    @AppStorage(StorageBackgroundDecision.enabledKey) private var dailyStorageMeasurement = true
    @AppStorage(MonitorAlerts.enabledKey) private var alertsEnabled = false
    @AppStorage(NotificationManager.lowDiskEnabledKey) private var lowDiskAlertsEnabled = false
    @AppStorage(MonitorAlerts.cpuEnabledKey) private var alertCPUOn = true
    @AppStorage(MonitorAlerts.cpuThresholdKey) private var alertCPUThreshold = 90.0
    @AppStorage(MonitorAlerts.tempEnabledKey) private var alertTempOn = true
    @AppStorage(MonitorAlerts.tempThresholdKey) private var alertTempThreshold = 85.0
    @AppStorage(MonitorAlerts.pressureEnabledKey) private var alertPressureOn = true

    /// Off on a fresh install — see `ExternalIPLookup`.
    @AppStorage(ExternalIPLookup.storageKey) private var externalIPEnabled = false

    // Both irreversible operations are confirmed: run on the click, they would
    // erase the size cache or the cleanup journal before the user could read the
    // button they had just pressed.
    @State private var showResetCachesConfirm = false
    @State private var showClearHistoryConfirm = false

    public init() {}

    public var body: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("settings.title"), subtitle: subtitle)
            column
        }
        .background(Palette.background)
        // The status can change outside the app (System Settings → Login Items),
        // so re-read it whenever this screen comes back into view.
        .onAppear { loginItems.refresh() }
        .confirmationDialog(
            loc.s("settings.resetCaches.confirmTitle"),
            isPresented: $showResetCachesConfirm, titleVisibility: .visible
        ) {
            Button(loc.s("settings.action.reset"), role: .destructive) { resetCaches() }
            Button(loc.s("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc.s("settings.resetCaches.desc"))
        }
        .confirmationDialog(
            loc.s("settings.clearHistory.confirmTitle"),
            isPresented: $showClearHistoryConfirm, titleVisibility: .visible
        ) {
            Button(loc.s("common.clear"), role: .destructive) { history.clear() }
            Button(loc.s("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc.s("settings.clearHistory.confirmMsg"))
        }
    }

    private var subtitle: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else { return loc.s("settings.subtitle") }
        return loc.s("settings.subtitle") + " · " + loc.f("settings.versionFmt", version)
    }

    // MARK: The 620pt column

    private var column: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.cardGap) {
                launchCard.staggeredAppear(index: 0)
                alertsCard.staggeredAppear(index: 1)
                if alertsEnabled { thresholdsCard }
                lowDiskAlertsCard
                SettingToggleCard(title: loc.s("settings.dailyStorage.title"),
                                  detail: loc.s("settings.dailyStorage.detail"),
                                  isOn: dailyStorageMeasurement,
                                  toggle: { dailyStorageMeasurement.toggle() })
                externalIPCard.staggeredAppear(index: 2)
                MenuBarCard().staggeredAppear(index: 3)
                densityCard.staggeredAppear(index: 4)
                appearanceCard.staggeredAppear(index: 5)
                exclusionsCard
                maintenanceCard.staggeredAppear(index: 6)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The cards carry a 1pt shadow; without this the last one is clipped
            // flat against the bottom of the scroll view.
            .padding(.bottom, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private var exclusionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: loc.s("cleanup.exclusions"))
            VStack(alignment: .leading, spacing: 8) {
                if cleanup.excludedPaths.isEmpty {
                    Text(loc.s("cleanup.exclusionsHint")).foregroundStyle(Palette.textSecondary)
                }
                ForEach(cleanup.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path).truncationMode(.middle).lineLimit(1).help(path)
                        Spacer()
                        Button(loc.s("cleanup.removeExclusion")) { cleanup.removeExclusion(path) }
                            .buttonStyle(.secondaryAction)
                            .disabled(cleanup.isCleaning)
                    }
                }
            }
            .font(Typo.secondary)
            .padding(Metric.inset)
        }
        .card()
    }

    // MARK: Three switches

    /// CleanAppCache's *own* autostart, and the only switch here whose state
    /// lives outside the app — `SMAppService` can park it in "requires
    /// approval", which the detail line and the accessory button both say.
    @ViewBuilder
    private var launchCard: some View {
        if loginItems.isTranslocated {
            // Launched straight from the DMG, the app runs from Gatekeeper's
            // randomized read-only mount and `register()` can only throw — a
            // toggle here would flip back with no explanation. Say why, and
            // open the folder the fix happens in.
            translocatedLaunchCard
        } else {
            SettingToggleCard(
                title: loc.s("loginitems.launchTitle"),
                detail: launchDetail,
                isOn: loginItems.isEnabled,
                toggle: {
                    // A refused registration otherwise only flips the switch
                    // back, which reads as a mis-click.
                    if !loginItems.setEnabled(!loginItems.isEnabled) {
                        ToastCenter.shared.error(loc.s("settings.loginItemFailed"))
                    }
                }
            ) {
                switch loginItems.status {
                case .requiresApproval:
                    Button(loc.s("settings.action.grant")) { openLoginItemsSettings() }
                        .buttonStyle(WarningButtonStyle(height: 26))
                case .notFound:
                    Button(loc.s("common.retry")) { loginItems.refresh() }
                        .buttonStyle(SecondaryButtonStyle(height: 26))
                default:
                    EmptyView()
                }
            }
        }
    }

    /// The launch card's translocated state: same geometry as
    /// `SettingToggleCard`, no switch — there is nothing the switch could do.
    private var translocatedLaunchCard: some View {
        HStack(spacing: Metric.colGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.s("loginitems.launchTitle"))
                    .font(Typo.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(loc.s("loginitems.status.translocated"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(loc.s("settings.action.showApplications")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            }
            .buttonStyle(WarningButtonStyle(height: 26))
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised)
        .card()
        .accessibilityElement(children: .contain)
    }

    private var launchDetail: String {
        switch loginItems.status {
        case .requiresApproval: return loc.s("loginitems.status.requiresApproval")
        case .notFound:         return loc.s("loginitems.status.notFound")
        default:                return loc.s("loginitems.launchSubtitle")
        }
    }

    private var alertsCard: some View {
        SettingToggleCard(title: loc.s("settings.alerts.enable"),
                          detail: loc.s("settings.alerts.desc"),
                          isOn: alertsEnabled) {
            alertsEnabled.toggle()
            if alertsEnabled { NotificationManager.shared.requestAuthorization() }
        }
    }

    private var lowDiskAlertsCard: some View {
        SettingToggleCard(title: loc.s("settings.lowDisk.enable"),
                          detail: loc.s("settings.lowDisk.desc"),
                          isOn: lowDiskAlertsEnabled) {
            lowDiskAlertsEnabled.toggle()
            if lowDiskAlertsEnabled { NotificationManager.shared.requestAuthorization() }
        }
    }

    /// The switch behind the Monitor's "external address" row. Its detail line is not a
    /// feature description but a disclosure: this is the one thing in the app
    /// that talks to the network, and turning it on is how it starts. Nothing
    /// happens on the flip itself — the Monitor asks only while the panel that
    /// shows the answer is open.
    private var externalIPCard: some View {
        SettingToggleCard(title: loc.s("settings.externalIp"),
                          detail: loc.s("settings.externalIp.desc"),
                          isOn: externalIPEnabled) {
            externalIPEnabled.toggle()
        }
    }

    // MARK: Table density

    private var densityCard: some View {
        HStack(spacing: Metric.colGap) {
            SettingsCardCaption(loc.s("settings.density"), detail: loc.s("settings.density.desc"))
            SegmentedControl(selection: $density,
                             options: TableDensity.allCases.map {
                                 SegmentOption(value: $0, label: loc.s($0.labelKey))
                             },
                             height: Metric.chip)
                .fixedSize()
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Appearance — theme and language

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: loc.s("settings.section.appearance"))

            VStack(alignment: .leading, spacing: 9) {
                Text(loc.s("settings.theme"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                HStack(spacing: 8) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeSwatch(theme: theme,
                                    selected: themeManager.theme == theme,
                                    name: loc.s(theme.labelKey),
                                    accessibility: loc.f("settings.chooseFmt", loc.s(theme.labelKey))) {
                            withAnimation(Motion.tabSwitch) { themeManager.theme = theme }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, Metric.inset)
            .padding(.vertical, 14)

            Rectangle().fill(Palette.borderHairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(loc.s("settings.language"))
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.textSecondary)
                    Text(loc.s("settings.language.desc"))
                        .font(Typo.footnote)
                        .foregroundStyle(Palette.textTertiary)
                }
                SegmentedControl(selection: $loc.language,
                                 options: Localizer.Language.allCases.map {
                                     SegmentOption(value: $0, label: loc.s($0.labelKey))
                                 },
                                 height: Metric.chip)
                    .fixedSize()
            }
            .padding(.horizontal, Metric.inset)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Alert thresholds

    /// Column widths for the two threshold rows and the pressure row — one spec,
    /// so the checkbox, the name and the value cannot drift between them.
    /// No titles, so nothing in it depends on the language and it is built once.
    private static let thresholdSpec = TableSpec([
        TableCol("check", width: Metric.checkboxGlyph),
        TableCol("name"),
        TableCol("value", width: 64, alignment: .trailing),
    ])

    private var thresholdsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: loc.s("settings.alerts"))

            thresholdRow(title: loc.s("settings.alerts.cpuLabel"),
                         value: Fmt.percent(alertCPUThreshold, decimals: 0),
                         accessibility: loc.f("settings.alerts.cpuFmt", Int(alertCPUThreshold)),
                         isOn: alertCPUOn) { alertCPUOn.toggle() }
            sliderStrip(value: $alertCPUThreshold, range: 50...100, step: 5,
                        enabled: alertCPUOn,
                        accessibility: loc.f("settings.alerts.cpuFmt", Int(alertCPUThreshold)))

            thresholdRow(title: loc.s("settings.alerts.tempLabel"),
                         value: celsius(alertTempThreshold),
                         accessibility: loc.f("settings.alerts.tempFmt", Int(alertTempThreshold)),
                         isOn: alertTempOn) { alertTempOn.toggle() }
            sliderStrip(value: $alertTempThreshold, range: 60...105, step: 5,
                        enabled: alertTempOn,
                        accessibility: loc.f("settings.alerts.tempFmt", Int(alertTempThreshold)))

            TableRow(spec: Self.thresholdSpec,
                     isSelected: alertPressureOn,
                     showsDivider: false,
                     accessibility: loc.s("settings.alerts.pressure"),
                     action: { alertPressureOn.toggle() }) {
                RowCheckbox(isOn: alertPressureOn)
                    .column(Self.thresholdSpec, "check")
                Text(loc.s("settings.alerts.pressure"))
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .column(Self.thresholdSpec, "name")
                // Memory pressure is a kernel signal, not a number the user sets;
                // the column stays empty rather than inventing a threshold.
                Color.clear
                    .frame(height: 0)
                    .column(Self.thresholdSpec, "value")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func thresholdRow(title: String, value: String, accessibility: String,
                              isOn: Bool, toggle: @escaping () -> Void) -> some View {
        TableRow(spec: Self.thresholdSpec,
                 isSelected: isOn,
                 showsDivider: false,
                 accessibility: accessibility,
                 action: toggle) {
            RowCheckbox(isOn: isOn)
                .column(Self.thresholdSpec, "check")
            Text(title)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .column(Self.thresholdSpec, "name")
            Text(value)
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(isOn ? Palette.textPrimary : Palette.textTertiary)
                .lineLimit(1)
                .column(Self.thresholdSpec, "value")
        }
    }

    /// The range bounds are printed under the slider: without them the handle
    /// position means nothing — 90 °C looks like the top of the scale.
    private func sliderStrip(value: Binding<Double>, range: ClosedRange<Double>,
                             step: Double, enabled: Bool,
                             accessibility: String) -> some View {
        VStack(spacing: 3) {
            Slider(value: value, in: range, step: step)
                .tint(Palette.accent)
                .disabled(!enabled)
                .accessibilityLabel(Text(accessibility))
            HStack(spacing: 8) {
                Text(Fmt.count(Int(range.lowerBound)))
                Spacer(minLength: 8)
                Text(Fmt.count(Int(range.upperBound)))
            }
            .font(Typo.numeric(10, weight: .regular))
            .foregroundStyle(Palette.textTertiary)
        }
        .opacity(enabled ? 1 : 0.45)
        .padding(.horizontal, Metric.inset)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private func celsius(_ value: Double) -> String {
        Fmt.decimal(value, decimals: 0) + " " + loc.s("unit.celsius")
    }

    // MARK: Maintenance

    private static let maintenanceSpec = TableSpec([
        TableCol("item"),
        TableCol("action", width: 96, alignment: .trailing),
    ])

    private var maintenanceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: loc.s("settings.maintenance"))

            maintenanceRow(title: loc.s("settings.resetCaches"),
                           detail: loc.s("settings.resetCaches.short"),
                           accessibility: loc.s("settings.resetCaches"),
                           action: { showResetCachesConfirm = true }) {
                Button(loc.s("settings.action.reset")) { showResetCachesConfirm = true }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
            }

            maintenanceRow(title: loc.s("history.title"),
                           detail: loc.f("settings.history.statsFmt",
                                         Fmt.plural("plural.cleanups", history.records.count),
                                         history.formattedTotalFreed),
                           accessibility: loc.s("history.clear"),
                           action: { if !history.records.isEmpty { showClearHistoryConfirm = true } }) {
                Button(loc.s("common.clear")) { showClearHistoryConfirm = true }
                    .buttonStyle(DangerButtonStyle(height: 26))
                    .disabled(history.records.isEmpty)
            }

            maintenanceRow(title: loc.s("settings.openLogs"),
                           detail: "~/Library/Logs/CleanAppCache",
                           detailIsPath: true,
                           accessibility: loc.s("settings.openLogs"),
                           action: { openLogs() }) {
                Button(loc.s("common.open")) { openLogs() }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
            }

            TableFootnoteRow(text: loc.s("settings.maintenance.irreversible"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func maintenanceRow<Action: View>(title: String, detail: String,
                                              detailIsPath: Bool = false,
                                              accessibility: String,
                                              action: @escaping () -> Void,
                                              @ViewBuilder button: () -> Action) -> some View {
        let spec = Self.maintenanceSpec
        return TableRow(spec: spec,
                        height: Metric.rowDetailed,
                        accessibility: accessibility,
                        action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typo.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(detailIsPath ? Typo.numeric(11, weight: .regular) : Typo.secondary)
                    .foregroundStyle(detailIsPath ? Palette.textTertiary : Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .column(spec, "item")

            button().column(spec, "action")
        }
    }

    // MARK: Plumbing

    private func resetCaches() {
        // The log clears first: the deletions below record their failures
        // there, and clearing afterwards would wipe the only diagnostic behind
        // the failure toast.
        Log.clear()
        AppState.shared.storageViewModel.clearCache()
        // Both of these hold file *names* from the user's Trash and Downloads,
        // so "reset caches" has to reach them too — and a locked or
        // re-permissioned file failing to unlink must not be toasted as
        // success while the inventory stays on disk.
        let scanOK = AppState.shared.dashboardViewModel.clearScanCache()
        Task {
            let diskOK = await DiskCacheManager.shared.clear()
            await StorageManager.shared.invalidateAll()
            if scanOK && diskOK {
                ToastCenter.shared.success(loc.s("settings.resetCaches.done"))
            } else {
                ToastCenter.shared.error(loc.s("settings.resetCaches.failed"))
            }
        }
    }

    private func openLogs() {
        let fm = FileManager.default
        guard let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let dir = lib.appendingPathComponent("Logs/CleanAppCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.Extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The 13/600 caption that opens a card, with its 12pt description.
}

/// Card title over an optional one-line description.
private struct SettingsCardCaption: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Menu-bar metrics, style and live preview
//
// Its own view so that it alone observes `MenuBarController`. As part of
// `SettingsView` the controller's 5 s tick would re-run the whole Settings body —
// nine `MenuBarLabelRenderer.image` calls and every other card with them.

private struct MenuBarCard: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var menuBar = MenuBarController.shared
    @AppStorage(MenuBarStyle.storageKey) private var menubarStyle: MenuBarStyle = .stack
    /// The Settings window can outlive its closing; the nine label images
    /// are drawn only while it is on screen, not on every tick for nobody.
    @State private var onScreen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCardCaption(loc.s("settings.menubar.metrics"),
                                detail: loc.s("settings.menubar.metrics.desc"))
            metricChips
            if onScreen {
                styleRow
                preview
            }
        }
        .onWindowVisibilityChange { onScreen = $0 }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Three per row: five chips at their Russian length do not fit 584pt, and a
    /// wrap that depends on measurement would reflow between languages.
    private var metricChips: some View {
        let all = MenuBarMetric.allCases
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: all.count, by: 3)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(all[start..<min(start + 3, all.count)]) { metric in
                        Chip(loc.s(metric.labelKey), isOn: menuBar.isOn(metric)) {
                            menuBar.toggle(metric)
                        }
                        .disabled(!menuBar.isAvailable(metric))
                        .opacity(menuBar.isAvailable(metric) ? 1 : 0.45)
                        .accessibilityLabel(Text(loc.f("menubar.toggleFmt", loc.s(metric.labelKey))))
                    }
                    Spacer(minLength: 0)
                }
            }
            // `toggle` silently refuses to unpin the last metric, and refuses a
            // sensor this Mac does not have. Saying so is the difference between
            // a rule and a click that does nothing.
            Text(loc.s("menubar.atLeastOne"))
                .font(Typo.footnote)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !menuBar.isAvailable(.gpuTemp) {
                Text(loc.s("menubar.gpuTempUnavailable"))
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Eight layouts do not fit a segmented control, and a list of names would
    /// make the user try each one to see what it is. Each option renders itself
    /// instead, at the size it will actually be.
    private var styleRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(loc.s("settings.menubar.style"))
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                      spacing: 8) {
                ForEach(MenuBarStyle.allCases) { option in
                    styleOption(option)
                }
            }
        }
        .animation(Motion.content, value: menubarStyle)
    }

    private func styleOption(_ option: MenuBarStyle) -> some View {
        let isOn = menubarStyle == option
        let image = MenuBarLabelRenderer.image(menuBar.labelState(style: option))
        return Button { menubarStyle = option } label: {
            HStack(spacing: 10) {
                // The word beside it is the label; the picture would only
                // repeat the live readings.
                Image(nsImage: image)
                    .renderingMode(.template)
                    .foregroundStyle(isOn ? Palette.accentText : Palette.textPrimary)
                    .frame(width: 74, alignment: .leading)
                    .accessibilityHidden(true)
                Text(loc.s(option.labelKey))
                    .font(Typo.secondary)
                    .foregroundStyle(isOn ? Palette.accentText : Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                    .fill(isOn ? Palette.accentTint : Palette.surfaceControl)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                    .strokeBorder(isOn ? Palette.accentBorder : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: The preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(loc.s("settings.menubar.preview"))
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)

            VStack(spacing: 0) {
                menuBarStrip
                Text(styleHint)
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Palette.surfaceRaised)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                    .strokeBorder(Palette.borderStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Metric.control, style: .continuous))
        }
    }

    private var menuBarStrip: some View {
        HStack(spacing: 12) {
            Monogram(size: 12)
            Text(loc.s("app.name"))
                .font(Typo.text(11, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            widget
            // The system's own items, drawn so the widget has neighbours to sit
            // between. They are chrome, not readings — the app measures neither
            // Wi-Fi nor the battery.
            Image(systemName: "wifi")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
            Image(systemName: "battery.100")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
            Text(Fmt.clock(Date()))
                .font(Typo.numeric(11, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Palette.surfaceFooter)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderHairline).frame(height: 1)
        }
    }

    /// The widget, drawn by the very code that draws the status item.
    ///
    /// A separate SwiftUI re-implementation would make "a live preview of the
    /// real menu-bar item" a promise the preview could quietly break — every new
    /// layout would have to be drawn twice. Rendering the same `NSImage` means
    /// the preview cannot be wrong.
    @ViewBuilder
    private var widget: some View {
        let image = MenuBarLabelRenderer.image(menuBar.labelState(style: menubarStyle))
        if image.size.width > 1 {
            Image(nsImage: image)
                .renderingMode(.template)
                .accessibilityLabel(Text(image.accessibilityDescription ?? ""))
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Metric.checkboxRadius, style: .continuous)
                        .fill(Palette.accentTint)
                )
                .animation(Motion.content, value: menubarStyle)
        }
    }

    private var styleHint: String {
        // The stacked layout pairs a load with its temperature when both are
        // pinned, so it has two hints; every other layout has one.
        if menubarStyle == .stack {
            let paired = (menuBar.isOn(.cpuLoad) && menuBar.isOn(.cpuTemp))
                || (menuBar.isOn(.gpuLoad) && menuBar.isOn(.gpuTemp))
            return loc.s(paired ? "settings.menubar.hint.stackTemp" : "settings.menubar.hint.stack")
        }
        return loc.s("settings.menubar.hint.\(menubarStyle.rawValue)")
    }
}

// MARK: - Switch card
//
// `15 18` padding, a 13/600 name over a 12pt consequence, and the 40×24 switch
// on the right. The whole card is the hit area — the switch alone is a 40pt
// target on a 620pt row — while `AppToggle` stays a real control so keyboard and
// VoiceOver reach it directly.

private struct SettingToggleCard<Accessory: View>: View {
    let title: String
    let detail: String
    let isOn: Bool
    let toggle: () -> Void
    @ViewBuilder let accessory: Accessory

    @State private var hovered = false

    init(title: String, detail: String, isOn: Bool,
         toggle: @escaping () -> Void,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.isOn = isOn
        self.toggle = toggle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Metric.colGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typo.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            accessory

            AppToggle(isOn: Binding(get: { isOn }, set: { _ in toggle() }), label: title)
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Palette.selectedRow : Palette.surfaceRaised)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovered = $0 }
        .animation(Motion.rowHover, value: hovered)
        .card()
        .accessibilityElement(children: .contain)
    }
}

extension SettingToggleCard where Accessory == EmptyView {
    init(title: String, detail: String, isOn: Bool, toggle: @escaping () -> Void) {
        self.init(title: title, detail: detail, isOn: isOn, toggle: toggle) { EmptyView() }
    }
}

// MARK: - Theme swatch
//
// A 26pt band of the theme's own ground with two 9×9 accent squares, its name
// underneath, and `accentBorder` when chosen. Only two themes: the palette is
// closed, and each extra theme would mean inventing forty colours of its own.

private struct ThemeSwatch: View {
    let theme: AppTheme
    let selected: Bool
    let name: String
    let accessibility: String
    let action: () -> Void

    @State private var hovered = false

    init(theme: AppTheme, selected: Bool, name: String, accessibility: String,
         action: @escaping () -> Void) {
        self.theme = theme
        self.selected = selected
        self.name = name
        self.accessibility = accessibility
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(theme.background)
                        .frame(height: 26)
                    HStack(spacing: 3) {
                        Rectangle().fill(theme.accent).frame(width: 9, height: 9)
                        Rectangle().fill(theme.accent2).frame(width: 9, height: 9)
                    }
                    .padding(5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Metric.segment, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.segment, style: .continuous)
                        .strokeBorder(Palette.borderHairline, lineWidth: 1)
                )

                Text(name)
                    .font(Typo.text(12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.accentText : Palette.textSecondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(width: 132, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                    .fill(selected ? Palette.accentTint : (hovered ? Palette.selectedRow : Palette.surfaceRaised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                    .strokeBorder(selected ? Palette.accentBorder : Palette.borderStrong, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.rowHover, value: hovered)
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
