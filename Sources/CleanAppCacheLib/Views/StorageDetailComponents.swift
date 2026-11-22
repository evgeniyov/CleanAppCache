import SwiftUI

enum DetailFormat {
    static func percent(_ fraction: Double, decimals: Int, locale: Locale) -> String {
        String(format: "%.\(decimals)f%%", locale: locale, fraction * 100)
    }
}

extension StorageItemDetail {
    var storageSizeText: String {
        sizeKnown ? (isPartial ? "≥ " : "") + formattedSize : Fmt.none
    }

    @MainActor
    func storageName(_ loc: Localizer) -> String {
        guard let volume else { return name }
        let roles = volume.roles.map { loc.opt("storage.apfs.role.\($0)") ?? $0 }.joined(separator: ", ")
        if volume.name.isEmpty { return roles.isEmpty ? name : roles }
        return roles.isEmpty || volume.name == roles ? name : loc.f("storage.apfs.volumeFmt", name, roles)
    }

    var canRevealInStorage: Bool {
        volume == nil && path != "/SystemData" && unavailableReason != "detail.externalVolume"
    }

    var canPreviewInStorage: Bool {
        canRevealInStorage && unavailableReason != "detail.privateMetadata"
    }

    var canBrowseInStorage: Bool {
        isDirectory && canPreviewInStorage && unavailableReason != "detail.alreadyCategorized"
    }
}

struct DetailListRow: View {
    @EnvironmentObject private var loc: Localizer
    let item: StorageItemDetail
    let spec: TableSpec
    let isSelected: Bool
    let isSizing: Bool
    let showPath: Bool
    let onSelect: () -> Void
    let onDrill: () -> Void

    var body: some View {
        let status = item.unavailableReason.map(loc.s) ?? (item.isPartial ? loc.s("detail.partial") : nil)
        return TableRow(spec: spec, isSelected: isSelected, selectionColor: Palette.pickedRow,
                        accessibility: loc.f("detail.a11y.rowFmt", displayName, spokenSize),
                        action: onSelect) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Palette.accentText : Palette.textSecondary)
                .accessibilityHidden(true)
                .column(spec, "icon")

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .truncationMode(.middle)
                if let status {
                    Text(status)
                        .font(Typo.footnote)
                        .foregroundStyle(Palette.warningText)
                }
            }
            .lineLimit(1)
            .column(spec, "name")

            Group {
                if !item.sizeKnown && isSizing && item.unavailableReason == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text(item.storageSizeText)
                        .font(Typo.numeric(12, weight: .regular))
                        .foregroundStyle(item.sizeKnown ? Palette.textPrimary : Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .column(spec, "size")

            Color.clear.column(spec, "open")
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if item.canBrowseInStorage { onDrill() }
        })
        // The disclosure button is a sibling of the selection button so
        // keyboard activation can open a folder without also selecting it.
        .overlay(alignment: .trailing) {
            if item.canBrowseInStorage {
                IconButton("chevron.right", label: loc.f("detail.a11y.openFmt", displayName), action: onDrill)
                    .padding(.trailing, spec.inset)
            }
        }
    }

    private var displayName: String {
        if item.path == "/SystemData" { return loc.s("detail.systemData") }
        if item.volume != nil { return item.storageName(loc) }
        if showPath {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return item.path.hasPrefix(home + "/") ? "~" + item.path.dropFirst(home.count) : item.path
        }
        return item.name
    }

    private var spokenSize: String {
        if let reason = item.unavailableReason { return loc.s(reason) }
        if item.sizeKnown { return item.storageSizeText }
        return loc.s(isSizing ? "detail.scanning" : "risk.unmeasured")
    }

    private var icon: String {
        if item.path == "/SystemData" { return "lock.shield" }
        if item.volume != nil { return "internaldrive.fill" }
        return item.isDirectory ? "folder.fill" : "doc"
    }
}

