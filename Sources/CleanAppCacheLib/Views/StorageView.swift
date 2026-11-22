import SwiftUI

// MARK: - Storage
//
// The screen the app opens on, and the reference layout for the other screens:
// four equal metric cards, a full-width distribution strip, then a table that
// takes the remaining height with a 300pt detail panel beside it.
//
// There is no large hero column. One giant percentage says less than the four
// cards do, and a ~296pt column would cost a third of the width on every window
// size.

public struct StorageView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: StorageViewModel
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var dashboard = AppState.shared.dashboardViewModel
    @ObservedObject private var systemData = AppState.shared.systemDataViewModel

    /// The category whose contents the right-hand panel is showing.
    @State private var picked: UUID?
    @State private var showsFreeSpaceHistory = false
    @State private var lastRefresh: Date?
    @State private var externalVolumes: [StorageVolume] = []
    @State private var selectedVolume: StorageVolume?
    @State private var externalCapacity: StorageInfo?
    @State private var readingExternalCapacity = false
    @State private var volumeRefresh = UUID()
    /// The full drill-down browser, still reachable from the panel.
    private struct BrowserPresentation: Identifiable {
        let id = UUID()
        let viewModel: StorageViewModel
    }
    @State private var browserPresentation: BrowserPresentation?

    /// Columns: swatch 12 | Category | Share 110 | Size 76, right-aligned.
    private var spec: TableSpec {
        TableSpec([
            TableCol("swatch", width: 12),
            TableCol("name", title: loc.s("storage.col.category")),
            TableCol("share", title: loc.s("storage.col.share"), width: 110),
            TableCol("size", title: loc.s("storage.col.size"), width: 76, alignment: .trailing),
        ])
    }

    public init() {}

    public var body: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("storage.title"), subtitle: subtitle) {
                HStack(spacing: 8) {
                    if selectedVolume == nil {
                        Button(loc.s("storage.trend.title")) { showsFreeSpaceHistory = true }
                            .buttonStyle(.secondaryAction)
                    }
                    volumePicker
                }
            }
            if let selectedVolume {
                externalContent(selectedVolume)
            } else {
                content
            }
        }
        .background(Palette.background)
        .onAppear {
            viewModel.loadStorageInfoIfNeeded()
            refreshSummary()
        }
        .task { await FreeSpaceHistory.shared.capture() }
        .task(id: volumeRefresh) { await updateVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumeRefresh = UUID()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumeRefresh = UUID()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            volumeRefresh = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await FreeSpaceHistory.shared.capture() }
        }
        .sheet(isPresented: $showsFreeSpaceHistory) { FreeSpaceHistoryView().environmentObject(loc) }
        .sheet(item: $browserPresentation) { presentation in
            StorageDetailView()
                .environmentObject(presentation.viewModel)
                .environmentObject(loc)
        }
    }

    /// "Macintosh HD · APFS · 11 categories".
    private var subtitle: String? {
        if let selectedVolume { return selectedVolume.url.path }
        guard viewModel.storageInfo != nil else { return nil }
        let count = rows.count
        guard count > 0 else { return nil }
        return loc.f("storage.subtitleFmt",
                     StorageInfo.volumeName,
                     StorageInfo.fileSystemName,
                     Fmt.plural("plural.categories", count))
    }

    private var rows: [StorageBreakdown] {
        viewModel.breakdown.filter { $0.bytes > 0 || !$0.sizeKnown || $0.isPartial }.sorted { $0.bytes > $1.bytes }
    }

    private var volumePicker: some View {
        Menu {
            Button {
                chooseVolume(nil)
            } label: {
                if selectedVolume == nil { Label(loc.s("storage.startupVolume"), systemImage: "checkmark") }
                else { Text(loc.s("storage.startupVolume")) }
            }
            ForEach(externalVolumes, id: \.self) { volume in
                Button {
                    chooseVolume(volume)
                } label: {
                    let title = externalVolumes.count(where: { $0.name == volume.name }) > 1
                        ? volume.url.path : volume.name
                    if selectedVolume == volume { Label(title, systemImage: "checkmark") }
                    else { Text(title) }
                }
            }
        } label: {
            Label(selectedVolume?.name ?? loc.s("storage.startupVolume"), systemImage: "externaldrive")
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityLabel(loc.s("storage.selectVolume"))
    }

    @ViewBuilder
    private func externalContent(_ volume: StorageVolume) -> some View {
        if let capacity = externalCapacity {
            HStack(spacing: Metric.cardGap) {
                MetricCard(caption: loc.s("storage.card.used"), value: Fmt.size(capacity.usedBytes))
                MetricCard(caption: loc.s("storage.card.free"), value: Fmt.size(capacity.freeBytes))
                MetricCard(caption: loc.s("storage.volumeCapacity"), value: Fmt.size(capacity.totalBytes))
            }
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: volume.name) {
                    Button(loc.s("detail.diskFolders")) {
                        browserPresentation = BrowserPresentation(viewModel: viewModel.makeVolumeBrowser(volume, capacity: capacity))
                    }
                    .buttonStyle(.secondaryAction(height: Metric.tapTarget))
                    RefreshStamp(text: nil, label: loc.s("common.rescan.tooltip")) { volumeRefresh = UUID() }
                }
                ShareBar(fraction: capacity.usedPercent, color: Palette.accent)
                    .accessibilityHidden(true)
                    .padding(.horizontal, Metric.inset)
                    .padding(.bottom, Metric.inset)
            }
            .card()
            Spacer(minLength: 0)
        } else if readingExternalCapacity {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            StateView(.failure(path: volume.url.path, code: loc.s("storage.volumeUnavailable"),
                               retry: { volumeRefresh = UUID() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chooseVolume(_ volume: StorageVolume?) {
        guard selectedVolume != volume else { return }
        selectedVolume = volume
        externalCapacity = nil
        readingExternalCapacity = volume != nil
        volumeRefresh = UUID()
    }

    private func updateVolumes() async {
        let volumes = await Task.detached(priority: .utility) { StorageVolume.mountedExternal() }.value
        guard !Task.isCancelled else { return }
        externalVolumes = volumes
        if let browsing = browserPresentation?.viewModel.externalVolume, !volumes.contains(browsing) {
            browserPresentation = nil
        }
        guard let selectedVolume else { return }
        guard volumes.contains(selectedVolume) else {
            chooseVolume(nil)
            return
        }
        let capacity = await Task.detached(priority: .utility) { selectedVolume.readCapacity() }.value
        guard !Task.isCancelled else { return }
        externalCapacity = capacity
        readingExternalCapacity = false
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let info = viewModel.storageInfo {
            cards(info)
            distribution(info)
            tableAndPanel(info)
        } else if viewModel.isLoading {
            StateView(.scanning(percent: 0,
                                category: loc.s("storage.analyzing"),
                                path: "",
                                cancel: nil))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Not a generic "unable to read" error: volume statistics fail for
            // a reason the user can act on, so name it.
            StateView(.noAccess(
                missing: loc.s("storage.unableRead"),
                openSettings: { openPrivacySettings() },
                scanAnyway: { viewModel.reloadStorageInfo() }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Four cards

    private func cards(_ info: StorageInfo) -> some View {
        HStack(spacing: Metric.cardGap) {
            MetricCard(caption: loc.s("storage.card.used"),
                       value: Fmt.size(info.usedBytes))

            MetricCard(caption: loc.s("storage.card.free"),
                       value: Fmt.size(info.freeBytes))

            // Clickable, accent-bordered: it is the one card that leads somewhere
            // the user probably wants to go.
            MetricCard(caption: loc.s("storage.card.cleanable"),
                       value: cleanable,
                       emphasised: true,
                       action: { appState.open(.smartCleanup) })

            MetricCard(caption: loc.s("storage.card.snapshots"),
                       value: snapshots,
                       action: { appState.open(.systemData) })
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshSummary(force: Bool = false) {
        if !dashboard.isScanning && (force || dashboard.scanResult == nil) { dashboard.startScan() }
        if force || !systemData.hasScanned { systemData.scan() }
    }

    private var loadingMetric: Fmt.Value {
        Fmt.Value(number: loc.s("storage.summaryLoading"), unit: nil)
    }

    private var cleanable: Fmt.Value {
        if dashboard.isScanning { return loadingMetric }
        guard dashboard.scanResult != nil else {
            return Fmt.Value(number: Fmt.none, unit: nil)
        }
        return Fmt.size(dashboard.cleanableItems.reduce(0) { $0 &+ $1.size })
    }

    private var snapshots: Fmt.Value {
        if systemData.isScanning || !systemData.hasScanned { return loadingMetric }
        guard !systemData.snapshotsUnreadable else { return Fmt.Value(number: Fmt.none, unit: nil) }
        return Fmt.Value(number: Fmt.count(systemData.snapshots.count), unit: loc.s("storage.snapshotsUnit"))
    }

    // MARK: Distribution

    /// This card is one padded block — title row and strip with
    /// 10pt between them and **no divider** under the title. `CardHeader` would
    /// have added its hairline and a fixed 44pt row, so this is spelled out.
    private func distribution(_ info: StorageInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(loc.s("storage.distribution"))
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                Button(loc.s("detail.diskFolders")) {
                    presentBrowser { $0.openDiskBrowser() }
                }
                .buttonStyle(.secondaryAction(height: Metric.tapTarget))
                RefreshStamp(text: refreshStamp,
                             label: loc.s("common.rescan.tooltip")) {
                    lastRefresh = Date()
                    if !viewModel.isLoading {
                        viewModel.reloadStorageInfo()
                        refreshSummary(force: true)
                    }
                }
            }
            StorageBar(segments: segments(info), total: info.totalBytes, onSelect: selectSegment)
            if viewModel.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc.s("storage.measuringDistribution"))
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button(loc.s("common.cancel")) { viewModel.cancelOverview() }
                        .buttonStyle(.secondaryAction(height: Metric.tapTarget))
                }
            } else if let date = viewModel.storageMeasuredAt {
                Text(loc.f("detail.measuredAtFmt", loc.date(date) + " " + Fmt.clock(date)))
                    .font(Typo.micro).foregroundStyle(Palette.textTertiary)
            }
            if viewModel.breakdown.contains(where: { !$0.reconciled }) {
                Text(loc.s("storage.allocationMismatch"))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textSecondary)
            }
            if viewModel.breakdown.contains(where: { $0.isPartial || !$0.sizeKnown }) {
                Text(loc.s("storage.partialScopes"))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .card()
    }

    private var refreshStamp: String? {
        guard let lastRefresh else { return nil }
        return loc.f("common.updatedAt", Fmt.clock(lastRefresh))
    }

    // MARK: Table + 300pt panel

    private func tableAndPanel(_ info: StorageInfo) -> some View {
        // Once per pass, not once per row: `spec` runs `loc.s()` per column.
        let spec = self.spec
        return HStack(alignment: .top, spacing: Metric.cardGap) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                categoryRow(item, info: info, spec: spec).staggeredAppear(index: index)
                            }
                            if rows.isEmpty && !viewModel.isLoading {
                                Text(loc.s("storage.distributionEmpty"))
                                    .font(Typo.secondary)
                                    .foregroundStyle(Palette.textSecondary)
                                    .frame(maxWidth: .infinity, minHeight: 140)
                            }
                        } header: {
                            TableHeader(spec)
                                .background(Palette.surfaceRaised)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()

            detailPanel(info)
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .card()
        }
        .frame(maxHeight: .infinity)
    }

    private func categoryRow(_ item: StorageBreakdown, info: StorageInfo,
                             spec: TableSpec) -> some View {
        let category = StorageCategory.from(rawName: item.name)
        let isPicked = picked == item.id
        // The share is measured against the largest row, not against the sum.
        let peak = rows.first?.bytes ?? 1
        let size = Fmt.size(item.bytes)

        return TableRow(spec: spec,
                        isSelected: isPicked,
                        selectionColor: Palette.pickedRow,
                        accessibility: loc.name(item.name),
                        action: { pick(item) }) {
            CategorySwatch(color: category.color)
                .column(spec, "swatch")

            Text(loc.name(item.name))
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .column(spec, "name")

            ShareBar(fraction: peak > 0 ? Double(item.bytes) / Double(peak) : 0,
                     color: category.color)
                .column(spec, "share")

            Text(item.sizeKnown ? (item.isPartial && !item.isResidual ? "≥ " : "") + size.joined : Fmt.none)
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .column(spec, "size")
        }
    }

    // MARK: Detail panel

    @ViewBuilder
    private func detailPanel(_ info: StorageInfo) -> some View {
        if let item = rows.first(where: { $0.id == picked }) {
            // 18pt inset all round, 12pt between blocks — the panel is one
            // padded column, not a stack of edge-to-edge strips.
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.name(item.name))
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.sizeKnown ? loc.f("storage.detail.shareFmt",
                           (item.isPartial && !item.isResidual ? "≥ " : "") + item.formattedSize,
                           Fmt.percent(share(item, of: info) * 100, decimals: 0)) : loc.s("storage.unmeasured"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)

                Rectangle().fill(Palette.borderHairline).frame(height: 1)

                if let reason = item.remainderReason {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(loc.f("storage.measuredScopesFmt", Fmt.bytes(viewModel.measuredCategoryBytes)))
                            Text(loc.s(reason == .protected ? "storage.remainderProtected" : "storage.remainderUnmeasured"))
                            ForEach(Array(item.accessIssues.prefix(8).enumerated()), id: \.offset) { _, issue in
                                Text(loc.s(issue.reasonKey) + "\n" + issue.path).textSelection(.enabled)
                            }
                            if let date = viewModel.storageMeasuredAt {
                                Text(loc.f("detail.measuredAtFmt", loc.date(date) + " " + Fmt.clock(date)))
                            }
                        }
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: .infinity)
                    if reason == .protected {
                        Button(loc.s("fda.openSettings")) { FullDiskAccess.openSettings() }
                            .buttonStyle(.primaryAction)
                    }
                } else {
                    contentsList(item)
                    Button(loc.s("storage.open")) { presentBrowser { $0.loadDetail(for: item) } }
                        .buttonStyle(.secondaryAction)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 9) {
                Text(loc.s("storage.pickCategory"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 200)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        }
    }

    private func contentsList(_ category: StorageBreakdown) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !category.path.isEmpty {
                    Text(category.path)
                        .font(Typo.numeric(11, weight: .regular))
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                }
                ForEach(Array(category.accessIssues.prefix(4).enumerated()), id: \.offset) { _, issue in
                    Text(loc.s(issue.reasonKey) + "\n" + issue.path)
                        .foregroundStyle(Palette.warningText)
                        .textSelection(.enabled)
                }
                if viewModel.isDetailSnapshotStale {
                    Text(loc.s("detail.staleListing"))
                        .foregroundStyle(Palette.warningText)
                }
                if viewModel.detailItems.contains(where: \.hasSharedAllocation) {
                    Text(loc.s("detail.sharedAllocation"))
                        .foregroundStyle(Palette.textSecondary)
                }
                if viewModel.isLoadingDetail {
                    ProgressView().controlSize(.small)
                } else if let error = viewModel.detailErrorKey {
                    Text(loc.s(error)).foregroundStyle(Palette.warningText)
                } else if viewModel.detailItems.isEmpty {
                    Text(loc.s("detail.noItems")).foregroundStyle(Palette.textSecondary)
                } else {
                    ForEach(viewModel.filteredDetailItems.prefix(60)) { entry in
                        HStack(spacing: 8) {
                            Text(entry.storageName(loc))
                                .font(Typo.secondary)
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.storageSizeText)
                                .font(Typo.numeric(12, weight: .regular))
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize()
                        }
                        .frame(minHeight: 22)
                    }
                }
            }
            .font(Typo.footnote)
        }
        .frame(maxHeight: .infinity)
    }

    private func share(_ item: StorageBreakdown, of info: StorageInfo) -> Double {
        info.totalBytes > 0 ? Double(item.bytes) / Double(info.totalBytes) : 0
    }

    // MARK: Selection

    private func presentBrowser(_ configure: (StorageViewModel) -> Void) {
        let browser = viewModel.makeDetailBrowser()
        configure(browser)
        // The presentation and its model are one value: the first sheet must
        // never be presented before its contents exist.
        browserPresentation = BrowserPresentation(viewModel: browser)
    }

    private func pick(_ item: StorageBreakdown) {
        picked = item.id
        viewModel.loadDetail(for: item)
    }

    private func selectSegment(_ seg: StorageBarSegment) {
        guard let item = rows.first(where: { $0.id == seg.breakdownID }) else { return }
        pick(item)
    }

    // MARK: Segments

    private func segments(_ info: StorageInfo) -> [StorageBarSegment] {
        let reconciled = !viewModel.isLoading && !rows.isEmpty && !rows.contains { !$0.reconciled }
        var segs = (reconciled ? rows : []).map { item in
            StorageBarSegment(
                name: loc.name(item.name),
                bytes: item.bytes,
                color: StorageCategory.from(rawName: item.name).color,
                breakdownID: item.id
            )
        }
        if !reconciled {
            segs.append(StorageBarSegment(name: loc.s("storage.card.used"), bytes: info.usedBytes,
                                          color: StorageCategory.other.color))
        }
        if info.freeBytes > 0 {
            segs.append(StorageBarSegment(
                name: loc.s("storage.freeSegment"),
                bytes: info.freeBytes,
                color: Palette.freeSegment,
                isFree: true
            ))
        }
        return segs
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Metric card
//
// Caption 12pt secondary, 8pt of air, then a 30/600 monospaced figure with its
// unit one size down. A card that leads somewhere gains an arrow in the caption
// row and lifts to `selectedRow` on hover.

public struct MetricCard: View {
    let caption: String
    let value: Fmt.Value
    let emphasised: Bool
    let action: (() -> Void)?

    @State private var hovered = false

    public init(caption: String, value: Fmt.Value,
                emphasised: Bool = false, action: (() -> Void)? = nil) {
        self.caption = caption
        self.value = value
        self.emphasised = emphasised
        self.action = action
    }

    public var body: some View {
        Group {
            // A card with nothing to open is plain content. Wrapping every card
            // in a disabled `Button` made VoiceOver announce the informational
            // ones as "dimmed button".
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .onHover { hovered = $0 }
        .animation(Motion.rowHover, value: hovered)
        .background(
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .fill(Palette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .strokeBorder(emphasised ? Palette.accentBorder : Palette.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metric.card, style: .continuous))
        .shadow(color: Shadow.cardColor, radius: Shadow.cardRadius, x: 0, y: Shadow.cardY)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if action != nil {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(emphasised ? Palette.accentText : Palette.textTertiary)
                }
            }
            Figure(value.number, unit: value.unit,
                   role: Typo.cardFigure,
                   color: emphasised ? Palette.accentText : Palette.textPrimary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered && action != nil ? Palette.selectedRow : Palette.surfaceRaised)
        .contentShape(Rectangle())
    }
}
