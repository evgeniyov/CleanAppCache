import SwiftUI
import AppKit

// MARK: - StateView
//
// The six states every scanning section owns, in one component, so no screen
// hand-builds its own empty state, centred message or progress ring.
//
// The rule: **all six states are mandatory for every scanning section.** They
// differ only in the "what was checked" string and the section noun, so a
// screen declares one value instead of assembling an empty state from scratch.
//
// What the six states guard against:
//   • A section without a "scanned, found nothing" branch draws zeroed tiles
//     and an empty grid.
//   • Testing the full list for emptiness while rendering the filtered one
//     turns an empty search into a blank scroll view.
//   • Showing the green "all clear" state for an empty search is a false
//     negative on a security screen; that case is `.filterEmpty`.
//   • A 7-second toast is gone before the error can be read. `.failure` keeps
//     the reason on screen.

public enum ScreenState {
    /// Nothing scanned yet. Names the section and what the scan will look for.
    case idle(section: String, willFind: String, scan: () -> Void)

    /// Scan in progress: percentage, current category, current path.
    /// `cancel` is optional: a screen whose view model has no cancellation
    /// passes nil and gets no button, rather than a live control that does
    /// nothing.
    case scanning(percent: Double, category: String, path: String, cancel: (() -> Void)?)

    /// Scanned and found nothing. Says **what** was checked and when.
    case clean(checked: String, lastScan: Date?, rescan: () -> Void)

    /// Scan failed. Keeps the path and the error code on screen.
    case failure(path: String, code: String, retry: () -> Void, copyDetails: (() -> Void)?)

    /// Blocked by missing permissions. Always offers "scan anyway".
    case noAccess(missing: String, openSettings: () -> Void, scanAnyway: (() -> Void)?)

    /// The filter matched nothing. Says how many items exist behind it.
    case filterEmpty(total: Int, query: String, reset: () -> Void)
}

// Enum cases cannot carry default values, so the common shapes get factories.
public extension ScreenState {
    /// `copyDetails` falls back to copying "path + code" to the pasteboard.
    static func failure(path: String, code: String,
                        retry: @escaping () -> Void) -> ScreenState {
        .failure(path: path, code: code, retry: retry, copyDetails: nil)
    }

    /// Use only where scanning without the permission genuinely cannot work —
    /// every other section offers the "scan anyway" way out.
    static func noAccess(missing: String,
                         openSettings: @escaping () -> Void) -> ScreenState {
        .noAccess(missing: missing, openSettings: openSettings, scanAnyway: nil)
    }
}

public struct StateView: View {
    @EnvironmentObject private var loc: Localizer
    let state: ScreenState

    public init(_ state: ScreenState) { self.state = state }