struct StorageDetailPanel: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: StorageViewModel
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var largeFiles = AppState.shared.largeFilesViewModel
    @ObservedObject private var duplicates = AppState.shared.duplicatesViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CardHeader(title: overviewTitle)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let item = viewModel.selectedDetailItem {
                        itemDetails(item)
                    } else {
                        folderOverview
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metric.inset)
            }
            .frame(maxHeight: .infinity)

            if let item = viewModel.selectedDetailItem {
                itemActions(item)
            } else if !viewModel.isVirtualRoot {
                actionFooter {
                    if !viewModel.isLoadingDetail && viewModel.detailErrorKey == nil {
                        folderSearch(URL(fileURLWithPath: viewModel.currentDetailPath))
                    }
                    Button(loc.s("common.openInFinder")) {
                        viewModel.openInFinder(url: URL(fileURLWithPath: viewModel.currentDetailPath))
                    }
                    .buttonStyle(.secondaryAction)
                }
            }
        }
    }

    private var overviewTitle: String {
        if viewModel.selectedDetailItem != nil { return loc.s("detail.itemDetails") }
        return loc.s(viewModel.isVolumeList ? "storage.apfs.summary" : "detail.folderOverview")
    }

    private var folderName: String {
        if viewModel.isGroupRoot, let group = viewModel.selectedBreakdown { return loc.name(group.name) }
        if viewModel.isVirtualRoot { return loc.s("detail.outsideCategories") }
        if viewModel.currentDetailPath == "/" { return StorageInfo.volumeName }
        if let volume = viewModel.externalVolume, volume.url.path == viewModel.currentDetailPath {
            return volume.name
        }
        return URL(fileURLWithPath: viewModel.currentDetailPath).lastPathComponent
    }

    @ViewBuilder
    private var folderOverview: some View {
        Text(folderName)
            .font(Typo.bodyStrong)
            .foregroundStyle(Palette.textPrimary)
            .textSelection(.enabled)

        if viewModel.isVolumeList {
            note(Fmt.plural("plural.items", viewModel.detailItems.count))
        } else if !viewModel.detailItems.isEmpty {
            let folders = viewModel.detailItems.count(where: \.isDirectory)
            let files = viewModel.detailItems.count - folders
            let counts = [Fmt.plural("plural.folders", folders), Fmt.plural("plural.files", files)]
            note(counts.joined(separator: " · "))
        }
        if viewModel.hasMeasuredEmptyListing {
            Text(Fmt.zeroBytes).figure(Typo.metricFigure)
        } else if viewModel.sizingCount > 0 && viewModel.detailItems.contains(where: {
            $0.sizeKnown && viewModel.contributesToDetailTotal($0)
        }) {
            let size = (viewModel.hasPartialDetail ? "≥ " : "") + Fmt.bytes(viewModel.measuredDetailBytes)
            Text(size).figure(Typo.metricFigure)
            if viewModel.hasPartialDetail {
                note(loc.s("detail.partialSize"))
            }
            if !viewModel.isVirtualRoot && !viewModel.hasPartialDetail, let share = diskShare(viewModel.measuredDetailBytes) {
                note(loc.f("detail.ofDiskFmt", share))
            }
            largestEntries
        } else if !viewModel.detailItems.isEmpty && !viewModel.isBrowserAwaitingMeasurement && !viewModel.isSizingDetail {
            note(loc.s("detail.sizeUnavailable"))
        }
        if viewModel.detailItems.contains(where: \.hasSharedAllocation) {
            note(loc.s("detail.sharedAllocation"))
        }
    }

    @ViewBuilder
    private var largestEntries: some View {
        let entries = viewModel.detailItems
            .filter { $0.sizeKnown && $0.size > 0 && viewModel.contributesToDetailTotal($0) }
            .sorted { $0.size > $1.size }
            .prefix(3)
        if !entries.isEmpty {
            Palette.borderHairline.frame(height: 1)
            Text(loc.s("detail.largestEntries")).microLabel()
            VStack(spacing: 8) {
                ForEach(entries) { item in
                    factRow(item.name, item.storageSizeText)
                }
            }
        }
    }

    @ViewBuilder
    private func itemDetails(_ item: StorageItemDetail) -> some View {
        Text(item.path == "/SystemData" ? loc.s("detail.systemData") : item.storageName(loc))
            .font(Typo.bodyStrong)
            .foregroundStyle(Palette.textPrimary)
            .textSelection(.enabled)

        if item.sizeKnown {
            Text(item.storageSizeText).figure(Typo.metricFigure)
            if let share = diskShare(item.size), !item.isPartial {
                let total = viewModel.measuredDetailBytes
                if viewModel.canCompareDetailSizes, total > 0 {
                    let folderShare = DetailFormat.percent(Double(item.size) / Double(total), decimals: 0, locale: loc.locale)
                    note(loc.f("detail.sharesFmt", folderShare, share))
                } else {
                    note(loc.f("detail.ofDiskFmt", share))
                }
            }
        }
        if let reason = item.unavailableReason {
            note(loc.s(reason), color: Palette.warningText)
        } else if item.isPartial {
            note(loc.s("detail.partialSize"), color: Palette.warningText)
        } else if !item.sizeKnown && viewModel.folderMeasurement == nil && !viewModel.isMeasuringFolder {
            note(loc.s(viewModel.isSizingDetail ? "detail.scanning" :
                        (viewModel.isBrowserAwaitingMeasurement ? "detail.notMeasuredYet" : "detail.sizeUnavailable")))
        }
        if item.hasSharedAllocation {
            note(loc.s("detail.sharedAllocation"))
        }
        ForEach(Array(item.accessIssues.prefix(8).enumerated()), id: \.offset) { _, issue in
            note(loc.s(issue.reasonKey) + "\n" + issue.path, color: Palette.warningText)
                .textSelection(.enabled)
        }

        if let measured = viewModel.folderMeasurement {
            Palette.borderHairline.frame(height: 1)
            Text(loc.s("detail.deepMeasurement")).microLabel()
            if measured.sizeKnown {
                Text(measured.storageSizeText).figure(Typo.metricFigure)
            }
            if let reason = measured.unavailableReason ?? measured.accessIssues.first?.reasonKey {
                note(loc.s(reason), color: Palette.warningText)
            }
        }

        if item.path != "/SystemData" {
            Palette.borderHairline.frame(height: 1)
            VStack(spacing: 8) {
                if let date = item.modified { factRow(loc.s("detail.modified"), loc.date(date)) }
                if let date = item.created { factRow(loc.s("detail.created"), loc.date(date)) }
                if let date = item.accessed { factRow(loc.s("detail.lastOpened"), loc.date(date)) }
            }

            Text(item.path)
                .font(Typo.numeric(11, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func note(_ text: String, color: Color = Palette.textSecondary) -> some View {
        Text(text)
            .font(Typo.footnote)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func diskShare(_ bytes: UInt64) -> String? {
        guard let total = viewModel.storageInfo?.totalBytes, total > 0 else { return nil }
        return DetailFormat.percent(Double(bytes) / Double(total), decimals: 1, locale: loc.locale)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Typo.footnote)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(Typo.numeric(11, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func itemActions(_ item: StorageItemDetail) -> some View {
        if item.canRevealInStorage {
            actionFooter {
                if item.canBrowseInStorage {
                    if item.url.pathExtension.lowercased() == "app" {
                        actionButton(loc.s("detail.openInUninstaller")) {
                            appState.appsViewModel.searchText = item.url.deletingPathExtension().lastPathComponent
                            onClose()
                            appState.open(.apps)
                        }
                    } else {
                        actionButton(loc.s("detail.drillDown")) { viewModel.pushPath(item.path) }
                    }
                } else if item.canPreviewInStorage && !item.isDirectory {
                    actionButton(loc.s("common.quickLook")) { QuickLook.shared.toggle(url: item.url) }
                }
                if item.canBrowseInStorage {
                    folderSearch(item.url)
                    if viewModel.isMeasuringFolder {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Button(loc.s("common.cancel")) { viewModel.cancelFolderMeasurement() }
                                .buttonStyle(.secondaryAction)
                        }
                    } else {
                        Button(loc.s("detail.measureFolder")) { viewModel.measureSelectedFolder() }
                            .buttonStyle(.secondaryAction)
                            .disabled(viewModel.isLoadingDetail || viewModel.isSizingDetail)
                            .help(loc.s("detail.deepMeasurementHelp"))
                    }
                }
                Button(loc.s("common.revealInFinder")) { viewModel.revealInFinder(url: item.url) }
                    .buttonStyle(.secondaryAction)
            }
        }
    }

    private func folderSearch(_ folder: URL) -> some View {
        Menu(loc.s("detail.searchHere")) {
            Button(loc.s("detail.findLargeFilesHere")) {
                largeFiles.setCustomSearchFolder(folder)
                onClose()
                appState.open(.largeFiles)
            }
            .disabled(largeFiles.isDeleting)
            Button(loc.s("detail.findDuplicatesHere")) {
                duplicates.setCustomSearchFolder(folder)
                onClose()
                appState.open(.duplicates)
            }
            .disabled(duplicates.isDeleting)
        }
    }

    private func actionFooter<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8, content: actions)
            .padding(Metric.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceFooter)
            .overlay(alignment: .top) { Palette.borderHairline.frame(height: 1) }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.primaryAction)
    }
}
