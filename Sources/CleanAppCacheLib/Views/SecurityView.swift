import SwiftUI

// MARK: - Security
//
// A read-only audit: the app never changes a setting, it only opens the pane
// where the user can. That promise is in the screen subtitle instead of in a
// closing strip of its own.
//
// Three blocks: a 220pt score card with the 72pt ring, the yellow banner for the
// single worst finding, and the checks table. A check that carries a risk
// expands in place into `security.risk` / `security.fix` — one open at a time.
//
// The number in the ring is `viewModel.score`, the same property the sidebar
// badge reads. Computing a second score here is how the badge and the screen
// start disagreeing.

public struct SecurityView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: SecurityViewModel
    /// The app uses no springs or bounce; Reduce Motion drops the rest.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The expanded check. The top risk opens by default, and only
    /// one is open at a time; `pickedByUser` keeps that default from overriding a choice
    /// the user has since made — including closing everything.
    @State private var picked: String?
    @State private var pickedByUser = false
    /// When the audit last finished. The manager keeps no timestamp of its own.
    @State private var checkedAt: Date?

    public init() {}

    /// Columns: dot 10 | name + detail | status plate 106 | chevron 16.
    private var spec: TableSpec {
        TableSpec([
            TableCol("dot", width: Row.dot),
            TableCol("name"),
            TableCol("status", width: Row.plate),
            TableCol("chevron", width: Row.chevron, alignment: .trailing),
        ])
    }

    public var body: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("security.title"),
                         subtitle: loc.s("security.subtitle"))
            content
        }
        .background(Palette.background)
        .onChange(of: viewModel.isRunning) { running in
            // Stamped when the run ends, not when it starts: "checked 14:31"
            // has to name the moment the answers on screen were true.
            if !running { checkedAt = Date() }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isRunning && viewModel.checks.isEmpty {
            StateView(.scanning(percent: 0,
                                category: loc.s("security.scanning"),
                                path: "",
                                cancel: nil))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else if !viewModel.hasRun {
            // The scan button lives here and only here — the screen header
            // must not carry a second copy of it.
            StateView(.idle(section: loc.s("security.title"),
                            willFind: loc.s("security.willFind"),
                            scan: { viewModel.run() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else {
            summary
            checksCard
        }
    }

    // MARK: Score card + banner

    private var summary: some View {
        HStack(spacing: Metric.cardGap) {
            scoreCard
                .frame(maxHeight: .infinity)
            banner
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Equal heights without a hardcoded one: the row hugs the taller child
        // and both stretch to it.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var scoreCard: some View {
        HStack(spacing: 16) {
            ring
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Text(verdictNote)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Metric.inset)
        .frame(width: 220, alignment: .leading)
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(loc.s("security.scoreLabel")))
        .accessibilityValue(Text("\(scoreText) — \(verdict)"))
    }

    /// 72×72, stroke 8, track `borderHairline`, opening at twelve o'clock.
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Palette.borderHairline, lineWidth: Row.ringStroke)
            Circle()
                .trim(from: 0, to: scoreFraction)
                .stroke(ringColor, style: StrokeStyle(lineWidth: Row.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : Motion.content, value: scoreFraction)
            Text(scoreText)
                .figure(Typo.scoreFigure)
                .contentTransition(.numericText())
        }
        // The path sits at r=31 inside a 72pt box, so the 8pt stroke lands
        // between 27 and 35 — a 5pt inset on a circle that would otherwise be
        // stroked at r=36 and spill outside the card's padding.
        .padding(5)
        .frame(width: 72, height: 72)
    }

    /// The ring has one warning fill, `#D6A22A`, even for a state that contains a
    /// critical finding — so red is not what "critical" turns the ring. Only a
    /// clean audit changes it, because a yellow 100 would read as a warning.
    private var ringColor: Color {
        guard hasScoredChecks else { return Tone.neutral.fill }
        return findings == 0 ? Tone.success.fill : Tone.warning.fill
    }

    @ViewBuilder
    private var banner: some View {
        if let risk = topRisk {
            HStack(spacing: 16) {
                Text(loc.f("security.topRiskFmt",
                           loc.s(risk.titleKey),
                           detailText(risk)))
                    .font(Typo.body)
                    .foregroundStyle(Palette.warningBody)
                    .lineSpacing(7.15)              // 13pt × 1,55
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let url = risk.settingsURL {
                    Button(loc.s("security.openSettings")) { viewModel.openSettings(url) }
                        .buttonStyle(.warningAction(height: Metric.chip))
                        .accessibilityLabel(Text(loc.f("security.a11y.openSettingsFmt",
                                                       loc.s(risk.titleKey))))
                }
            }
            .padding(Metric.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notice(.warning)
        } else {
            Text(loc.s("security.allClear"))
                .font(Typo.body)
                .foregroundStyle(Palette.successText)
                .lineSpacing(7.15)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Metric.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .notice(.success)
        }
    }

    // MARK: Checks table

    private var checksCard: some View {
        VStack(spacing: 0) {
            // The refresh button belongs in the card header, never in the
            // screen header.
            CardHeader(title: loc.s("security.checks"),
                       detail: checksSummary,
                       height: 44) {
                RefreshStamp(text: checkedStamp,
                             label: loc.s("common.rescan.tooltip")) { viewModel.run() }
            }
            // Once per pass, not once per row: `spec` runs `loc.s()` per column.
            let spec = self.spec
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.checks.enumerated()), id: \.element.id) { index, check in
                        checkGroup(check, spec: spec).staggeredAppear(index: index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    /// The row and, when it is open, its explanation — one divider under both,
    /// so an expanded check reads as a single block.
    private func checkGroup(_ check: SecurityCheck, spec: TableSpec) -> some View {
        let isOpen = openCheckID == check.id
        let expandable = isExpandable(check)
        let rowTone = tone(for: check.status)
        let rowAction: (() -> Void)? = expandable ? { toggle(check) } : nil

        return VStack(spacing: 0) {
            TableRow(spec: spec,
                     height: Row.height,
                     background: isOpen ? expandedFill(check.status) : nil,
                     showsDivider: false,
                     accessibility: loc.f("security.a11y.rowFmt",
                                          loc.s(check.titleKey),
                                          verdictWord(check.status)),
                     action: rowAction) {
                StatusDot(tone: rowTone, size: Row.dot)
                    .column(spec, "dot")

                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.s(check.titleKey))
                        .font(Typo.bodyStrong)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(detailText(check))
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                .column(spec, "name")

                StatusPlate(plateWord(check), tone: rowTone)
                    .column(spec, "status")

                Group {
                    if expandable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .animation(reduceMotion ? nil : Motion.disclosure, value: isOpen)
                    }
                }
                .column(spec, "chevron")
            }

            if isOpen { explanation(check) }

            Rectangle().fill(Palette.rowDivider).frame(height: 1)
        }
    }

    /// Two columns, gap 24: the risk on the left in the status colour, the fix
    /// on the right in 300pt.
    private func explanation(_ check: SecurityCheck) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc.s("security.risk"))
                    .microLabel(tone(for: check.status).text)
                explanationBody(loc.s("sec.\(check.id).risk"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(loc.s("security.fix"))
                    .microLabel()
                explanationBody(loc.s("sec.\(check.id).todo"))
                // The fix text names the pane; this opens it. Without a button
                // here, the banner's one top risk would be the only way to
                // reach a settings pane.
                if let url = check.settingsURL {
                    Button(loc.s("security.openSettings")) { viewModel.openSettings(url) }
                        .buttonStyle(.secondaryAction(height: 28))
                        .padding(.top, 2)
                        .accessibilityLabel(Text(loc.f("security.a11y.openSettingsFmt",
                                                       loc.s(check.titleKey))))
                }
            }
            .frame(width: 300, alignment: .leading)
        }
        .padding(.top, 4)
        .padding(.trailing, Metric.inset)
        .padding(.bottom, Metric.inset)
        // A literal 42 would bake in today's 14pt column gap; taken from the tokens the
        // block stays flush with the check name whatever the gap becomes.
        .padding(.leading, Metric.inset + Row.dot + Metric.colGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(expandedFill(check.status))
    }

    private func explanationBody(_ text: String) -> some View {
        Text(text)
            .font(Typo.secondary)
            .foregroundStyle(Palette.textNav)
            .lineSpacing(7.2)                       // 12pt × 1,6
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ check: SecurityCheck) {
        let next = openCheckID == check.id ? nil : check.id
        pickedByUser = true
        withAnimation(reduceMotion ? nil : Motion.disclosure) { picked = next }
    }

    // MARK: Derived values

    /// Findings, as the verdict counts them: `unknown` is not a finding, it is
    /// an unanswered question, and it is reported separately.
    private var findings: Int { viewModel.failCount + viewModel.warnCount }

    private var unknownCount: Int {
        viewModel.checks.filter { $0.status == .unknown }.count
    }

    /// Nothing could be determined at all. `SecurityViewModel.score` returns 0
    /// there, and a 0 in the ring asserts "maximally insecure" from no evidence.
    private var hasScoredChecks: Bool {
        viewModel.checks.contains { $0.status != .unknown }
    }

    private var scoreText: String {
        hasScoredChecks ? Fmt.count(viewModel.score) : Fmt.none
    }

    private var scoreFraction: Double {
        hasScoredChecks ? Double(viewModel.score) / 100 : 0
    }

    /// 0 findings → "Excellent", 1–2 → "Good", 3+ → "Some findings".
    private var verdict: String {
        guard hasScoredChecks else { return loc.s("security.status.unknown") }
        switch findings {
        case 0:     return loc.s("security.verdict.great")
        case 1...2: return loc.s("security.verdict.good")
        default:    return loc.s("security.verdict.issues")
        }
    }

    private var verdictNote: String {
        hasScoredChecks ? Fmt.plural("plural.issues", findings)
                        : loc.f("security.unknown", unknownCount)
    }

    /// "3 of 8 flagged", plus the checks that returned no answer — they
    /// are missing from both halves of that ratio and would otherwise vanish.
    private var checksSummary: String {
        let flagged = loc.f("security.flaggedFmt", findings, viewModel.checks.count)
        guard unknownCount > 0 else { return flagged }
        return flagged + " · " + loc.f("security.unknown", unknownCount)
    }

    private var checkedStamp: String? {
        guard let checkedAt else { return nil }
        return loc.f("common.checkedAt", Fmt.clock(checkedAt))
    }

    /// The banner's subject. The view model already sorts worst-first, so the
    /// first failure — or the first warning — is the one to lead with.
    private var topRisk: SecurityCheck? {
        viewModel.checks.first { $0.status == .fail }
            ?? viewModel.checks.first { $0.status == .warn }
    }

    private var openCheckID: String? {
        pickedByUser ? picked : topRisk.flatMap { isExpandable($0) ? $0.id : nil }
    }

    /// Only a check that carries a risk expands, and only if the copy for it
    /// exists — a check added later without an explanation stays a plain row
    /// rather than opening onto a raw key.
    private func isExpandable(_ check: SecurityCheck) -> Bool {
        guard check.status == .fail || check.status == .warn else { return false }
        return loc.opt("sec.\(check.id).risk") != nil
    }

    private func tone(for status: SecurityCheck.Status) -> Tone {
        switch status {
        case .pass:    return .success
        case .warn:    return .warning
        case .fail:    return .danger
        case .unknown: return .neutral
        }
    }

    private func expandedFill(_ status: SecurityCheck.Status) -> Color {
        status == .fail ? Palette.expandBadRow : Palette.expandWarnRow
    }

    /// The plate labels the **setting**, not the verdict: "Remote login · Disabled"
    /// is a green row, and "Automatic login · Enabled" is a red one. Which
    /// state a check found is recorded only in the suffix of its detail key, so
    /// that is what the plate reads; the dot and the tint carry the verdict.
    private func plateWord(_ check: SecurityCheck) -> String {
        switch check.status {
        case .warn:    return loc.s("security.plate.warn")
        case .unknown: return loc.s("security.plate.unknown")
        case .pass, .fail:
            return loc.s(check.detailKey.hasSuffix(".on") ? "security.plate.on"
                                                          : "security.plate.off")
        }
    }

    /// Verdict in words, for VoiceOver — the plate says "Disabled", which on its
    /// own does not say whether that is good.
    private func verdictWord(_ status: SecurityCheck.Status) -> String {
        loc.s("security.status.\(status.rawValue)")
    }

    /// Works around a known defect in the guest-account check: it
    /// hands back `sec.guest.off` — "the guest account is disabled" — even when
    /// its probe returned nothing at all. Any unknown whose detail key is not an
    /// `.unknown` variant gets the neutral reason instead of that claim.
    private func detailText(_ check: SecurityCheck) -> String {
        if check.status == .unknown, !check.detailKey.hasSuffix(".unknown") {
            return loc.s("security.unknownReason")
        }
        return loc.s(check.detailKey)
    }
}

// MARK: - Row geometry

private enum Row {
    /// Row 56pt, dot 10pt, status plate a fixed 106pt.
    static let height: CGFloat = 56
    static let dot: CGFloat = 10
    static let plate: CGFloat = 106
    static let chevron: CGFloat = 16
    static let ringStroke: CGFloat = 8
}
