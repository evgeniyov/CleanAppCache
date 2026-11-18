import SwiftUI

// MARK: - System Data, explained (the exception)
//
// This is one of the eight scan sections, and the one that cannot be an adapter
// onto `ScanResultView`. The reason is not cosmetic: every other section has a
// checkbox column and a "Clean selected" button, and this screen can clean
// exactly one of its seven components. Purgeable space, swap, the Spotlight
// index, the system caches and logs are measured here to explain the Finder
// figure, not to be deleted — the caches are cleaned in Smart Cleanup, the rest
// is macOS's to manage. A checkbox on those rows over a clean button would
// promise something nothing behind this screen can do.
//
// So the section keeps its own shape and shares everything else with the other
// sections: one `TableSpec` for the header and the rows, the "What it is"
// context column, the share bar measured against the largest row, `Fmt` for
// every number, and the common idle / scanning / no-access / clean states.
//
// Local Time Machine snapshots — the one thing here that *can* be deleted —
// hang off the component they belong to rather than living in a second card:
// they are that component's contents. Both ways of deleting them go through a
// confirmation and say the deletion is permanent, because `tmutil` does not use
// the Trash.

public struct SystemDataView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: SystemDataViewModel

    /// Snapshot awaiting the delete confirmation — nil means no dialog.
    @State private var pendingDelete: TMSnapshot?
    @State private var showThinConfirm = false
    /// Snapshot whose delete is in flight. `isDeletingSnapshot` is a single
    /// flag, so the row needs its own id to know whose spinner to show.
    @State private var deletingID: String?
    /// Snapshot whose last delete failed — kept on the row until the next try.
    @State private var failedID: String?
    /// Components whose full explanation is open.
    @State private var expanded: Set<SystemDataComponent.Kind> = []
    @State private var showAllSnapshots = false
    /// Probed in `onAppear` and after each scan: `FullDiskAccess.isGranted()`
    /// opens and reads a file, and `body` runs on every expand/collapse.
    @State private var hasFullDiskAccess = true
    /// The view model does not keep a scan timestamp, so `.clean` gets one here.
    @State private var lastScan: Date?

    /// Snapshots shown before the footnote. macOS keeps up to a day of hourly
    /// snapshots; twenty-odd nested rows push the remaining components — the
    /// point of the screen — off the first screenful.
    private let snapshotLimit = 8

    public init() {}

    // MARK: Columns

    private var spec: TableSpec {
        TableSpec([
            TableCol("component", title: loc.s("sysdata.col.component")),
            TableCol("what", title: loc.s("scan.col.what"), width: 210),
            TableCol("share", title: loc.s("scan.col.share"), width: 84),
            TableCol("size", title: loc.s("scan.col.size"), width: 88, alignment: .trailing),
            TableCol("action", title: loc.s("sysdata.col.action"), width: 104, alignment: .trailing),
        ])
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScreenBody {
                ScreenHeader(title: loc.s("sysdata.title"), subtitle: subtitle) { headerActions }
                intro
                // tmutil said "Full Disk Access" on stderr — the one refusal
                // with a fix the user can actually perform, so it gets the
                // standard FDA banner rather than only a seven-second toast.
                if viewModel.snapshotAccessDenied {
                    FullDiskAccessBanner { viewModel.snapshotAccessDenied = false }
                }
                content
            }
            if !viewModel.snapshots.isEmpty { bottomBar }
        }
        .background(Palette.background)
        .onAppear { hasFullDiskAccess = FullDiskAccess.isGranted() }
        .onChange(of: viewModel.isScanning) { _ in
            guard !viewModel.isScanning, viewModel.hasScanned else { return }
            lastScan = Date()
            // Re-probed after every scan: granting access mid-session is the
            // whole point of the `noAccess` state's "Open Settings".
            hasFullDiskAccess = FullDiskAccess.isGranted()
        }
        .onChange(of: viewModel.isDeletingSnapshot) { _ in
            guard !viewModel.isDeletingSnapshot, let id = deletingID else { return }
            // The view model reports a failed delete only through a toast that
            // expires after seven seconds. It removes the snapshot from
            // `snapshots` on success, so anything still in the list is a
            // failure — and that reason stays on the row.
            failedID = viewModel.snapshots.contains { $0.id == id } ? id : nil
            deletingID = nil
        }
        .confirmationDialog(
            pendingDelete.map { loc.f("sysdata.confirmDeleteTitleFmt", viewModel.snapshotDateText($0)) } ?? "",
            isPresented: dialogBinding($pendingDelete), titleVisibility: .visible
        ) {
            if let snapshot = pendingDelete {
                Button(loc.s("sysdata.deleteSnapshot"), role: .destructive) { delete(snapshot) }
            }
            Button(loc.s("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc.s("sysdata.confirmDeleteMsg"))
        }
        .confirmationDialog(
            loc.s("sysdata.thinAll"),
            isPresented: $showThinConfirm, titleVisibility: .visible
        ) {
            // Thinning erases every local snapshot it can reach, so it gets the
            // same confirmation a single delete does. The volume — here a
            // count, since APFS hides snapshot sizes — lives in the button.
            Button(loc.f("sysdata.thinAllFmt", Fmt.count(viewModel.snapshots.count)),
                   role: .destructive) {
                failedID = nil
                viewModel.thinAllSnapshots()
            }
            Button(loc.s("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc.s("sysdata.thinConsequence"))
        }
    }

    /// `confirmationDialog` wants a Bool; the payload lives in an optional.
    private func dialogBinding(_ target: Binding<TMSnapshot?>) -> Binding<Bool> {
        Binding(get: { target.wrappedValue != nil },
                set: { if !$0 { target.wrappedValue = nil } })
    }

    // MARK: Header

    @ViewBuilder
    private var headerActions: some View {
        // While the section is unscanned the action lives in the centre
        // of the empty state and must not be duplicated here.
        if viewModel.hasScanned && !viewModel.isScanning {
            Button(loc.s("common.rescan")) { viewModel.scan() }
                .buttonStyle(.secondaryAction)
        }
    }

    private var subtitle: String? {
        guard viewModel.hasScanned, !viewModel.isScanning,
              !viewModel.components.isEmpty else { return nil }
        return loc.f("scan.subtitleFmt",
                     Fmt.plural("plural.items", viewModel.components.count),
                     Fmt.bytes(totalBytes),
                     loc.s("sysdata.checked"))
    }

    /// Best-effort sum, exactly as the explainer describes it: purgeable space
    /// overlaps the caches it can reclaim, and anything APFS hides counts zero.
    private var totalBytes: UInt64 {
        viewModel.components.reduce(UInt64(0)) { $0 &+ ($1.bytes ?? 0) }
    }

    // MARK: Introduction
    //
    // The one piece of prose the screen cannot do without: it says what the
    // Finder figure is and what of it can actually be deleted here. As a
    // subtitle it was two greyed lines under the title; as a band it is part of
    // the interface and stays visible over every state.

    private var intro: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accentText)
            Text(loc.s("sysdata.explainer"))
                .font(Typo.footnote)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notice(.info)
    }

    // MARK: Body — table or state

    @ViewBuilder
    private var content: some View {
        if viewModel.isScanning && viewModel.components.isEmpty {
            // The view model runs the scan in a detached `Task` and exposes
            // neither progress nor a cancellation token, so the percentage
            // stays at 0 and Cancel has nothing to call.
            StateView(.scanning(percent: 0,
                                category: loc.s("sysdata.scanning"),
                                path: "",
                                cancel: nil))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else if !viewModel.hasScanned {
            StateView(.idle(section: loc.s("sysdata.title"),
                            willFind: loc.s("sysdata.idle"),
                            scan: { viewModel.scan() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else if nothingMeasured && !hasFullDiskAccess {
            // Half of these trees sit behind TCC. With nothing readable and no
            // access, "we found nothing" is a permissions answer, not a clean
            // one, so it must not look like the empty "clean" card.
            StateView(.noAccess(missing: loc.s("fda.subtitle"),
                                openSettings: { FullDiskAccess.openSettings() },
                                scanAnyway: { viewModel.scan() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else if nothingMeasured {
            StateView(.clean(checked: loc.s("sysdata.checked"),
                             lastScan: lastScan,
                             rescan: { viewModel.scan() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else {
            table
        }
    }

    /// Nothing to report: no snapshot to act on and not one component whose
    /// size could be measured. `components` is never literally empty — the
    /// manager always appends the snapshots row — so emptiness is about bytes.
    /// An unreadable snapshot list is NOT "nothing": claiming clean when
    /// tmutil refused to answer would assert from no evidence, so the table
    /// (with its "couldn't read" note) is shown instead.
    private var nothingMeasured: Bool {
        viewModel.snapshots.isEmpty && !viewModel.snapshotsUnreadable &&
            viewModel.components.allSatisfy { ($0.bytes ?? 0) == 0 }
    }

    // MARK: Table

    private var table: some View {
        // Once per pass, not once per row: `spec` runs `loc.s()` per column and
        // `peak` walks every component.
        let spec = self.spec
        let peak = viewModel.components.map { $0.bytes ?? 0 }.max() ?? 0
        return VStack(spacing: 0) {
            TableHeader(spec)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.components.enumerated()),
                            id: \.element.id) { index, component in
                        componentRow(component, spec: spec, peak: peak)
                            .staggeredAppear(index: index)

                        if expanded.contains(component.kind) {
                            explanation(component)
                        }
                        // Snapshots are this component's contents, so they hang
                        // off its row instead of a second card.
                        if component.kind == .snapshots {
                            snapshotRows(spec: spec)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    /// `peak` is the largest component — the bar is measured against that,
    /// not against the sum.
    private func componentRow(_ component: SystemDataComponent,
                              spec: TableSpec, peak: UInt64) -> some View {
        let blocked = isBlocked(component)
        let isOpen = expanded.contains(component.kind)

        return TableRow(spec: spec,
                        height: Metric.rowDetailed,
                        isSelected: isOpen,
                        accessibility: loc.f("sysdata.a11y.explainFmt",
                                             loc.s(component.kind.titleKey)),
                        action: { toggle(component) }) {
            Text(loc.s(component.kind.titleKey))
                .font(Typo.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .column(spec, "component")

            Text(note(for: component, blocked: blocked))
                .font(Typo.secondary)
                .foregroundStyle(blocked ? Palette.warningText : Palette.textSecondary)
                .lineLimit(1)
                .column(spec, "what")

            Group {
                if let bytes = component.bytes, peak > 0 {
                    ShareBar(fraction: Double(bytes) / Double(peak))
                } else {
                    // No measurement, no bar — a zero-length bar reads as
                    // "nothing here", which is a different claim.
                    Color.clear.frame(height: 6)
                }
            }
            .column(spec, "share")

            Text(component.formattedSize ?? loc.s("sysdata.sizeHidden"))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(component.bytes == nil ? Palette.textTertiary : Palette.textSecondary)
                .lineLimit(1)
                .column(spec, "size")

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // A row that cannot be measured must offer a way out; a size
                // greyed to "hidden" with no action leaves nothing to do.
                if blocked {
                    Button(loc.s("sysdata.grantAccess")) { FullDiskAccess.openSettings() }
                        .buttonStyle(.warningAction(height: 24))
                        .help(loc.s("fda.openSettings"))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .animation(Motion.disclosure, value: isOpen)
            }
            .column(spec, "action")
        }
    }

    /// The long per-component description does not fit a table cell, and it is
    /// the whole reason this screen exists — so activating a row opens it here
    /// instead of losing it to truncation.
    private func explanation(_ component: SystemDataComponent) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(loc.s(component.kind.descKey))
                .font(Typo.footnote)
                .foregroundStyle(Palette.textNav)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 10)
        .frame(minHeight: Metric.nestedRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceFooter)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rowDivider).frame(height: 1)
        }
    }

    // MARK: Snapshots (nested)

    @ViewBuilder
    private func snapshotRows(spec: TableSpec) -> some View {
        ForEach(Array(visibleSnapshots.enumerated()), id: \.element.id) { index, snapshot in
            snapshotRow(snapshot, spec: spec).staggeredAppear(index: index)
        }

        // Truncation is labelled and always offers a way out.
        if hiddenSnapshotCount > 0 {
            TableFootnoteRow(
                text: loc.f("table.moreFmt", Fmt.count(hiddenSnapshotCount)),
                actionTitle: loc.s("table.showAll"),
                action: { withAnimation(Motion.panelReveal) { showAllSnapshots = true } }
            )
        }
    }

    private func snapshotRow(_ snapshot: TMSnapshot, spec: TableSpec) -> some View {
        let failed = failedID == snapshot.id
        let busy = deletingID == snapshot.id

        return TableRow(spec: spec,
                        height: Metric.nestedRow,
                        accessibility: loc.f("sysdata.a11y.snapshotFmt",
                                             viewModel.snapshotDateText(snapshot)),
                        action: { pendingDelete = snapshot }) {
            Text(viewModel.snapshotDateText(snapshot))
                .font(Typo.body)
                .foregroundStyle(Palette.textNav)
                .lineLimit(1)
                // Indents the row under the component it belongs to.
                .padding(.leading, 14)
                .column(spec, "component")

            Text(failed ? loc.s("sysdata.snapshotDeleteFailed") : snapshot.id)
                .font(failed ? Typo.secondary : Typo.numeric(11, weight: .regular))
                .foregroundStyle(failed ? Palette.dangerText : Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .column(spec, "what")

            Color.clear.frame(height: 6)
                .column(spec, "share")

            // APFS does not expose per-snapshot sizes without root.
            Text(Fmt.none)
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .column(spec, "size")

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // Always rendered, never gated on hover.
                if busy {
                    ProgressView().controlSize(.small)
                } else if failed {
                    Button(loc.s("common.retry")) { pendingDelete = snapshot }
                        .buttonStyle(.secondaryAction(height: 24))
                        .disabled(viewModel.isDeletingSnapshot)
                } else {
                    Button(loc.s("sysdata.deleteAction")) { pendingDelete = snapshot }
                        .buttonStyle(.dangerAction(height: 24))
                        .disabled(viewModel.isDeletingSnapshot)
                        .help(loc.s("sysdata.deleteSnapshot"))
                }
            }
            .column(spec, "action")
        }
    }

    private var visibleSnapshots: [TMSnapshot] {
        showAllSnapshots ? viewModel.snapshots : Array(viewModel.snapshots.prefix(snapshotLimit))
    }

    private var hiddenSnapshotCount: Int {
        showAllSnapshots ? 0 : max(0, viewModel.snapshots.count - snapshotLimit)
    }

    // MARK: Batch action

    private var bottomBar: some View {
        BottomActionBar(
            selectionLabel: loc.s("sysdata.snapshotsList"),
            selectionValue: Fmt.count(viewModel.snapshots.count),
            consequence: loc.s("sysdata.thinConsequence"),
            consequenceIsDestructive: true
        ) {
            if viewModel.isDeletingSnapshot || viewModel.isScanning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Palette.dangerFill)
                    .frame(width: 90)
            }
            Button(loc.f("sysdata.thinAllFmt", Fmt.count(viewModel.snapshots.count))) {
                showThinConfirm = true
            }
            .buttonStyle(PrimaryButtonStyle(tint: Palette.dangerFill))
            .disabled(viewModel.isDeletingSnapshot || viewModel.isScanning)
            .help(loc.s("sysdata.thinAllHelp"))
        }
    }

    // MARK: Row content

    /// A component is blocked when its size could not be read and the app has
    /// no Full Disk Access. Snapshots are excluded: APFS hides their size from
    /// everyone, so "grant access" would be a promise nothing can keep.
    private func isBlocked(_ component: SystemDataComponent) -> Bool {
        component.bytes == nil && component.kind != .snapshots && !hasFullDiskAccess
    }

    /// The "What it is" column: what the component is in one line — who manages
    /// it, or where it *is* cleaned. The full answer is a click away in the
    /// explanation, which is why this stays short enough not to truncate.
    private func note(for component: SystemDataComponent, blocked: Bool) -> String {
        if component.kind == .snapshots {
            // "Couldn't read" ≠ "none": tmutil refused (Full Disk Access /
            // rights), and "—" here would quietly claim zero snapshots.
            if viewModel.snapshotsUnreadable { return loc.s("sysdata.note.snapshotsUnreadable") }
            return viewModel.snapshots.isEmpty
                ? Fmt.none
                : Fmt.plural("plural.snapshots", viewModel.snapshots.count)
        }

        var text: String
        if blocked {
            text = loc.s("sysdata.note.sizeNeedsAccess")
        } else if component.bytes == nil {
            text = loc.s("detail.sizeUnavailable")
        } else {
            switch component.kind {
            case .systemCaches, .systemLogs: text = loc.s("sysdata.note.cleanedInCleanup")
            default:                         text = loc.s("sysdata.note.systemManaged")
            }
        }
        if let count = component.count {
            text += " · " + Fmt.plural("plural.items", count)
        }
        return text
    }

    private func toggle(_ component: SystemDataComponent) {
        withAnimation(Motion.panelReveal) {
            if expanded.contains(component.kind) {
                expanded.remove(component.kind)
            } else {
                expanded.insert(component.kind)
            }
        }
    }

    private func delete(_ snapshot: TMSnapshot) {
        deletingID = snapshot.id
        failedID = nil
        viewModel.deleteSnapshot(snapshot)
    }
}
