import SwiftUI

// MARK: - ListRow
//
// The detailed two-line row (name over path) for the Storage drill-down and
// the Applications detail sheet. The column tables use `TableRow`; this one
// survives for lists that have no `TableSpec` to align against.
//
// Non-negotiables baked into the component so screens cannot regress:
//
//   1. The row is a `Button`, not `.onTapGesture` on a `Rectangle`. That gives
//      it the button trait, focus, Space/Return, and a VoiceOver action —
//      none of which a tap gesture on a shape provides.
//   2. `accessibility` is a required parameter and describes the row's own
//      action, not a neighbouring control.
//   3. The `actions` column is always present and never hover-gated, so its
//      buttons stay reachable from the keyboard and VoiceOver.
//   4. Risk is spelled out in words, never carried by color alone.

// MARK: Row anatomy

public enum RowIcon {
    /// SF Symbol on a 26×26 plate.
    case symbol(String)
    /// 10×10 status dot — used on the Security screen instead of four glyphs.
    case status(Tone)
    /// Real app icon (NSWorkspace) or any other pre-built view.
    case view(AnyView)
    case none

    public static func custom<V: View>(_ v: V) -> RowIcon { .view(AnyView(v)) }
}

public enum RowSelection {
    case none
    /// Checkbox. `enabled: false` draws the "unavailable" bar instead of a tick.
    case checkbox(isOn: Bool, enabled: Bool)
}

public extension RowSelection {
    // Enum cases cannot carry default values.
    static func checkbox(isOn: Bool) -> RowSelection { .checkbox(isOn: isOn, enabled: true) }
}

public enum RowState: Equatable {
    case normal
    /// Needs elevated privileges. The row **must** still offer a way forward —
    /// a `WarningButtonStyle` action in the `actions` column.
    case needsAdmin
    /// Operation failed: `detail` is replaced by the reason in danger text.
    case failed(String)
}

/// A word label for risk/status. Never rely on the color alone.
public struct RowRisk {
    let text: String
    let tone: Tone
    public init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

public enum RowDetailStyle {
    case plain
    /// Monospaced, truncated in the middle — for filesystem paths.
    case path
}

// MARK: - ListRow

public struct ListRow<Meta: View, Actions: View>: View {
    let title: String
    let detail: String?
    let detailStyle: RowDetailStyle
    let icon: RowIcon
    let selection: RowSelection
    let risk: RowRisk?
    let state: RowState
    let height: CGFloat
    let isSelected: Bool
    /// Describes what activating the row does. Required — see rule 2 above.
    let accessibility: String
    let action: () -> Void
    @ViewBuilder var meta: Meta
    @ViewBuilder var actions: Actions

    @State private var hovered = false

    public init(title: String,
                detail: String? = nil,
                detailStyle: RowDetailStyle = .plain,
                icon: RowIcon = .none,
                selection: RowSelection = .none,
                risk: RowRisk? = nil,
                state: RowState = .normal,
                height: CGFloat = Metric.row,
                isSelected: Bool = false,
                accessibility: String,
                action: @escaping () -> Void,
                @ViewBuilder meta: () -> Meta,
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.detail = detail
        self.detailStyle = detailStyle
        self.icon = icon
        self.selection = selection
        self.risk = risk
        self.state = state
        self.height = height
        self.isSelected = isSelected
        self.accessibility = accessibility
        self.action = action
        self.meta = meta()
        self.actions = actions()
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                selectionSlot
                iconSlot
                contentSlot.layoutPriority(1)
                meta
                actionsSlot
            }
            .padding(.horizontal, Metric.inset)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rowDivider).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.rowHover, value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(traits)
    }

    private var traits: AccessibilityTraits {
        var t: AccessibilityTraits = .isButton
        if isSelected { t.formUnion(.isSelected) }
        return t
    }

    // MARK: Slots

    @ViewBuilder
    private var selectionSlot: some View {
        switch selection {
        case .none:
            EmptyView()
        case let .checkbox(isOn, enabled):
            RowCheckbox(isOn: isOn,
                        enabled: enabled && state != .needsAdmin,
                        blocked: state == .needsAdmin)
        }
    }

    @ViewBuilder
    private var iconSlot: some View {
        switch icon {
        case .none:
            EmptyView()
        case let .status(tone):
            Circle()
                .fill(tone.fill)
                .frame(width: 10, height: 10)
                .frame(width: 26, height: 26)
        case let .view(v):
            v.frame(width: 26, height: 26)
        case let .symbol(name):
            let blocked = state == .needsAdmin
            Image(systemName: blocked ? "lock.fill" : name)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(blocked ? Palette.warningText : Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                        .fill(blocked ? Palette.borderHairline : Palette.surfaceControl)
                )
        }
    }

    private var contentSlot: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typo.bodyStrong)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let risk {
                    Text(risk.text).riskLabel(risk.tone.text)
                }
            }
            if let detailText {
                Text(detailText)
                    .font(detailFont)
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .truncationMode(detailStyle == .path ? .middle : .tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fixed 86pt so every table's last column lines up — but only when
    /// the row actually has actions.
    ///
    /// Reserving it unconditionally would cost 86pt on every table that passes no
    /// actions at all, and that space comes out of the flexible title column: on
    /// Storage it squeezes the share bars down to their minimum, so a 162 GB row
    /// and a 172 KB row draw the same length.
    @ViewBuilder
    private var actionsSlot: some View {
        if Actions.self != EmptyView.self {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                actions
            }
            .frame(width: 86, alignment: .trailing)
        }
    }

    // MARK: Appearance

    private var rowBackground: Color {
        if isSelected { return Palette.selectedRow }
        // A single hover level, shared with the selected-row color.
        return hovered ? Palette.selectedRow : .clear
    }

    private var titleColor: Color {
        switch state {
        case .needsAdmin: return Palette.textSecondary
        case .failed:     return Palette.textPrimary
        case .normal:     return Palette.textPrimary
        }
    }

    private var detailText: String? {
        if case let .failed(reason) = state { return reason }
        return detail
    }

    private var detailColor: Color {
        if case .failed = state { return Palette.dangerText }
        return Palette.textTertiary
    }

    private var detailFont: Font {
        detailStyle == .path ? Typo.numeric(11, weight: .regular) : Typo.footnote
    }
}

