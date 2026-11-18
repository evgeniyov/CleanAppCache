import SwiftUI

// MARK: - Tables
//
// A table is a card → 32pt header → rows separated by `rowDivider` → an optional
// 60pt action footer.
//
// Column widths in the header and in the rows must match to the pixel. When
// they are laid out by two unrelated pieces of code — a header walking a column
// list while a row builds a fixed arrangement of slots — any change to one
// silently drifts from the other.
//
// Here the header and every row read the same `TableSpec`. A cell takes the
// width of the column it names, the flexible column takes the remainder, and the
// two cannot disagree because neither one owns the numbers.

/// One column. `width == nil` marks the flexible column that absorbs slack —
/// exactly one per spec.
public struct TableCol: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let width: CGFloat?
    public let alignment: Alignment

    public init(_ key: String, title: String = "", width: CGFloat? = nil,
                alignment: Alignment = .leading) {
        self.key = key
        self.title = title
        self.width = width
        self.alignment = alignment
    }
}

public struct TableSpec: Sendable {
    public let columns: [TableCol]
    public let spacing: CGFloat
    public let inset: CGFloat

    public init(_ columns: [TableCol],
                spacing: CGFloat = Metric.colGap,
                inset: CGFloat = Metric.inset) {
        self.columns = columns
        self.spacing = spacing
        self.inset = inset
    }

    func column(_ key: String) -> TableCol? {
        columns.first { $0.key == key }
    }
}

private struct TableColumnModifier: ViewModifier {
    let spec: TableSpec
    let key: String

    func body(content: Content) -> some View {
        // An unknown key would silently render a zero-width cell and shift every
        // column after it, so it fails loudly in debug instead.
        assert(spec.column(key) != nil, "TableSpec has no column '\(key)'")
        let col = spec.column(key)
        let alignment = col?.alignment ?? .leading
        // The `Color.clear` is load-bearing. A cell whose content is conditional
        // — a disclosure arrow only on expandable rows, a quit button only on
        // leaves — resolves to `EmptyView` on the other branch, and SwiftUI
        // elides `EmptyView` from a stack entirely: the frame below never gets
        // the chance to reserve the column, so every cell after it slides left
        // and the row stops lining up with its own header. Giving the cell a
        // real (empty) backing view is what keeps the column present.
        let cell = ZStack(alignment: alignment) {
            Color.clear
            content
        }
        return Group {
            if let width = col?.width {
                cell.frame(width: width, alignment: alignment)
            } else {
                cell.frame(maxWidth: .infinity, alignment: alignment)
            }
        }
    }
}

public extension View {
    /// Sizes this cell to the named column of `spec`. The header and the rows
    /// both go through here, which is what keeps them aligned.
    func column(_ spec: TableSpec, _ key: String) -> some View {
        modifier(TableColumnModifier(spec: spec, key: key))
    }
}

// MARK: - Header

/// 32pt column header — 11pt tertiary, hairline divider underneath.
///
/// A column may render something other than its title (a sort control, a filter
/// menu) by naming it in `custom`.
public struct TableHeader<Custom: View>: View {
    let spec: TableSpec
    let height: CGFloat
    let customKeys: Set<String>
    let custom: (String) -> Custom

    public init(_ spec: TableSpec,
                height: CGFloat = Metric.tableHeader,
                customKeys: Set<String> = [],
                @ViewBuilder custom: @escaping (String) -> Custom) {
        self.spec = spec
        self.height = height
        self.customKeys = customKeys
        self.custom = custom
    }

    public var body: some View {
        HStack(spacing: spec.spacing) {
            ForEach(spec.columns) { col in
                Group {
                    if customKeys.contains(col.key) {
                        custom(col.key)
                    } else {
                        Text(col.title)
                            .font(Typo.footnote)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .column(spec, col.key)
            }
        }
        .padding(.horizontal, spec.inset)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderHairline).frame(height: 1)
        }
    }
}

public extension TableHeader where Custom == EmptyView {
    init(_ spec: TableSpec, height: CGFloat = Metric.tableHeader) {
        self.init(spec, height: height, customKeys: []) { _ in EmptyView() }
    }
}

