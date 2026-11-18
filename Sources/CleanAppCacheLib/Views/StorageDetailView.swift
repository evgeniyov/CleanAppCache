import SwiftUI

public struct StorageDetailView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: StorageViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsScope = false

    public init() {}

    public var body: some View {
        ScreenBody {
            ScreenHeader(title: title, subtitle: subtitle) {
                HStack(spacing: 8) {
                    if viewModel.browserMode != .category {
                        IconButton("info.circle", label: loc.s("detail.aboutSizes")) {
                            showsScope.toggle()
                        }
                        .popover(isPresented: $showsScope, arrowEdge: .bottom) {
                            scope
                        }
                    }
                    IconButton("xmark", label: loc.s("common.close")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            HStack(alignment: .top, spacing: Metric.cardGap) {
                listing
                StorageDetailPanel(onClose: { dismiss() })
                    .frame(width: 280)
                    .card()
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 960, height: 620)
        .background(Palette.background)
        .onDisappear { viewModel.cancelDetailSizing() }
        .onChange(of: viewModel.searchText) { _ in clearHiddenSelection() }
        .onChange(of: viewModel.showOnlyFolders) { _ in clearHiddenSelection() }
    }

    private var title: String {
        switch viewModel.browserMode {
        case .disk: return viewModel.externalVolume?.name ?? loc.s("detail.diskFolders")
        case .unassigned: return loc.s("detail.outsideCategories")
        case .category: return loc.name(viewModel.selectedBreakdown?.name ?? loc.s("detail.contents"))
        }
    }

    private var subtitle: String? {
        var facts: [String] = []
        if let breakdown = viewModel.selectedBreakdown {
            if breakdown.sizeKnown {
                let share = DetailFormat.percent(breakdown.percentOfTotal, decimals: 1, locale: loc.locale)
                let lowerBound = breakdown.isPartial ? "≥ " : ""
                facts.append("\(lowerBound)\(breakdown.formattedSize) · \(lowerBound)\(loc.f("detail.ofDiskFmt", share))")
            } else {
                facts.append(loc.s("storage.unmeasured"))
            }
        }
        if !viewModel.detailItems.isEmpty {
            facts.append(Fmt.plural("plural.items", viewModel.detailItems.count))
        }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.s("detail.aboutSizes"))
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.textPrimary)
            Text(loc.s(viewModel.browserMode == .unassigned ? "detail.unassignedScope" : "detail.diskScope"))
            if viewModel.browserMode == .unassigned {
                Text(loc.s("storage.systemUnmeasured"))
            }
        }
        .font(Typo.secondary)
        .foregroundStyle(Palette.textSecondary)
        .padding(Metric.inset)
        .frame(width: 320, alignment: .leading)
        .background(Palette.surfaceRaised)
    }

    private var spec: TableSpec {
        TableSpec([
            TableCol("icon", width: Metric.tapTarget),
            TableCol("name"),
            TableCol("size", width: 100, alignment: .trailing),
            TableCol("open", width: Metric.tapTarget),
        ])
    }

    private var listing: some View {
        let spec = self.spec
        return VStack(spacing: 0) {
            toolbar
            listBody(spec)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.isSizingDetail || !viewModel.detailItems.isEmpty || viewModel.canMeasureBrowserListing {
                measurementFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    private func columnHeaders(_ spec: TableSpec) -> some View {
        TableHeader(spec, customKeys: ["name", "size"]) { key in
            if key == "name" {
                SortableHeader(title: loc.s("apps.sort.name"),
                               isActive: isSortingByName, ascending: viewModel.sortMode == .nameAsc) {
                    viewModel.sortMode = viewModel.sortMode == .nameAsc ? .nameDesc : .nameAsc
                }
            } else {
                SortableHeader(title: loc.s("storage.col.size"),
                               isActive: !isSortingByName, ascending: viewModel.sortMode == .sizeAsc,
                               alignment: .trailing) {
                    viewModel.sortMode = viewModel.sortMode == .sizeDesc ? .sizeAsc : .sizeDesc
                }
            }
        }
        .background(Palette.surfaceRaised)
    }

    private var isSortingByName: Bool {
        viewModel.sortMode == .nameAsc || viewModel.sortMode == .nameDesc
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            IconButton("chevron.left", label: loc.s("common.back"), disabled: !viewModel.canGoBack) {
                viewModel.popPath()
            }
            breadcrumbs
            SearchField(text: $viewModel.searchText, placeholder: loc.s("detail.search"), width: 140)
            IconButton(viewModel.showOnlyFolders ? "folder.fill" : "folder",
                       label: loc.s("detail.foldersOnly"),
                       tone: viewModel.showOnlyFolders ? .info : nil) {
                viewModel.showOnlyFolders.toggle()
            }
            .accessibilityAddTraits(viewModel.showOnlyFolders ? .isSelected : [])
            RefreshButton(label: loc.s("common.rescan.tooltip")) {
                viewModel.reloadCurrentDetail()
            }
        }
        .padding(.horizontal, Metric.inset)
        .frame(height: Metric.utilityStrip)
        .background(Palette.surfaceFooter)
        .overlay(alignment: .bottom) { Palette.borderHairline.frame(height: 1) }
    }

    private var breadcrumbs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(viewModel.detailPathStack.enumerated()), id: \.offset) { index, path in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Palette.textTertiary)
                                .accessibilityHidden(true)
                        }
                        if index == viewModel.detailPathStack.count - 1 {
                            Text(pathLabel(path))
                                .foregroundStyle(Palette.textPrimary)
                                .help(path.isEmpty ? pathLabel(path) : path)
                                .id("current")
                        } else {
                            Button(pathLabel(path)) { viewModel.popToDetailPath(index) }
                                .buttonStyle(.plain)
                                .foregroundStyle(Palette.accentText)
                                .help(path.isEmpty ? pathLabel(path) : path)
                        }
                    }
                }
                .font(Typo.secondary)
                .lineLimit(1)
            }
            .onAppear { proxy.scrollTo("current", anchor: .trailing) }
            .onChange(of: viewModel.currentDetailPath) { _ in
                proxy.scrollTo("current", anchor: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pathLabel(_ path: String) -> String {
        if path.isEmpty { return loc.s("detail.outsideCategories") }
        if path == "/" { return StorageInfo.volumeName }
        if let volume = viewModel.externalVolume, volume.url.path == path { return volume.name }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var measurementFooter: some View {
        HStack(spacing: 8) {
            if viewModel.isSizingDetail {
                ProgressView().controlSize(.small)
                Text(loc.f("detail.sizingProgressFmt", viewModel.sizingCount, viewModel.sizingTotal))
            } else {
                Text(measurementStatus)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if viewModel.isSizingDetail {
                Button(loc.s("common.cancel")) { viewModel.cancelDetailSizing() }
                    .buttonStyle(.secondaryAction(height: Metric.tapTarget))
            } else if viewModel.canMeasureBrowserListing {
                Button(loc.s("detail.measureFolders")) { viewModel.measureBrowserListing() }
                    .buttonStyle(.secondaryAction(height: Metric.tapTarget))
                    .help(loc.s("detail.scanBudget"))
            }
        }
        .font(Typo.footnote)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 8)
        .frame(minHeight: Metric.utilityStrip)
        .background(Palette.surfaceFooter)
        .overlay(alignment: .top) { Palette.borderHairline.frame(height: 1) }
    }

    private var measurementStatus: String {
        if viewModel.isDetailSnapshotStale {
            if let date = viewModel.detailMeasuredAt {
                return loc.f("detail.savedAtFmt", loc.date(date) + " " + Fmt.clock(date))
            }
            return loc.s("detail.staleListing")
        }
        if viewModel.isBrowserAwaitingMeasurement {
            return loc.s(viewModel.currentDetailPath == "/" ? "detail.openSubfolder" : "detail.notMeasuredYet")
        }
        if viewModel.detailScanLimited || viewModel.hasPartialDetail {
            return loc.f("detail.coverageFmt", viewModel.sizingCount, viewModel.detailItems.count,
                         viewModel.pendingDetailCount, viewModel.blockedDetailCount)
        }
        if let date = viewModel.detailMeasuredAt {
            return loc.f("detail.measuredAtFmt", loc.date(date) + " " + Fmt.clock(date))
        }
        return loc.f("detail.sizingProgressFmt", viewModel.sizingCount, viewModel.detailItems.count)
    }

    @ViewBuilder
    private func listBody(_ spec: TableSpec) -> some View {
        let items = viewModel.filteredDetailItems
        if viewModel.isLoadingDetail && viewModel.detailItems.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text(loc.s("detail.scanning"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                Button(loc.s("common.cancel")) { viewModel.cancelDetailSizing() }
                    .buttonStyle(.secondaryAction)
            }
        } else if let error = viewModel.detailErrorKey {
            StateView(.failure(path: viewModel.currentDetailPath, code: loc.s(error),
                               retry: { viewModel.reloadCurrentDetail() }))
        } else if viewModel.detailItems.isEmpty {
            Text(loc.s("detail.noItems"))
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
        } else if items.isEmpty {
            let query = viewModel.searchText.isEmpty ? loc.s("detail.foldersOnly") : viewModel.searchText
            StateView(.filterEmpty(total: viewModel.detailItems.count, query: query, reset: resetFilters))
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    // Keep the header in the same width as the rows when
                    // macOS reserves space for a permanent scrollbar.
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(items) { item in
                                row(item, spec: spec)
                            }
                        } header: {
                            columnHeaders(spec)
                        }
                    }
                }
                .id(viewModel.currentDetailPath)
                .quickLookOnSpace(quickLookURL)

                if items.count < viewModel.detailItems.count {
                    TableFootnoteRow(text: loc.f("detail.filteredCountFmt", items.count, viewModel.detailItems.count),
                                     actionTitle: loc.s("state.resetFilter"), action: resetFilters)
                }
            }
        }
    }

    private func row(_ item: StorageItemDetail, spec: TableSpec) -> some View {
        let folder = viewModel.currentDetailPath
        return DetailListRow(item: item,
                      spec: spec,
                      isSelected: viewModel.selectedDetailItem?.id == item.id,
                      isSizing: viewModel.isSizingDetail && !viewModel.contributesToDetailTotal(item),
                      showPath: viewModel.isVirtualRoot,
                      onSelect: {
                          if viewModel.currentDetailPath == folder { viewModel.selectedDetailItem = item }
                      },
                      onDrill: {
                          if viewModel.currentDetailPath == folder { viewModel.pushPath(item.path) }
                      })
            .contextMenu {
                if item.canPreviewInStorage {
                    Button(loc.s("common.quickLook")) { QuickLook.shared.toggle(url: item.url) }
                }
                if item.canBrowseInStorage {
                    Button(loc.s("common.openInFinder")) { viewModel.openInFinder(url: item.url) }
                }
                if item.canRevealInStorage {
                    Button(loc.s("common.revealInFinder")) { viewModel.revealInFinder(url: item.url) }
                }
            }
    }

    private var quickLookURL: URL? {
        guard let item = viewModel.selectedDetailItem, item.canPreviewInStorage else { return nil }
        return item.url
    }

    private func clearHiddenSelection() {
        if let selection = viewModel.selectedDetailItem,
           !viewModel.filteredDetailItems.contains(where: { $0.id == selection.id }) {
            viewModel.selectedDetailItem = nil
        }
    }

    private func resetFilters() {
        viewModel.searchText = ""
        viewModel.showOnlyFolders = false
        viewModel.minSizeMB = 0
    }
}
