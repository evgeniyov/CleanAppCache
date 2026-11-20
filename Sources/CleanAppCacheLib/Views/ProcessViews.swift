import SwiftUI

// MARK: - Process table
//
// Header and rows share one `TableSpec` — arrow 16 | Process | share 120 |
// CPU 60 | Memory 76 | action 30 — so the header and row columns cannot drift
// out of alignment.
//
// A group of several processes expands: the arrow turns 90°, the children indent
// to 44pt, lose 6pt of height, sit on `selectedRow` and carry the quiet child
// bar. A group has no single PID, so only a leaf row offers the quit button.

struct ProcessTable: View {
    @EnvironmentObject private var loc: Localizer

    let groups: [ProcessGroup]
    @Binding var query: String
    @Binding var sortByMemory: Bool
    @Binding var expanded: Set<String>
    /// 40pt at regular density, 32 compact.
    let rowHeight: CGFloat
    let onKill: (ProcessInfoItem) -> Void

    private var spec: TableSpec {
        TableSpec([
            TableCol("arrow", width: 16),
            TableCol("name", title: loc.s("monitor.col.process")),
            TableCol("share", title: shareTitle, width: 120),
            TableCol("cpu", title: loc.s("monitor.col.cpu"), width: 60, alignment: .trailing),
            TableCol("mem", title: loc.s("monitor.col.memory"), width: 76, alignment: .trailing),
            TableCol("kill", width: 30, alignment: .trailing),
        ])
    }

    /// The share column is named after whatever the table is sorted by.
    private var shareTitle: String {
        loc.s(sortByMemory ? "monitor.col.shareMemory" : "monitor.col.shareCpu")
    }

    var body: some View {
        // Once per pass. `visible` filters and sorts the whole list, `peak`
        // walks it again, and `spec` runs `loc.s()` per column — computed per
        // row, all three would rerun for every row on every 2 s tick.
        let spec = self.spec
        let rows = visible
        let peak = rows.map(magnitude).max() ?? 1
        return VStack(spacing: 0) {
            CardHeader(title: loc.s("monitor.processes"), detail: countText(visible: rows.count), height: 48) {
                HStack(spacing: 10) {
                    SearchField(text: $query,
                                placeholder: loc.s("monitor.searchProcess"),
                                width: 200)
                    SegmentedControl(selection: $sortByMemory,
                                     options: [
                                        SegmentOption(value: false, label: loc.s("monitor.col.cpu")),
                                        SegmentOption(value: true, label: loc.s("monitor.col.memory")),
                                     ],
                                     height: 30)
                }
            }

            TableHeader(spec, customKeys: ["cpu", "mem"]) { key in
                // The column being sorted by is the darker of the two.
                let isActive = (key == "mem") == sortByMemory
                Text(loc.s(key == "mem" ? "monitor.col.memory" : "monitor.col.cpu"))
                    .font(Typo.footnote)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, group in
                        groupRow(group, spec: spec, peak: peak).staggeredAppear(index: index)
                        if expanded.contains(group.id) {
                            ForEach(group.children) { child in
                                childRow(child, spec: spec, peak: peak)
                            }
                        }
                    }
                    if rows.isEmpty && !query.isEmpty {
                        StateView(.filterEmpty(total: groups.count,
                                               query: query,
                                               reset: { query = "" }))
                            .frame(minHeight: 220)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    // MARK: Data

    private var visible: [ProcessGroup] {
        ProcessGroup.ranked(groups, byMemory: sortByMemory, query: query)
    }

    private func magnitude(_ group: ProcessGroup) -> Double {
        sortByMemory ? Double(group.memBytes) : group.cpuPercent
    }

    private func magnitude(_ item: ProcessInfoItem) -> Double {
        sortByMemory ? Double(item.memBytes) : item.cpuPercent
    }

    private func countText(visible: Int) -> String {
        query.isEmpty
            ? Fmt.count(visible)
            : loc.f("monitor.procFilteredFmt", Fmt.count(visible), Fmt.count(groups.count))
    }

    // MARK: Rows

    /// `peak` is the largest row's magnitude — the bar is measured against
    /// that, not against the sum.
    private func groupRow(_ group: ProcessGroup, spec: TableSpec, peak: Double) -> some View {
        let expandable = group.children.count > 1
        let isOpen = expanded.contains(group.id)

        return TableRow(spec: spec,
                        height: rowHeight,
                        background: isOpen ? Palette.selectedRow : nil,
                        accessibility: expandable
                            ? loc.f("monitor.a11y.expandFmt", group.name) : group.name,
                        // A no-op keeps a leaf row enabled so its quit button
                        // stays reachable — `.disabled` would propagate to it.
                        action: { if expandable { toggle(group) } }) {
            Group {
                if expandable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(Motion.disclosure, value: isOpen)
                }
            }
            .column(spec, "arrow")

            Text(group.name)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .column(spec, "name")

            ShareBar(fraction: peak > 0 ? magnitude(group) / peak : 0, color: Palette.accent)
                .column(spec, "share")

            Text(Fmt.percent(group.cpuPercent))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(sortByMemory ? Palette.textSecondary : Palette.textPrimary)
                .lineLimit(1)
                .column(spec, "cpu")

            Text(Fmt.bytes(group.memBytes))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(sortByMemory ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
                .column(spec, "mem")

            Group {
                if !expandable, let only = group.children.first {
                    KillButton(name: only.name) { onKill(only) }
                }
            }
            .column(spec, "kill")
        }
    }

    private func childRow(_ child: ProcessInfoItem, spec: TableSpec, peak: Double) -> some View {
        TableRow(spec: spec,
                 height: max(24, rowHeight - 6),
                 background: Palette.selectedRow,
                 accessibility: child.name,
                 action: {}) {
            Color.clear
                .frame(width: 1, height: 1)
                .column(spec, "arrow")

            Text(child.name)
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                // Children start at 44pt, 26 past the group's 18pt inset.
                .padding(.leading, 26)
                .column(spec, "name")

            ShareBar(fraction: peak > 0 ? magnitude(child) / peak : 0,
                     color: Palette.accentChildBar)
                .column(spec, "share")

            Text(Fmt.percent(child.cpuPercent))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .column(spec, "cpu")

            Text(Fmt.bytes(child.memBytes))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .column(spec, "mem")

            KillButton(name: child.name) { onKill(child) }
                .column(spec, "kill")
        }
    }

    private func toggle(_ group: ProcessGroup) {
        withAnimation(Motion.disclosure) {
            if expanded.contains(group.id) {
                expanded.remove(group.id)
            } else {
                expanded.insert(group.id)
            }
        }
    }
}

// MARK: - Quit button

/// 22×22, radius 6, `dangerTint` plate with a `dangerFill` cross. Always
/// visible: a button that appears only on hover cannot be reached from the
/// keyboard or from VoiceOver.
private struct KillButton: View {
    @EnvironmentObject private var loc: Localizer

    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Palette.dangerFill)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Metric.segment, style: .continuous)
                        .fill(Palette.dangerTint)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(loc.f("monitor.a11y.killFmt", name)))
        .help(loc.f("monitor.a11y.killFmt", name))
    }
}