// MARK: - Row

/// A table row: the same insets and spacing as the header, a `rowDivider`
/// underneath, and the shared selection/hover background.
public struct TableRow<Content: View>: View {
    let spec: TableSpec
    let height: CGFloat
    let isSelected: Bool
    /// Storage and History paint their picked row `pickedRow`; everything else
    /// uses `selectedRow`.
    let selectionColor: Color?
    let background: Color?
    let showsDivider: Bool
    let accessibility: String
    let action: (() -> Void)?
    @ViewBuilder let content: Content

    @State private var hovered = false

    public init(spec: TableSpec,
                height: CGFloat = Metric.row,
                isSelected: Bool = false,
                selectionColor: Color? = nil,
                background: Color? = nil,
                showsDivider: Bool = true,
                accessibility: String,
                action: (() -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.spec = spec
        self.height = height
        self.isSelected = isSelected
        self.selectionColor = selectionColor
        self.background = background
        self.showsDivider = showsDivider
        self.accessibility = accessibility
        self.action = action
        self.content = content()
    }

    public var body: some View {
        Button { action?() } label: {
            HStack(spacing: spec.spacing) {
                content
            }
            .padding(.horizontal, spec.inset)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(alignment: .bottom) {
                if showsDivider {
                    Rectangle().fill(Palette.rowDivider).frame(height: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { hovered = $0 }
        .animation(Motion.rowHover, value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var rowBackground: Color {
        if let background { return background }
        if isSelected { return selectionColor ?? Palette.selectedRow }
        return hovered ? Palette.selectedRow : .clear
    }
}

// MARK: - Risk group header

/// 34pt group header on `surfaceFooter`: a 7×7 marker, an uppercase name, the
/// group total, and select-all / clear on the right.
public struct TableGroupHeader: View {
    let color: Color
    let title: String
    let total: String
    let selectAllTitle: String
    let clearTitle: String
    let onSelectAll: (() -> Void)?
    let onClear: (() -> Void)?

    public init(color: Color, title: String, total: String,
                selectAllTitle: String = "", clearTitle: String = "",
                onSelectAll: (() -> Void)? = nil, onClear: (() -> Void)? = nil) {
        self.color = color
        self.title = title
        self.total = total
        self.selectAllTitle = selectAllTitle
        self.clearTitle = clearTitle
        self.onSelectAll = onSelectAll
        self.onClear = onClear
    }

    public var body: some View {
        HStack(spacing: 9) {
            CategorySwatch(color: color, size: 7)
            Text(title).microLabel(Palette.textSecondary)
            Text(total)
                .font(Typo.numeric(11, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 8)
            if let onSelectAll {
                linkButton(selectAllTitle, action: onSelectAll)
            }
            if let onClear {
                linkButton(clearTitle, action: onClear)
            }
        }
        .padding(.horizontal, Metric.inset)
        .frame(height: Metric.sectionHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceFooter)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderHairline).frame(height: 1)
        }
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Typo.footnote)
            .foregroundStyle(Palette.accentText)
    }
}

// MARK: - Card header
//
// The strip above a table inside its card: a title, a count, and — on Storage,
// Smart Cleanup and Security — the "checked at" time with the circular refresh
// button. The refresh button belongs here, next to the data it refreshes, and
// not in the screen header.

public struct CardHeader<Trailing: View>: View {
    let title: String
    let detail: String?
    let height: CGFloat
    let trailing: Trailing

    public init(title: String, detail: String? = nil, height: CGFloat = 44,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.height = height
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(Typo.numeric(12, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Metric.inset)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderHairline).frame(height: 1)
        }
    }
}

public extension CardHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil, height: CGFloat = 44) {
        self.init(title: title, detail: detail, height: height) { EmptyView() }
    }
}

/// "updated 14:31" beside the refresh button.
public struct RefreshStamp: View {
    let text: String?
    let label: String
    let action: () -> Void

    public init(text: String?, label: String, action: @escaping () -> Void) {
        self.text = text
        self.label = label
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 9) {
            if let text {
                Text(text)
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            RefreshButton(label: label, action: action)
        }
    }
}

// MARK: - Column filter
//
// The column title is replaced by the chosen value and darkens to `textPrimary`;
// a 6pt chevron sits to its right. Only one menu can be open at a time, which is
// what the shared `openKey` binding enforces.

public struct ColumnFilter<Value: Hashable>: View {
    let title: String
    let options: [SegmentOption<Value>]
    @Binding var selection: Value
    /// The value that means "no filter"; its label is always the first item.
    let allValue: Value
    let allTitle: String
    let columnKey: String
    @Binding var openKey: String?

    public init(title: String, options: [SegmentOption<Value>],
                selection: Binding<Value>, allValue: Value, allTitle: String,
                columnKey: String, openKey: Binding<String?>) {
        self.title = title
        self.options = options
        self._selection = selection
        self.allValue = allValue
        self.allTitle = allTitle
        self.columnKey = columnKey
        self._openKey = openKey
    }

    private var isActive: Bool { selection != allValue }

    private var label: String {
        isActive ? (options.first { $0.value == selection }?.label ?? title) : title
    }

    public var body: some View {
        Button {
            openKey = (openKey == columnKey) ? nil : columnKey
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(Typo.footnote)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textTertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Once a value is picked the visible text is the value alone ("from 1
        // GB"), so the column name has to be carried separately or VoiceOver
        // cannot tell which column is filtered.
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isActive ? label : allTitle))
        // The menu is an overlay, not a popover, so Escape reaches nothing
        // unless it is wired here.
        .onExitCommand { openKey = nil }
        .overlay(alignment: .topLeading) {
            if openKey == columnKey {
                menu.offset(y: 22)
            }
        }
        .zIndex(openKey == columnKey ? 10 : 0)
    }

    private var menu: some View {
        VStack(spacing: 0) {
            item(allTitle, value: allValue)
            ForEach(options) { option in
                item(option.label, value: option.value)
            }
        }
        .padding(5)
        .frame(width: 168, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metric.menu, style: .continuous)
                .fill(Palette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.menu, style: .continuous)
                .strokeBorder(Palette.borderStrong, lineWidth: 1)
        )
        .shadow(color: Shadow.menuColor, radius: Shadow.menuRadius, x: 0, y: Shadow.menuY)
    }

    private func item(_ title: String, value: Value) -> some View {
        let chosen = selection == value
        return Button {
            selection = value
            openKey = nil
        } label: {
            HStack(spacing: 0) {
                Text(title)
                    .font(Typo.secondary)
                    .foregroundStyle(chosen ? Palette.accentText : Palette.textNav)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Metric.segment, style: .continuous)
                    .fill(chosen ? Palette.accentTint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sortable column header
//
// Clicking sorts, clicking again reverses. The active column darkens to
// `textPrimary` and grows an 8pt arrow.

public struct SortableHeader: View {
    let title: String
    let isActive: Bool
    let ascending: Bool
    let alignment: HorizontalAlignment
    let action: () -> Void

    public init(title: String, isActive: Bool, ascending: Bool,
                alignment: HorizontalAlignment = .leading,
                action: @escaping () -> Void) {
        self.title = title
        self.isActive = isActive
        self.ascending = ascending
        self.alignment = alignment
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(Typo.footnote)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textTertiary)
                    .lineLimit(1)
                if isActive {
                    Image(systemName: ascending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Palette.textPrimary)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The 6pt arrow is the only visible sort state.
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(Text(isActive
            ? Localizer.shared.s(ascending ? "a11y.sortAscending" : "a11y.sortDescending")
            : ""))
    }
}

// MARK: - Search field

public struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    let width: CGFloat?

    public init(text: Binding<String>, placeholder: String, width: CGFloat? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.width = width
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.secondary)
                .foregroundStyle(Palette.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Localizer.shared.s("common.clear")))
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 28)
        .background(
            RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                .fill(Palette.surfaceControl)
        )
    }
}
