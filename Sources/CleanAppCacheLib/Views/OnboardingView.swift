import SwiftUI
import AppKit

// MARK: - First-launch onboarding
//
// 520×640 with a scrollable middle. A fixed-size sheet without a `ScrollView`
// breaks as soon as a translation runs two lines longer than the English: the
// buttons are pushed past the bottom edge with no way to scroll to them — on
// the one screen the user cannot skip.
//
// The content does not advertise features ("scan, then decide", "live
// monitoring"), which a first-run user has no way to judge. The
// only question a first run actually raises is "what is this about to delete",
// so the three numbered points are the three safety rules from the README:
// everything is reversible by default, risky items are never preselected, apps
// are matched strictly by bundle ID.
//
// Chrome follows the standard skeleton — fixed head, scrolling body, fixed
// footer — even though this is a sheet rather than a screen with a ScreenHeader.

public struct OnboardingView: View {
    @EnvironmentObject private var loc: Localizer
    let onDone: () -> Void

    /// Sampled in `onAppear` rather than read from the body: `isGranted()` opens
    /// the TCC database to probe the permission, which is far too expensive for
    /// a value SwiftUI re-reads on every render. Re-probing when the app comes
    /// back to the front is what lets the banner resolve itself after the user
    /// grants access in System Settings and switches back — the same pattern
    /// `ContentView` uses for its own banner.
    @State private var hasFullDiskAccess = true

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.borderStrong)
            rules
            Divider().overlay(Palette.borderStrong)
            footer
        }
        .frame(width: 520, height: 640)
        .background(Palette.background)
        .onAppear { hasFullDiskAccess = FullDiskAccess.isGranted() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                // The 7pt accent square is the sidebar's identity mark, not a
                // decoration: it is the one place accent appears on this sheet
                // besides the point numbers and the primary button.
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 7, height: 7)
                Text(verbatim: "CleanAppCache").microLabel(Palette.textSecondary)
            }

            Text(loc.s("onboard.headline"))
                .font(Typo.text(24, weight: .semibold))
                .tracking(-0.48)                     // −0.02em at 24pt
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Text(loc.s("onboard.lede"))
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    // MARK: The three safety rules (scrollable)

    private var rules: some View {
        ScrollView {
            VStack(spacing: 0) {
                rule(index: 0,
                     title: loc.s("onboard.rule1.title"),
                     body: loc.s("onboard.rule1.body"))
                rule(index: 1,
                     title: loc.s("onboard.rule2.title"),
                     body: loc.s("onboard.rule2.body"))
                rule(index: 2,
                     title: loc.s("onboard.rule3.title"),
                     body: loc.s("onboard.rule3.body"))

                accessNotice
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rule(index: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Monospaced so 01/02/03 sit on the same optical column.
            Text(String(format: "%02d", index + 1))
                .font(Typo.numeric(14))
                .foregroundStyle(Palette.accent)
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Typo.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(body)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderHairline).frame(height: 1)
        }
        // One VoiceOver stop per rule: the number, the rule and its explanation
        // are one statement, and reading them as three items breaks it apart.
        .accessibilityElement(children: .combine)
        .staggeredAppear(index: index)
    }

    // MARK: Full Disk Access

    // Stated as words in both directions. Asking for access unconditionally
    // would tell a user who has already granted it that their results will be
    // incomplete. Reduce Motion is handled by `staggeredAppear` above, so this
    // view does not need to read the environment value itself.
    @ViewBuilder
    private var accessNotice: some View {
        if hasFullDiskAccess {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tone.success.text)
                Text(loc.s("onboard.access.granted"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .padding(.trailing, 13)
            .padding(.vertical, 12)
            .notice(.success)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(loc.s("onboard.access.body"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Button(loc.s("onboard.fda")) { FullDiskAccess.openSettings() }
                    .buttonStyle(.warningAction)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Leading padding clears the notice's 3pt stripe.
            .padding(.leading, 14)
            .padding(.trailing, 13)
            .padding(.vertical, 13)
            .notice(.warning)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if !hasFullDiskAccess {
                // Granting access is optional, and saying so here is what keeps
                // the warning above from reading as a wall.
                Text(loc.s("onboard.access.later"))
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button { onDone() } label: {
                // The return glyph names the shortcut the button already answers
                // to; VoiceOver reads the label below instead of the symbol.
                Text(loc.s("onboard.start") + "  ↩")
            }
            .buttonStyle(PrimaryButtonStyle(height: 34))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(Text(loc.s("onboard.start")))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Palette.surfaceRaised)
    }
}