// MARK: Convenience initializers

public extension ListRow where Actions == EmptyView {
    init(title: String, detail: String? = nil, detailStyle: RowDetailStyle = .plain,
         icon: RowIcon = .none, selection: RowSelection = .none, risk: RowRisk? = nil,
         state: RowState = .normal, height: CGFloat = Metric.row, isSelected: Bool = false,
         accessibility: String, action: @escaping () -> Void,
         @ViewBuilder meta: () -> Meta) {
        self.init(title: title, detail: detail, detailStyle: detailStyle, icon: icon,
                  selection: selection, risk: risk, state: state, height: height,
                  isSelected: isSelected, accessibility: accessibility, action: action,
                  meta: meta, actions: { EmptyView() })
    }
}

public extension ListRow where Meta == EmptyView {
    init(title: String, detail: String? = nil, detailStyle: RowDetailStyle = .plain,
         icon: RowIcon = .none, selection: RowSelection = .none, risk: RowRisk? = nil,
         state: RowState = .normal, height: CGFloat = Metric.row, isSelected: Bool = false,
         accessibility: String, action: @escaping () -> Void,
         @ViewBuilder actions: () -> Actions) {
        self.init(title: title, detail: detail, detailStyle: detailStyle, icon: icon,
                  selection: selection, risk: risk, state: state, height: height,
                  isSelected: isSelected, accessibility: accessibility, action: action,
                  meta: { EmptyView() }, actions: actions)
    }
}

public extension ListRow where Meta == EmptyView, Actions == EmptyView {
    init(title: String, detail: String? = nil, detailStyle: RowDetailStyle = .plain,
         icon: RowIcon = .none, selection: RowSelection = .none, risk: RowRisk? = nil,
         state: RowState = .normal, height: CGFloat = Metric.row, isSelected: Bool = false,
         accessibility: String, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, detailStyle: detailStyle, icon: icon,
                  selection: selection, risk: risk, state: state, height: height,
                  isSelected: isSelected, accessibility: accessibility, action: action,
                  meta: { EmptyView() }, actions: { EmptyView() })
    }
}

// MARK: - Checkbox
//
// 20pt glyph inside a 28×28 hit area. Four states: off, on (white tick on
// accent), mixed (white bar on accent: the row stands for several items and
// only some are selected), and unavailable (grey dash on a control-coloured
// box, so "can't select this" is visible without color).

public struct RowCheckbox: View {
    let isOn: Bool
    let mixed: Bool
    let enabled: Bool
    let blocked: Bool

