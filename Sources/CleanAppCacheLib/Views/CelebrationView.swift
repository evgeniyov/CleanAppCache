import SwiftUI

// MARK: - Post-cleanup result
//
// A flat panel with an explicit way out. An overlay that dismisses only on a
// background tap, or on its own timer, leaves keyboard users nothing to press
// and makes the figure vanish before it has been read.
//
// The figure is everything the cleanup removed, and the lines under it split
// it: erased bytes are free space now, trashed bytes are not until the Trash
// is emptied. Calling the whole figure "freed" would promise space the disk
// does not have yet.
//
// The undo lives here too, for the trashed part only: erased bytes have no
// way back. The "moved to Trash" toast alone is not enough: it has already
// expired by the time this panel finishes counting up, so the moment the user
// sees how much has gone would be the moment they can no longer take it back.

struct CelebrationView: View {
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var history = CleanupHistory.shared
    let outcome: DashboardViewModel.CleanupOutcome
    let onDone: () -> Void

    @State private var appeared = false
    /// 0…1 progress of the count-up animation.
    @State private var countProgress: Double = 0
    /// Read once in `run()`. `StorageInfo.read()` queries the purgeable-space
    /// estimate, the slowest resource key, and the count-up re-renders the
    /// body 24 times in under a second.
    @State private var freeText = Fmt.none

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.s("celebrate.done")).microLabel(Palette.successText)

            Text(displayedBytes)
                .figure(Typo.heroFigure)
                .contentTransition(.numericText())

            ForEach(detailLines, id: \.self) { line in
                Text(line)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(subtitle)
                .font(Typo.footnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if outcome.trashedBytes > 0 {
                    Button(loc.s("celebrate.restore")) { openTrash() }
                        .buttonStyle(.secondaryAction)
                }
                Button(loc.s("common.done")) { onDone() }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(26)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Palette.surfaceRaised)
        .overlay(Rectangle().strokeBorder(Palette.borderStrong, lineWidth: 1))
        .opacity(appeared ? 1 : 0)
        .onAppear { run() }
        // Escape closes it, which the tap-anywhere overlay never offered.
        .background {
            Button("", action: onDone)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(detailLines.joined(separator: " ")))
    }

    /// One line per non-zero part. The panel only appears when the sum is
    /// non-zero, so there is always at least one.
    private var detailLines: [String] {
        var lines: [String] = []
        if outcome.freedBytes > 0 {
            lines.append(loc.f("celebrate.erasedFmt", Fmt.bytes(Int64(outcome.freedBytes))))
        }
        if outcome.trashedBytes > 0 {
            lines.append(loc.f("celebrate.trashedFmt", Fmt.bytes(Int64(outcome.trashedBytes))))
        }
        return lines
    }

    private var subtitle: String {
        loc.f("celebrate.subtitleFmt", freeText, history.formattedTotalFreed)
    }

    private var totalBytes: UInt64 {
        outcome.freedBytes &+ outcome.trashedBytes
    }

    private var displayedBytes: String {
        let current = UInt64(Double(totalBytes) * countProgress)
        return Fmt.bytes(Int64(current))
    }

    /// The Trash is where a reversible cleanup went, so "put it back" means
    /// opening it — the app deliberately keeps no shadow copy of its own.
    private func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash"))
    }

    private func run() {
        freeText = StorageInfo.read()?.formattedFree ?? Fmt.none
        // No auto-dismiss in either branch now: the panel waits to be closed.
        if reduceMotion {
            appeared = true
            countProgress = 1
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { appeared = true }
        Task {
            let steps = 24
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: 35_000_000)
                let t = Double(i) / Double(steps)
                withAnimation(.linear(duration: 0.03)) {
                    countProgress = 1 - pow(1 - t, 2)
                }
            }
        }
    }
}
