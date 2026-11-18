import AppKit
import SwiftUI

/// Scan coverage stays separate from the selectable cleanup table.
struct ScanSkippedSummaryView: View {
    @EnvironmentObject private var loc: Localizer
    let summary: ScanSkipSummary
    var cached = false
    var titleKey = "scan.skipped.titleFmt"
    var explanationKey = "scan.skipped.explanation"
    var rescan: (() -> Void)? = nil
    @State private var expanded = false
    @State private var offersPrivacySettings = false

    var body: some View {
        if summary.needsNotice {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(loc.s(explanationKey))
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.textSecondary)
                    if cached {
                        Text(loc.s("scan.skipped.cached"))
                            .font(Typo.footnote)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    if !summary.explanationsAvailable {
                        Text(loc.s("scan.skipped.legacy"))
                            .font(Typo.secondary)
                            .foregroundStyle(Palette.warningBody)
                    }
                    ForEach(ScanSkipReason.allCases, id: \.self) { reason in
                        if let count = summary.counts[reason], count > 0 {
                            Text(loc.f("scan.skipped.reasonCountFmt", reasonText(reason), Fmt.count(count)))
                                .font(Typo.secondary)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(summary.paths.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reasonText(item.reason))
                                        .font(Typo.secondary)
                                        .foregroundStyle(Palette.textSecondary)
                                    Text(abbreviated(item.path))
                                        .font(Typo.numeric(11, weight: .regular))
                                        .foregroundStyle(Palette.textTertiary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .help(item.path)
                                    if let rescan {
                                        actions(for: item, rescan: rescan)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    if summary.omittedCount > 0 {
                        Text(loc.f("scan.skipped.omittedFmt", Fmt.count(summary.omittedCount)))
                            .font(Typo.footnote)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(summary.totalCount > 0
                     ? loc.f(titleKey, Fmt.count(summary.totalCount))
                     : loc.s("scan.skipped.legacyTitle"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(14)
            .onChange(of: expanded) { isExpanded in
                if isExpanded && rescan != nil && summary.counts[.unreadable, default: 0] > 0 {
                    offersPrivacySettings = !FullDiskAccess.isGranted()
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for item: ScanSkippedItem, rescan: @escaping () -> Void) -> some View {
        switch item.reason {
        case .inUse, .recent, .verificationLimit, .unreadable:
            if item.reason == .inUse {
                let names = Set(AppActivityGuard.runningCacheOwners(for: URL(fileURLWithPath: item.path))
                    .compactMap { $0.localizedName ?? $0.bundleIdentifier })
                if !names.isEmpty {
                    Text(loc.f("scan.skipped.runningAppsFmt", names.sorted().joined(separator: ", ")))
                        .font(Typo.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            HStack(spacing: 8) {
                if item.reason == .unreadable && offersPrivacySettings {
                    Button(loc.s("scan.skipped.openPrivacy")) { FullDiskAccess.openSettings() }
                        .buttonStyle(.secondaryAction(height: 24))
                }
                Button(loc.s("common.rescan.tooltip"), action: rescan)
                    .buttonStyle(.secondaryAction(height: 24))
            }
            .padding(.top, 4)
        default:
            EmptyView()
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func reasonText(_ reason: ScanSkipReason) -> String {
        switch reason {
        case .inUse: return loc.s("scan.skipped.inUse")
        case .recent: return loc.s("scan.skipped.recent")
        case .safetyProtected: return loc.s("scan.skipped.safetyProtected")
        case .systemProtected: return loc.s("scan.skipped.systemProtected")
        case .unreadable: return loc.s("scan.skipped.unreadable")
        case .verificationLimit: return loc.s("scan.skipped.verificationLimit")
        case .symbolicLink: return loc.s("scan.skipped.symbolicLink")
        case .ownLogs: return loc.s("scan.skipped.ownLogs")
        case .userExcluded: return loc.s("scan.skipped.userExcluded")
        case .managedCache: return loc.s("scan.skipped.managedCache")
        }
    }
}