    /// `mixed` marks a row that stands for several items of which only some are
    /// selected. It wins over `isOn`; `blocked` and `!enabled` win over both,
    /// because a control that cannot be toggled must never read as queued.
    public init(isOn: Bool, mixed: Bool = false, enabled: Bool = true, blocked: Bool = false) {
        self.isOn = isOn
        self.mixed = mixed
        self.enabled = enabled
        self.blocked = blocked
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.checkboxRadius, style: .continuous)
        return ZStack {
            if blocked || !enabled {
                shape.fill(Palette.surfaceControl)
                shape.strokeBorder(Palette.checkboxBorder, lineWidth: 1.5)
                Capsule()
                    .fill(Palette.textTertiary)
                    .frame(width: 10, height: 1.5)
            } else if mixed {
                // Accent fill like the on state, so it reads as "queued"; the
                // white bar matches the tick's stroke weight. The disabled dash
                // above is grey on a control-coloured box, never on accent.
                shape.fill(Palette.accent)
                Capsule()
                    .fill(.white)
                    .frame(width: 8, height: 2)
            } else if isOn {
                shape.fill(Palette.accent)
                // An 11×11 tick, stroke 1.9, round caps.
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                shape.fill(Palette.surfaceRaised)
                shape.strokeBorder(Palette.checkboxBorder, lineWidth: 1.5)
            }
        }
        .frame(width: Metric.checkboxGlyph, height: Metric.checkboxGlyph)
        .contentShape(Rectangle())
    }
}

// MARK: - Meta helpers
//
// The `meta` column: a monospaced size, right-aligned (the share bar is
// `ShareBar` in Bars.swift).

/// Right-aligned monospaced figure. Every number in the app is monospaced.
public struct RowValue: View {
    let text: String
    let width: CGFloat
    let size: CGFloat
    let color: Color?

    public init(_ text: String, width: CGFloat = 80, size: CGFloat = 12, color: Color? = nil) {
        self.text = text
        self.width = width
        self.size = size
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(Typo.numeric(size, weight: .regular))
            .foregroundStyle(color ?? Palette.textSecondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

// MARK: - Table chrome

/// 30pt section header inside a table.
public struct TableSectionHeader: View {
    let title: String
    let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title).microLabel()
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(Typo.numeric(11, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, Metric.inset)
        .frame(height: Metric.sectionHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderHairline).frame(height: 1)
        }
    }
}

/// Truncation footnote. A list capped with `prefix(200)` / `prefix(15)` /
/// `prefix(80)` must not cut itself off silently: every truncation is labelled
/// and offers a way out.
public struct TableFootnoteRow: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(Typo.numeric(11, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, Metric.inset)
        .frame(height: Metric.footnoteRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceFooter)
    }
}

// MARK: - Bottom action bar
//
// 60pt on `surfaceFooter`, appearing when something is selected. It wraps,
// because a flat HStack collapses the left-hand text at the minimum window
// width.

public struct BottomActionBar<Actions: View>: View {
    let selectionLabel: String
    let selectionValue: String
    /// Object count beside the volume — "· 15,396 items".
    let selectionCount: String?
    /// Where the files actually go. Mandatory — the bar must say whether the
    /// action is reversible.
    let consequence: String
    let consequenceIsDestructive: Bool
    @ViewBuilder var actions: Actions

    public init(selectionLabel: String,
                selectionValue: String,
                selectionCount: String? = nil,
                consequence: String,
                consequenceIsDestructive: Bool = false,
                @ViewBuilder actions: () -> Actions) {
        self.selectionLabel = selectionLabel
        self.selectionValue = selectionValue
        self.selectionCount = selectionCount
        self.consequence = consequence
        self.consequenceIsDestructive = consequenceIsDestructive
        self.actions = actions()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                selectionBlock
                Spacer(minLength: 12)
                consequenceBlock
                actions
            }
            // Narrow window: consequence text moves under the selection block.
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    selectionBlock
                    consequenceBlock
                }
                Spacer(minLength: 8)
                actions
            }
        }
        .padding(.horizontal, Metric.inset)
        .frame(minHeight: Metric.bottomBar)
        .frame(maxWidth: .infinity)
        .background(Palette.surfaceFooter)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.borderHairline).frame(height: 1)
        }
    }

    /// Label 12pt secondary → volume 16/600 SF Mono → count 12pt tertiary.
    private var selectionBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(selectionLabel)
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
            Text(selectionValue)
                .font(Typo.numeric(Typo.barTotal.size))
                .foregroundStyle(Palette.textPrimary)
                .contentTransition(.numericText())
                .animation(Motion.content, value: selectionValue)
            if let selectionCount {
                Text(selectionCount)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    /// The consequence line — secondary when reversible, `dangerText` when not.
    /// It is plain text either way: the bar never nests a second boxed surface.
    private var consequenceBlock: some View {
        Text(consequence)
            .font(Typo.secondary)
            .foregroundStyle(consequenceIsDestructive ? Palette.dangerText : Palette.textSecondary)
            .lineLimit(2)
    }
}
