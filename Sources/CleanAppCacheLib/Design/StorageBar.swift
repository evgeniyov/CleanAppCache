import SwiftUI

// MARK: - Storage distribution bar
//
// One 30pt strip, radius 6, clipped. Segments sit flush against each other and
// are told apart by colour alone — the category swatch in the table beside it
// repeats the same hue, so the two read as one object.
//
// Free space is a *labelled segment*, not the absence of one. A bar that draws
// nothing for it leaves "how much room is left" — the question the screen
// exists to answer — as the one thing it does not say.
//
// The label rule is the fussy part and a hard requirement: a
// caption is drawn in full ("IMAGES 10%") only if the whole thing fits,
// otherwise just the name, otherwise nothing. Never a word cut in half.

public struct StorageBarSegment: Identifiable {
    public let id = UUID()
    public let name: String        // localized display name
    public let bytes: UInt64
    public let color: Color
    public let isFree: Bool
    /// Links a segment back to its breakdown row, so clicking either selects the
    /// same category.
    public let breakdownID: UUID?

    public init(name: String, bytes: UInt64, color: Color, isFree: Bool = false,
                breakdownID: UUID? = nil) {
        self.name = name
        self.bytes = bytes
        self.color = color
        self.isFree = isFree
        self.breakdownID = breakdownID
    }

    @MainActor var formattedSize: String { Fmt.bytes(bytes) }
}

public struct StorageBar: View {
    private let segments: [StorageBarSegment]
    private let total: UInt64
    private let onSelect: (StorageBarSegment) -> Void

    @State private var hovered: UUID?

    /// Bar height and corner radius.
    private let height: CGFloat = 30
    private let radius: CGFloat = 6
    /// Horizontal padding inside a segment, both sides.
    private let labelInset: CGFloat = 7
    /// Estimated width of one character at this font size.
    private let charWidth: CGFloat = 7

    /// `total` is the disk's capacity, not the sum of the segments.
    ///
    /// Dividing by the sum is wrong in the one case that matters: the category
    /// breakdown takes seconds to compute, so until it lands the only segment is
    /// free space — and a self-normalising bar would draw it as "FREE 100 %" next
    /// to a hero figure reading 75 % used. Whatever the breakdown has not accounted
    /// for shows as its own muted segment instead of inflating the others.
    public init(segments: [StorageBarSegment], total: UInt64,
                onSelect: @escaping (StorageBarSegment) -> Void) {
        self.segments = segments
        self.total = max(1, total)
        self.onSelect = onSelect
    }

    /// The slice no category has claimed yet.
    private var unaccounted: UInt64 {
        let claimed = segments.reduce(UInt64(0)) { $0 &+ $1.bytes }
        return total > claimed ? total - claimed : 0
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                ForEach(segments) { seg in
                    let fraction = Double(seg.bytes) / Double(total)
                    segment(seg, width: max(seg.bytes > 0 ? 2 : 0, width * fraction),
                            fraction: fraction)
                }
                if unaccounted > 0 {
                    Rectangle()
                        .fill(Palette.borderHairline)
                        .frame(width: max(2, width * Double(unaccounted) / Double(total)))
                }
            }
        }
        .frame(height: height)
        .background(Palette.borderHairline)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func segment(_ seg: StorageBarSegment, width: CGFloat, fraction: Double) -> some View {
        let isHovered = hovered == seg.id
        Button {
            onSelect(seg)
        } label: {
            ZStack {
                Rectangle().fill(seg.isFree ? Palette.freeSegment : seg.color)
                if let label = caption(for: seg, fraction: fraction, width: width) {
                    Text(label)
                        .font(Typo.micro)
                        .tracking(0.5)
                        .foregroundStyle(seg.isFree ? Palette.textSecondary
                                                    : Color.white.opacity(0.95))
                        .lineLimit(1)
                        .padding(.horizontal, labelInset)
                }
            }
            .frame(width: width)
            .brightness(isHovered ? 0.06 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? seg.id : nil }
        .animation(Motion.rowHover, value: isHovered)
        .help("\(seg.name) — \(seg.formattedSize)")
        .accessibilityLabel(Text("\(seg.name), \(seg.formattedSize)"))
    }

    /// Full caption if the whole thing fits, else the name alone, else nothing.
    /// Truncating mid-word is never allowed, so this measures before
    /// it commits rather than letting `lineLimit` cut the string.
    private func caption(for seg: StorageBarSegment, fraction: Double,
                         width: CGFloat) -> String? {
        let name = seg.name.uppercased()
        let percent = Int((fraction * 100).rounded())
        let full = "\(name) \(percent)%"
        let usable = width - labelInset * 2
        if CGFloat(full.count) * charWidth <= usable { return full }
        if CGFloat(name.count) * charWidth <= usable { return name }
        return nil
    }
}
