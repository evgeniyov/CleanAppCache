import SwiftUI

// MARK: - Sidebar
//
// Navigation is one flat level: three groups, every item always visible.
// Nothing expands, nothing collapses, and the section itself is not clickable —
// it is a label. An active item is an `accentTint` plate at radius 8.

/// Group label above a run of items — 30pt, 11/600, tertiary, tracking 0.3.
///
/// It is a control, not a caption: a group opens its first item, so clicking
/// the Cleanup group opens Smart Cleanup.
struct SidebarGroupHeader: View {
    let title: String
    /// 4 above the first group, 12 above the rest.
    let isFirst: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: compact ? Metric.tapTarget : Metric.sidebarGroupHeader)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, compact ? (isFirst ? 0 : 4) : (isFirst ? 4 : 12))
    }
}

/// Navigation item — 36pt, 13pt. Active: weight 600, `accentText` on
/// `accentTint`, radius 8.
struct SidebarItemRow<Badge: View>: View {
    let title: String
    let isSelected: Bool
    let rowHeight: CGFloat
    let action: () -> Void
    let badge: Badge

    @State private var hovered = false

    init(title: String, isSelected: Bool, rowHeight: CGFloat = Metric.sidebarRow,
         action: @escaping () -> Void,
         @ViewBuilder badge: () -> Badge) {
        self.title = title
        self.isSelected = isSelected
        self.rowHeight = rowHeight
        self.action = action
        self.badge = badge()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Palette.accentText : Palette.textNav)
                    .lineLimit(1)
                Spacer(minLength: 4)
                badge
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background(
                RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.rowHover, value: hovered)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: Color {
        if isSelected { return Palette.accentTint }
        return hovered ? Palette.surfaceControl : .clear
    }
}

extension SidebarItemRow where Badge == EmptyView {
    init(title: String, isSelected: Bool, rowHeight: CGFloat = Metric.sidebarRow, action: @escaping () -> Void) {
        self.init(title: title, isSelected: isSelected, rowHeight: rowHeight, action: action) { EmptyView() }
    }
}

/// Counter at the trailing edge of an item — 11pt SF Mono, tertiary.
///
/// Generic over the view model so each badge observes exactly one object: the
/// sidebar must not re-render because an unrelated scanner published a change,
/// and `MonitorViewModel` in particular ticks every second.
///
/// `value` returns nil until the section has been scanned — the sidebar shows
/// nothing rather than a zero that reads as "nothing to clean here".
struct SidebarCounter<VM: ObservableObject>: View {
    @ObservedObject var vm: VM
    let value: (VM) -> String?

    var body: some View {
        if let text = value(vm) {
            Text(text)
                .font(Typo.numeric(11, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Monogram
//
// The app mark: a "C" built from three interface strokes — top, left and bottom
// — forming a brace open to the right. White on solid accent, square ends, no
// gradient. The proportions are drawn for a 20pt tile: the glyph is
// half the tile, inset a quarter, with a stroke an eighth wide.

public struct Monogram: View {
    let size: CGFloat

    public init(size: CGFloat = 20) { self.size = size }

    public var body: some View {
        let glyph = size * 0.5
        let inset = size * 0.25
        let stroke = size * 0.125

        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.accent)
            Group {
                Rectangle().frame(width: glyph, height: stroke)
                    .offset(x: inset, y: inset)
                Rectangle().frame(width: stroke, height: glyph)
                    .offset(x: inset, y: inset)
                Rectangle().frame(width: glyph, height: stroke)
                    .offset(x: inset, y: inset + glyph - stroke)
            }
            .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .accessibilityHidden(true)
    }
}
