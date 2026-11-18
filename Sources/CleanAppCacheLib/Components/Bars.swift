import SwiftUI

// MARK: - Bars and gauges
//
// Every bar in the app is one of four shapes. They share one layout rule: a
// `GeometryReader` has no intrinsic size, so a bar built on one alone
// collapses to nothing under a bare `maxWidth`. These use a
// `Capsule`-clipped `ZStack` with an explicit fraction instead, which stretches
// correctly inside any container.

/// Track plus fill. The corner radius is always half the height.
public struct GaugeBar: View {
    let fraction: Double
    let height: CGFloat
    let fill: Color?
    let track: Color?

    public init(fraction: Double, height: CGFloat = 6,
                fill: Color? = nil, track: Color? = nil) {
        self.fraction = fraction
        self.height = height
        self.fill = fill
        self.track = track
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track ?? Palette.borderHairline)
                Capsule()
                    .fill(fill ?? Palette.accent)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

/// Share bar inside a table row — 6pt, `borderHairline` track.
///
/// The width is measured against the **largest value in the list**, not
/// against the sum. The caller passes the already-divided fraction.
public struct ShareBar: View {
    let fraction: Double
    let color: Color?
    let width: CGFloat?

    public init(fraction: Double, color: Color? = nil, width: CGFloat? = nil) {
        self.fraction = fraction
        self.color = color
        self.width = width
    }

    public var body: some View {
        GaugeBar(fraction: fraction, height: 6, fill: color ?? Palette.accentBarLight)
            .frame(width: width)
    }
}

/// A labelled "health" gauge — 8pt bar under a caption and a 13/700 value
/// (Monitor: memory pressure, SSD life, battery capacity).
public struct HealthBar: View {
    let title: String
    let value: String
    let fraction: Double
    let color: Color
    let note: String?

    public init(title: String, value: String, fraction: Double,
                color: Color, note: String? = nil) {
        self.title = title
        self.value = value
        self.fraction = fraction
        self.color = color
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 6)
                Text(value)
                    .font(Typo.numeric(13, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
            }
            GaugeBar(fraction: fraction, height: 8, fill: color)
            if let note {
                Text(note)
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }
}

/// Composite bar for "free space after cleanup": the space already used
/// stays neutral, the part about to be freed is accent.
public struct SplitBar: View {
    let usedFraction: Double
    let freedFraction: Double
    let height: CGFloat

    public init(usedFraction: Double, freedFraction: Double, height: CGFloat = 10) {
        self.usedFraction = usedFraction
        self.freedFraction = freedFraction
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.borderHairline)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Palette.barUsedNeutral)
                        .frame(width: clamp(usedFraction) * geo.size.width)
                    Rectangle()
                        .fill(Palette.accent)
                        .frame(width: clamp(freedFraction) * geo.size.width)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }

    private func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
}

/// Status dot — the Security row marker and the thermal pill's state light.
public struct StatusDot: View {
    let tone: Tone
    let size: CGFloat

    public init(tone: Tone, size: CGFloat = 10) {
        self.tone = tone
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(tone.fill)
            .frame(width: size, height: size)
    }
}

/// Square colour marker for a category or section — 12×12 radius 3 in tables,
/// 7×7 radius 2 in group headers, 8×8 in History.
public struct CategorySwatch: View {
    let color: Color
    let size: CGFloat

    public init(color: Color, size: CGFloat = 12) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size <= 8 ? 2 : 3, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
    }
}