    public var body: some View {
        VStack(spacing: 14) {
            switch state {
            case let .scanning(percent, category, path, cancel):
                scanning(percent: percent, category: category, path: path, cancel: cancel)
            default:
                plate
                textBlock
                buttons
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metric.gutter)
    }

    // MARK: Standard layout
    //
    // 44×44 plate at radius 10, a 13/600 title, and 12pt copy no wider than
    // 320pt so the paragraph keeps a readable measure.

    private var plate: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .strokeBorder(plateTone, lineWidth: 1)
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(glyphTone)
        }
        .frame(width: 44, height: 44)
    }

    private var textBlock: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(Typo.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                // 12pt × 1.55 line-height ⇒ 6.6pt of extra leading.
                .lineSpacing(6.6)
                .frame(maxWidth: 320)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            switch state {
            case let .idle(_, _, scan):
                Button(loc.s("common.scan"), action: scan)
                    .buttonStyle(.primaryAction(height: 30))

            case let .clean(_, _, rescan):
                Button(loc.s("common.rescan"), action: rescan)
                    .buttonStyle(.secondaryAction)

            case let .failure(path, code, retry, copyDetails):
                Button(loc.s("common.retry"), action: retry)
                    .buttonStyle(.primaryAction(height: 30))
                Button(loc.s("state.copyDetails")) { // the reason must outlive the 7s toast
                    if let copyDetails {
                        copyDetails()
                    } else {
                        // Sensible default so no screen ships without it.
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString("\(path)\n\(code)", forType: .string)
                    }
                }
                .buttonStyle(.secondaryAction)

            case let .noAccess(_, openSettings, scanAnyway):
                Button(loc.s("fda.openSettings"), action: openSettings)
                    .buttonStyle(.primaryAction(height: 30))
                if let scanAnyway {
                    Button(loc.s("state.scanAnyway"), action: scanAnyway)
                        .buttonStyle(.secondaryAction)
                }

            case let .filterEmpty(_, _, reset):
                Button(loc.s("state.resetFilter"), action: reset)
                    .buttonStyle(.secondaryAction)

            case .scanning:
                EmptyView()
            }
        }
        .padding(.top, 2)
    }

    // MARK: Scanning — percentage and a bar, no 96pt ring

    private func scanning(percent: Double, category: String, path: String,
                          cancel: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Text(Fmt.percent(percent * 100, decimals: 0))
                .figure(Typo.scanPercent)
                .contentTransition(.numericText())
                .animation(Motion.progress, value: percent)

            GaugeBar(fraction: percent, height: 5)
                .frame(width: 280)
                .animation(Motion.progress, value: percent)

            VStack(spacing: 4) {
                Text(category)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                Text(path)
                    .font(Typo.numeric(11, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320)
            }

            if let cancel {
                Button(loc.s("common.cancel"), action: cancel)
                    .buttonStyle(.secondaryAction)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: Per-state content

    private var icon: String {
        switch state {
        case .idle, .filterEmpty: return "magnifyingglass"
        case .clean:              return "checkmark"
        case .failure:            return "xmark"
        case .noAccess:           return "lock.fill"
        case .scanning:           return "magnifyingglass"
        }
    }

    /// The plate uses the neutral card border. The three states that
    /// carry a verdict keep their tone — that is information, not decoration.
    private var plateTone: Color {
        switch state {
        case .idle, .filterEmpty, .scanning: return Palette.borderStrong
        case .clean:    return Palette.successFill
        case .failure:  return Palette.dangerFill
        case .noAccess: return Palette.warningFill
        }
    }

    private var glyphTone: Color {
        switch state {
        case .idle, .filterEmpty, .scanning: return Palette.textSecondary
        case .clean:    return Palette.successText
        case .failure:  return Palette.dangerText
        case .noAccess: return Palette.warningText
        }
    }

    /// The title is the same on every unscanned
    /// section, and the section's name belongs in the description with the rest
    /// of what the scan will look at.
    private var title: String {
        switch state {
        case .idle:        return loc.s("state.notScanned.title")
        case .clean:       return loc.s("state.clean.title")
        case .failure:     return loc.s("state.failure.title")
        case .noAccess:    return loc.s("state.noAccess.title")
        case .filterEmpty: return loc.s("state.noMatch.title")
        case .scanning:    return ""
        }
    }

    private var message: String {
        switch state {
        case let .idle(_, willFind, _):
            return willFind

        case let .clean(checked, lastScan, _):
            guard let lastScan else { return checked }
            // Via Localizer so the formatter is cached and carries the UI
            // locale — building one per render is what made 200-row lists cost
            // 20–200 ms, and without `.locale` the date ignores the UI language.
            return loc.f("state.clean.desc", checked, loc.dateTime(lastScan))

        case let .failure(path, code, _, _):
            return loc.f("state.failure.desc", path, code)

        case let .noAccess(missing, _, _):
            return missing

        case let .filterEmpty(total, query, _):
            // Names the filter and the total behind it: "the “5 GB+” filter left none of 6 items".
            return loc.f("state.noMatch.desc", query, total)

        case .scanning:
            return ""
        }
    }
}
