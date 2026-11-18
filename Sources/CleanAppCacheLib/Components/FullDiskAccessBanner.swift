import SwiftUI

// MARK: - Full Disk Access banner
//
// `notice(.warning)` at the top of the Detail area: flat surface, 3pt warning
// stripe on the leading edge, no tinted material panel and no 18pt radius.

struct FullDiskAccessBanner: View {
    @EnvironmentObject private var loc: Localizer
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.warningText)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(loc.s("fda.title"))
                    .font(Typo.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                Text(loc.s("fda.subtitle"))
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(loc.s("fda.openSettings")) { FullDiskAccess.openSettings() }
                .buttonStyle(.warningAction)

            IconButton("xmark", label: loc.s("fda.dismiss"), action: onDismiss)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .notice(.warning)
    }
}
