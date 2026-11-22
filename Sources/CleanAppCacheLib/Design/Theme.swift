import SwiftUI

// MARK: - Design tokens
//
// The "Paper" direction: a daylight tool. White cards on a warm grey ground,
// air between blocks, and the only heavy thing on screen is the figures. Colour
// carries category, risk and selection — nothing else.
//
// The palette is closed: no colour outside this token set may be introduced.
// The light values are the designer's reference set; the dark set is derived
// from it, structurally identical to light (same cards, same radii).
//
// Views must read tokens through `Palette` rather than hardcoding colours.

public struct DesignTokens: Sendable {

    // MARK: Surfaces and borders

    /// Content area behind the cards.
    public let background: Color
    /// Sidebar, cards, tables.
    public let surfaceRaised: Color
    /// Search fields, secondary buttons, segment tracks.
    public let surfaceControl: Color
    /// Bottom action bar, risk-group headers.
    public let surfaceFooter: Color
    /// Selected / expanded row.
    public let selectedRow: Color
    /// Picked row in Storage and History.
    public let pickedRow: Color

    /// Card, sidebar and window borders.
    public let borderStrong: Color
    /// Dividers inside a card, gauge tracks.
    public let borderHairline: Color
    /// Divider between table rows.
    public let rowDivider: Color
    /// Border of an unchecked checkbox.
    public let checkboxBorder: Color
    /// Track of an off toggle.
    public let toggleOff: Color
    /// Used part of the disk gauge in the cleanup panel.
    public let barUsedNeutral: Color
    /// "Free" segment of the distribution strip.
    public let freeSegment: Color

    // MARK: Text

    /// Titles, values, row names.
    public let textPrimary: Color
    /// Inactive sidebar items, body of an expanded explanation.
    public let textNav: Color
    /// Captions, secondary text.
    public let textSecondary: Color
    /// Table headers, units, metadata, paths.
    public let textTertiary: Color

    // MARK: Accent

    /// Fills: buttons, checkboxes, gauges, the chart line.
    public let accent: Color
    /// The accent as text — contrast-corrected for the card surface.
    public let accentText: Color
    /// Active sidebar item, active chip, selected menu item.
    public let accentTint: Color
    /// Active chip border, "cleanable" card, history chart columns.
    public let accentBorder: Color
    /// E-cores, share bars in scan results.
    public let accentBarLight: Color
    /// Share bar of a child process.
    public let accentChildBar: Color
    /// "Clean" button with an empty selection.
    public let accentDisabled: Color
    /// The accent on a dark surface (History hero, toast).
    public let accentOnDark: Color

    // MARK: Semantic

    public let successFill: Color
    public let successTint: Color
    public let successText: Color

    public let warningFill: Color
    public let warningTint: Color
    public let warningText: Color
    /// Border of the yellow banner.
    public let warningBorder: Color
    /// The banner's button; also "not opened in a long time".
    public let warningButton: Color
    /// Body text inside the yellow banner.
    public let warningBody: Color

    public let dangerFill: Color
    public let dangerTint: Color
    public let dangerText: Color

    /// Background of an expanded security check — warning / critical.
    public let expandWarnRow: Color
    public let expandBadRow: Color

    /// Share bars of the three cleanup risk groups.
    public let riskSafeBar: Color
    public let riskCheckBar: Color
    public let riskPermanentBar: Color

    /// Dot in the toast.
    public let toastDot: Color

    // MARK: Categories

    /// Eleven storage categories, in the order `StorageCategory` declares them.
    public let breakdown: [Color]
    /// Six file kinds on the Large Files screen.
    public let fileKinds: [Color]

    // MARK: Dark hero
    //
    // The History hero is the single dark surface in the app and keeps the same
    // colour in both themes — that is what makes it read as an exception.

    public let heroDark: Color
    public let heroDarkText: Color
    public let heroDarkSecondary: Color
}

public extension AppTheme {
    /// Token table for this theme. `light` is the reference set; `dark` is
    /// derived from it — parity by structure, not by mood.
    ///
    /// Both tables are built once. As a computed `switch` every `Palette.*`
    /// read would construct all 46 `Color`s plus two arrays — about 550
    /// allocations per table row per render, visible on every hover and monitor tick.
    var tokens: DesignTokens { self == .light ? Self.lightTokens : Self.darkTokens }

    private static let lightTokens = DesignTokens(
        background:      Color(hex: 0xF6F6F4),
        surfaceRaised:   Color(hex: 0xFFFFFF),
        surfaceControl:  Color(hex: 0xF6F6F4),
        surfaceFooter:   Color(hex: 0xFBFBF9),
        selectedRow:     Color(hex: 0xFBFBFE),
        pickedRow:       Color(hex: 0xF7F7FB),
        borderStrong:    Color(hex: 0xE2E2DE),
        borderHairline:  Color(hex: 0xEFEFEC),
        rowDivider:      Color(hex: 0xF4F4F1),
        checkboxBorder:  Color(hex: 0x87878E),
        toggleOff:       Color(hex: 0x87878E),
        barUsedNeutral:  Color(hex: 0xD5D5CE),
        freeSegment:     Color(hex: 0xE4E4DF),

        textPrimary:     Color(hex: 0x16161A),
        textNav:         Color(hex: 0x3A3A42),
        textSecondary:   Color(hex: 0x6A6A72),
        // Small paths and headers need text contrast even on tinted rows.
        textTertiary:    Color(hex: 0x6B6B73),

        accent:          Color(hex: 0x6C63E0),
        accentText:      Color(hex: 0x5249C4),
        accentTint:      Color(hex: 0xEEEDFC),
        accentBorder:    Color(hex: 0xCFCBF6),
        accentBarLight:  Color(hex: 0xB9B5EE),
        accentChildBar:  Color(hex: 0xC6C2F2),
        accentDisabled:  Color(hex: 0xC9C6EC),
        accentOnDark:    Color(hex: 0xA79FF5),

        successFill:     Color(hex: 0x2E9E52),
        successTint:     Color(hex: 0xE9F6EE),
        successText:     Color(hex: 0x1F7A3C),
        warningFill:     Color(hex: 0xD6A22A),
        warningTint:     Color(hex: 0xFFF6E8),
        warningText:     Color(hex: 0x8A5A00),
        warningBorder:   Color(hex: 0xF2DFBE),
        warningButton:   Color(hex: 0xB37200),
        warningBody:     Color(hex: 0x7A5A18),
        dangerFill:      Color(hex: 0xC0392B),
        dangerTint:      Color(hex: 0xFDECEA),
        dangerText:      Color(hex: 0xB02218),
        expandWarnRow:   Color(hex: 0xFFFCF6),
        expandBadRow:    Color(hex: 0xFFF9F8),
        riskSafeBar:     Color(hex: 0x7BBE95),
        riskCheckBar:    Color(hex: 0xE2C173),
        riskPermanentBar: Color(hex: 0xDB8B82),
        toastDot:        Color(hex: 0x4ADE80),

        breakdown: StorageCategory.lightPalette,
        fileKinds: FileKind.lightPalette,

        heroDark:          Color(hex: 0x16161A),
        heroDarkText:      Color(hex: 0xFFFFFF),
        heroDarkSecondary: Color(hex: 0x9A9AA4)
    )

    // Eleven values are fixed by the design; the rest are derived at the same
    // structural role and lightness relationship as the light set. Four of the
    // derived values are lifted to pass WCAG 2.x: a straight derivation puts
    // `textTertiary` at 3.3:1 on `surfaceControl` and the unchecked checkbox
    // border at 1.6:1 on a card.
    // The ladder sits in graphite, not near-black: a `background` of #101014
    // with near-white text is a 17:1 wall that is hard to look at for long.
    // Every ground is lifted ~5–6 L* and the white softened, capping body text
    // at ~13:1 while all twenty measured WCAG pairs stay above their thresholds.
    private static let darkTokens = DesignTokens(
        background:      Color(hex: 0x1E1E23),
        surfaceRaised:   Color(hex: 0x26262C),
        surfaceControl:  Color(hex: 0x2E2E36),
        surfaceFooter:   Color(hex: 0x2A2A31),
        selectedRow:     Color(hex: 0x2B2A3C),
        pickedRow:       Color(hex: 0x302E44),
        borderStrong:    Color(hex: 0x3C3C46),
        borderHairline:  Color(hex: 0x35353E),
        rowDivider:      Color(hex: 0x2E2E36),
        // 3.57:1 on `surfaceRaised` — the border is the only thing that says
        // "checkbox", and the off-track is the only thing behind the knob.
        checkboxBorder:  Color(hex: 0x7A7A8C),
        toggleOff:       Color(hex: 0x7A7A8C),
        barUsedNeutral:  Color(hex: 0x45454F),
        freeSegment:     Color(hex: 0x32323B),

        textPrimary:     Color(hex: 0xE6E6EC),
        textNav:         Color(hex: 0xC6C6D0),
        textSecondary:   Color(hex: 0x9E9EAA),
        // 4.8:1 on `surfaceControl`, 6.0:1 on `background`. Same neutral hue
        // as the rest of the ladder (R = G, B = R + 12).
        textTertiary:    Color(hex: 0x9A9AA6),

        // The light accent: a white 13pt label on a lifted #7B72F0 would be
        // 3.8:1; on this it is 4.7:1, and as a fill it still clears 3:1 on
        // a card (3.2:1 on the graphite `surfaceRaised`).
        accent:          Color(hex: 0x6C63E0),
        accentText:      Color(hex: 0xA79FF5),
        accentTint:      Color(hex: 0x2A2745),
        accentBorder:    Color(hex: 0x3E3870),
        accentBarLight:  Color(hex: 0x5A52A8),
        accentChildBar:  Color(hex: 0x4A4390),
        accentDisabled:  Color(hex: 0x474169),
        accentOnDark:    Color(hex: 0xA79FF5),

        successFill:     Color(hex: 0x2E9E52),
        successTint:     Color(hex: 0x1E3226),
        successText:     Color(hex: 0x5CC77E),
        warningFill:     Color(hex: 0xD6A22A),
        warningTint:     Color(hex: 0x362C1A),
        warningText:     Color(hex: 0xE6B95A),
        warningBorder:   Color(hex: 0x473A20),
        warningButton:   Color(hex: 0xD6A22A),
        warningBody:     Color(hex: 0xD9C08A),
        dangerFill:      Color(hex: 0xC0392B),
        dangerTint:      Color(hex: 0x372220),
        dangerText:      Color(hex: 0xE8776B),
        expandWarnRow:   Color(hex: 0x2F2718),
        expandBadRow:    Color(hex: 0x2F211E),
        riskSafeBar:     Color(hex: 0x7BBE95),
        riskCheckBar:    Color(hex: 0xE2C173),
        riskPermanentBar: Color(hex: 0xDB8B82),
        toastDot:        Color(hex: 0x4ADE80),

        // The eleven category hues are mid-tone by construction and
        // hold their identity on either ground, so they do not fork.
        breakdown: StorageCategory.lightPalette,
        fileKinds: FileKind.lightPalette,

        // Still the one surface deeper than `background`, but not so dark
        // that it reads as a black hole beside the graphite ground.
        heroDark:          Color(hex: 0x141419),
        heroDarkText:      Color(hex: 0xF2F2F7),
        heroDarkSecondary: Color(hex: 0x9A9AA4)
    )
}

// MARK: - Categories
//
// Colour is bound to the category, not to its rank in the list, so a category
// keeps its hue when the sort order changes. The raw values match the names
// `StorageManager.getBreakdown` emits.

public enum StorageCategory: String, CaseIterable, Sendable {
    case other        = "Other"
    case applications = "Applications"
    case movies       = "Movies"
    case pictures     = "Pictures"
    case downloads    = "Downloads"
    case userCaches   = "User Caches"
    case music        = "Music"
    case documents    = "Documents"
    case desktop      = "Desktop"
    case userApps     = "User Apps"
    case userLogs     = "User Logs"
    case applicationSupport = "Application Support"
    case containers   = "Containers"
    case developer    = "Developer"
    case mailMessages = "Mail and Messages"
    case iCloudDrive  = "iCloud Drive"
    case otherLibrary = "Other Library"
    case yourFolders  = "Your folders"
    case hiddenFolders = "Hidden folders"
    case systemData   = "System Data"
    case serviceVolumes = "macOS and Service Volumes"

    /// Localization key for the display name. The project already translates
    /// the data layer's raw names under `bk.<name>`, so the category reuses
    /// them instead of introducing a parallel set.
    public var titleKey: String { "bk." + rawValue }

    /// Category hues, in `allCases` order.
    static let lightPalette: [Color] = [
        Color(hex: 0x8C86E8),  // Other
        Color(hex: 0x4A8FD8),  // Applications
        Color(hex: 0xC77BC0),  // Movies
        Color(hex: 0x3F8A6B),  // Pictures
        Color(hex: 0x8B7BE8),  // Downloads
        Color(hex: 0xD2372B),  // User Caches
        Color(hex: 0x6C63E0),  // Music
        Color(hex: 0x9A833F),  // Documents
        Color(hex: 0x9A9AA2),  // Desktop
        Color(hex: 0x4AA0A0),  // User Apps
        Color(hex: 0xB08A3F),  // User Logs
        Color(hex: 0x526ECC),  // Application Support
        Color(hex: 0xBA6C46),  // Containers
        Color(hex: 0x7B56B0),  // Developer
        Color(hex: 0xBB5678),  // Mail and Messages
        Color(hex: 0x398FB5),  // iCloud Drive
        Color(hex: 0xA56B90),  // Other Library
        Color(hex: 0x278777),  // Your folders
        Color(hex: 0xBA813C),  // Hidden folders
        Color(hex: 0x65788F),  // System Data
        Color(hex: 0x666799),  // macOS and Service Volumes
    ]

    var paletteIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    @MainActor public var color: Color {
        Palette.tokens.breakdown[paletteIndex]
    }

    /// Maps a raw breakdown name onto a category. Unknown names fall back to
    /// `other` rather than picking a hue that already belongs to something else.
    public static func from(rawName: String) -> StorageCategory {
        StorageCategory(rawValue: rawName) ?? .other
    }
}

/// File kinds on the Large Files screen.
public enum FileKind: String, Codable, CaseIterable, Sendable {
    case video, archive, diskImage, audio, data, project

    public var titleKey: String { "kind.\(rawValue)" }

    static let lightPalette: [Color] = [
        Color(hex: 0xC77BC0),  // Video
        Color(hex: 0x9A833F),  // Archive
        Color(hex: 0x4A8FD8),  // Disk image
        Color(hex: 0x6C63E0),  // Audio
        Color(hex: 0x3F8A6B),  // Data
        Color(hex: 0x9A9AA2),  // Project
    ]

    @MainActor public var color: Color {
        Palette.tokens.fileKinds[Self.allCases.firstIndex(of: self) ?? 0]
    }

    /// Classifies by extension. Anything unrecognised is `data` — the neutral
    /// bucket — so a new extension never borrows another kind's colour.
    public static func of(_ filename: String) -> FileKind {
        switch (filename as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv":
            return .video
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "xip", "pkg", "tgz":
            return .archive
        case "dmg", "iso", "img", "sparsebundle", "sparseimage", "vmdk", "qcow2":
            return .diskImage
        case "mp3", "aac", "m4a", "wav", "aiff", "flac", "alac", "ogg":
            return .audio
        case "xcodeproj", "xcworkspace", "playground", "sketch", "fig",
             "psd", "ai", "blend", "aep", "logicx", "band":
            return .project
        default:
            return .data
        }
    }
}

// MARK: - Palette

public enum Palette {
    @MainActor public static var tokens: DesignTokens { ThemeManager.shared.theme.tokens }

    // Surfaces
    @MainActor public static var background: Color { tokens.background }
    @MainActor public static var surfaceRaised: Color { tokens.surfaceRaised }
    @MainActor public static var surfaceControl: Color { tokens.surfaceControl }
    @MainActor public static var surfaceFooter: Color { tokens.surfaceFooter }
    @MainActor public static var selectedRow: Color { tokens.selectedRow }
    @MainActor public static var pickedRow: Color { tokens.pickedRow }

    // Borders
    @MainActor public static var borderStrong: Color { tokens.borderStrong }
    @MainActor public static var borderHairline: Color { tokens.borderHairline }
    @MainActor public static var rowDivider: Color { tokens.rowDivider }
    @MainActor public static var checkboxBorder: Color { tokens.checkboxBorder }
    @MainActor public static var toggleOff: Color { tokens.toggleOff }
    @MainActor public static var barUsedNeutral: Color { tokens.barUsedNeutral }
    @MainActor public static var freeSegment: Color { tokens.freeSegment }

    // Text
    @MainActor public static var textPrimary: Color { tokens.textPrimary }
    @MainActor public static var textNav: Color { tokens.textNav }
    @MainActor public static var textSecondary: Color { tokens.textSecondary }
    @MainActor public static var textTertiary: Color { tokens.textTertiary }

    // Accent
    @MainActor public static var accent: Color { tokens.accent }
    @MainActor public static var accentText: Color { tokens.accentText }
    @MainActor public static var accentTint: Color { tokens.accentTint }
    @MainActor public static var accentBorder: Color { tokens.accentBorder }
    @MainActor public static var accentBarLight: Color { tokens.accentBarLight }
    @MainActor public static var accentChildBar: Color { tokens.accentChildBar }
    @MainActor public static var accentDisabled: Color { tokens.accentDisabled }
    @MainActor public static var accentOnDark: Color { tokens.accentOnDark }

    // Semantic
    @MainActor public static var successFill: Color { tokens.successFill }
    @MainActor public static var successTint: Color { tokens.successTint }
    @MainActor public static var successText: Color { tokens.successText }
    @MainActor public static var warningFill: Color { tokens.warningFill }
    @MainActor public static var warningTint: Color { tokens.warningTint }
    @MainActor public static var warningText: Color { tokens.warningText }
    @MainActor public static var warningBorder: Color { tokens.warningBorder }
    @MainActor public static var warningButton: Color { tokens.warningButton }
    @MainActor public static var warningBody: Color { tokens.warningBody }
    @MainActor public static var dangerFill: Color { tokens.dangerFill }
    @MainActor public static var dangerTint: Color { tokens.dangerTint }
    @MainActor public static var dangerText: Color { tokens.dangerText }
    @MainActor public static var expandWarnRow: Color { tokens.expandWarnRow }
    @MainActor public static var expandBadRow: Color { tokens.expandBadRow }
    @MainActor public static var toastDot: Color { tokens.toastDot }

    // Dark hero
    @MainActor public static var heroDark: Color { tokens.heroDark }
    @MainActor public static var heroDarkText: Color { tokens.heroDarkText }
    @MainActor public static var heroDarkSecondary: Color { tokens.heroDarkSecondary }

    /// Segment colour of the storage distribution strip. Index wraps.
    @MainActor public static func breakdown(_ index: Int) -> Color {
        let set = tokens.breakdown
        return set[((index % set.count) + set.count) % set.count]
    }

    /// Share bar inside a table: the accent when the row is selected, the light
    /// accent otherwise.
    @MainActor public static func bar(selected: Bool) -> Color {
        selected ? accent : accentBarLight
    }
}

// MARK: - Geometry

public enum Metric {

    // Radii — nothing rounder than 12.
    /// Window / sheet.
    public static let window: CGFloat = 12
    /// Card, table.
    public static let card: CGFloat = 10
    /// Button, sidebar row, search field.
    public static let control: CGFloat = 8
    /// Primary action button.
    public static let action: CGFloat = 9
    /// Filter dropdown.
    public static let menu: CGFloat = 9
    /// Segment inside a track.
    public static let segment: CGFloat = 6
    /// Checkbox.
    public static let checkboxRadius: CGFloat = 5

    // Spacing.
    /// Content area horizontal inset.
    public static let gutter: CGFloat = 26
    public static let contentTop: CGFloat = 22
    public static let contentBottom: CGFloat = 24
    /// Vertical gap between blocks.
    public static let blockGap: CGFloat = 16
    /// Gap between cards in a row.
    public static let cardGap: CGFloat = 10
    /// Horizontal inset inside a table row.
    public static let inset: CGFloat = 18
    /// Gap between columns.
    public static let colGap: CGFloat = 16
    /// Step between elements within a row.
    public static let rowGap: CGFloat = 12

    // Sidebar.
    public static let sidebar: CGFloat = 236
    public static let sidebarRow: CGFloat = 36
    public static let sidebarGroupHeader: CGFloat = 30
    public static let sidebarSettingsRow: CGFloat = 32

    // Tables.
    public static let tableHeader: CGFloat = 32
    public static let nestedTableHeader: CGFloat = 30
    public static let sectionHeader: CGFloat = 34
    /// Regular density; `rowCompact` is the Settings alternative.
    public static let row: CGFloat = 40
    public static let rowCompact: CGFloat = 32
    /// Two-line row: name over path.
    public static let rowDetailed: CGFloat = 48
    /// Scan-result row.
    public static let rowResult: CGFloat = 52
    /// Scan-result row with a description line between the name and the path.
    public static let rowResultDetailed: CGFloat = 68
    public static let nestedRow: CGFloat = 34
    public static let footnoteRow: CGFloat = 34
    public static let bottomBar: CGFloat = 60
    public static let utilityStrip: CGFloat = 44

    /// Right-hand detail panel; each screen sets its own width.
    public static let heroColumn: CGFloat = 288

    // Controls.
    public static let checkboxGlyph: CGFloat = 20
    public static let tapTarget: CGFloat = 28
    public static let iconButton: CGFloat = 26
    public static let refreshButton: CGFloat = 26
    public static let chip: CGFloat = 32
    public static let secondaryButton: CGFloat = 32
    public static let primaryButton: CGFloat = 34
    public static let heroButton: CGFloat = 40
    public static let toggleWidth: CGFloat = 40
    public static let toggleHeight: CGFloat = 24

    /// Minimum window width.
    public static let minWindowWidth: CGFloat = 1100
}

/// Card and menu shadows. Values are the CSS ones halved for SwiftUI's
/// radius convention, which is roughly half the CSS blur.
public enum Shadow {
    public static let cardColor = Color.black.opacity(0.03)
    public static let cardRadius: CGFloat = 1
    public static let cardY: CGFloat = 1

    public static let menuColor = Color.black.opacity(0.14)
    public static let menuRadius: CGFloat = 14
    public static let menuY: CGFloat = 12

    public static let toastColor = Color.black.opacity(0.30)
    public static let toastRadius: CGFloat = 17
    public static let toastY: CGFloat = 12
}

// MARK: - Typography
//
// System font for text, SF Mono for **every** number, always. The unit beside a
// figure is always smaller than the figure and painted `textTertiary`.

public enum Typo {
    /// Monospaced figures. All numbers use this: sizes, percentages, PIDs,
    /// timestamps, paths.
    public static func numeric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Plain text at a scale value.
    public static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // Text roles.
    public static var screenTitle: Font { .system(size: 26, weight: .semibold) }
    public static var cardTitle: Font   { .system(size: 13, weight: .semibold) }
    public static var body: Font        { .system(size: 13) }
    public static var bodyStrong: Font  { .system(size: 13, weight: .semibold) }
    public static var secondary: Font   { .system(size: 12) }
    public static var footnote: Font    { .system(size: 11) }
    public static var micro: Font       { .system(size: 10, weight: .bold) }
    public static var tempCaption: Font { .system(size: 8, weight: .bold) }

    // Figure roles — size paired with its specified tracking.
    public static let heroFigure    = (size: CGFloat(46), tracking: CGFloat(-2.4))
    public static let bigFigure     = (size: CGFloat(44), tracking: CGFloat(-2.2))
    public static let scanPercent   = (size: CGFloat(38), tracking: CGFloat(-1.7))
    public static let cardFigure    = (size: CGFloat(30), tracking: CGFloat(-1.4))
    public static let metricFigure  = (size: CGFloat(26), tracking: CGFloat(-1.1))
    public static let scoreFigure   = (size: CGFloat(21), tracking: CGFloat(0))
    public static let barTotal      = (size: CGFloat(16), tracking: CGFloat(0))

    public static let screenTitleTracking: CGFloat = -0.6
}

public extension View {
    /// Uppercase micro-label: 10/700, tracking 0.9 — table and group headers.
    @MainActor func microLabel(_ color: Color? = nil) -> some View {
        self.font(Typo.micro)
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(color ?? Palette.textTertiary)
    }

    /// Word-form status/risk label: 10/700, tracking 0.6. Risk is never carried
    /// by colour alone.
    @MainActor func riskLabel(_ color: Color) -> some View {
        self.font(Typo.micro)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// A figure at one of the figure-role sizes, monospaced with its tracking applied.
    @MainActor func figure(_ role: (size: CGFloat, tracking: CGFloat),
                           color: Color? = nil) -> some View {
        self.font(Typo.numeric(role.size))
            .tracking(role.tracking)
            .foregroundStyle(color ?? Palette.textPrimary)
            .lineLimit(1)
    }
}

/// A figure with its unit: the unit is smaller and `textTertiary`.
public struct Figure: View {
    let value: String
    let unit: String?
    let role: (size: CGFloat, tracking: CGFloat)
    let color: Color?

    public init(_ value: String, unit: String? = nil,
                role: (size: CGFloat, tracking: CGFloat) = Typo.cardFigure,
                color: Color? = nil) {
        self.value = value
        self.unit = unit
        self.role = role
        self.color = color
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // In a narrow card the figure shrinks instead of truncating to
            // "6.…"; the unit keeps its size, since a clipped unit is the part
            // a reader cannot reconstruct.
            Text(value).figure(role, color: color)
                .minimumScaleFactor(0.5)
            if let unit {
                Text(unit)
                    .font(Typo.numeric(unitSize, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// Unit sizes range from 14 to 18pt. Two sizes are fixed by the design
    /// — a 26pt figure takes a 14pt unit, a 30pt figure takes 15pt — which is a
    /// quarter-point per point of figure, clamped to the stated range.
    private var unitSize: CGFloat {
        min(18, max(14, 14 + (role.size - 26) / 4))
    }
}

// MARK: - Tone

public enum Tone: Sendable, Hashable {
    case info, success, warning, danger
    /// "We could not determine this." Distinct from `info`, which is the accent
    /// and reads as a claim; a check that failed to run must not look like one
    /// that passed with a note.
    case neutral

    @MainActor public var fill: Color {
        switch self {
        case .neutral: return Palette.textTertiary
        case .info:    return Palette.accent
        case .success: return Palette.successFill
        case .warning: return Palette.warningFill
        case .danger:  return Palette.dangerFill
        }
    }

    /// Legible variant for text and glyphs on a card.
    @MainActor public var text: Color {
        switch self {
        case .neutral: return Palette.textSecondary
        case .info:    return Palette.accentText
        case .success: return Palette.successText
        case .warning: return Palette.warningText
        case .danger:  return Palette.dangerText
        }
    }

    /// Pale background for a status plate.
    @MainActor public var tint: Color {
        switch self {
        case .neutral: return Palette.surfaceControl
        case .info:    return Palette.accentTint
        case .success: return Palette.successTint
        case .warning: return Palette.warningTint
        case .danger:  return Palette.dangerTint
        }
    }
}

// MARK: - Surfaces

public extension View {
    /// The card: white, `borderStrong`, radius 10, shadow `0 1px 2px 3%`.
    func card() -> some View {
        modifier(CardModifier(border: nil, radius: Metric.card))
    }

    /// A card with an emphasised border — the "cleanable" card uses `accentBorder`.
    func card(border: Color) -> some View {
        modifier(CardModifier(border: border, radius: Metric.card))
    }

    /// The yellow risk banner and its siblings.
    func notice(_ tone: Tone) -> some View {
        modifier(NoticeModifier(tone: tone))
    }
}

private struct CardModifier: ViewModifier {
    let border: Color?
    let radius: CGFloat
    @ObservedObject private var themeManager = ThemeManager.shared

    init(border: Color?, radius: CGFloat) {
        self.border = border
        self.radius = radius
    }

    func body(content: Content) -> some View {
        let t = themeManager.theme.tokens
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(t.surfaceRaised))
            .overlay(shape.strokeBorder(border ?? t.borderStrong, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: Shadow.cardColor, radius: Shadow.cardRadius, x: 0, y: Shadow.cardY)
    }
}

private struct NoticeModifier: ViewModifier {
    let tone: Tone
    @ObservedObject private var themeManager = ThemeManager.shared

    func body(content: Content) -> some View {
        let t = themeManager.theme.tokens
        let (fill, border): (Color, Color) = {
            switch tone {
            case .neutral: return (t.surfaceControl, t.borderStrong)
            case .info:    return (t.accentTint, t.accentBorder)
            case .success: return (t.successTint, t.successFill.opacity(0.30))
            case .warning: return (t.warningTint, t.warningBorder)
            case .danger:  return (t.dangerTint, t.dangerText.opacity(0.22))
            }
        }()
        let shape = RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
        return content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .clipShape(shape)
    }
}

// MARK: - Button styles
//
// Each style renders a dedicated body `View` rather than building the hierarchy
// inline. SwiftUI only installs `@Environment` on the style instance it owns, so
// a style whose `makeBody` reads `@Environment(\.isEnabled)` directly always
// reports `true` when another style forwards to it.

private enum ButtonFill {
    case primary(Color?)
    case secondary
    case warning
    case danger
}

private struct ButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: ButtonFill
    let height: CGFloat
    let hPadding: CGFloat
    let radius: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, hPadding)
            .frame(height: height)
            .background(shape.fill(background))
            .overlay {
                if let border {
                    shape.strokeBorder(border, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 1)
            .animation(Motion.buttonPress, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch fill {
        // The label on `accentDisabled` must stay legible — white on the
        // pale light-theme disabled fill is only 1.6:1. `accentText` is 4.1:1 there
        // and white stays 11:1 on the dark fill.
        case .primary:
            if isEnabled { return .white }
            return ThemeManager.shared.theme.isDark ? .white : Palette.accentText
        case .secondary: return isEnabled ? Palette.textSecondary : Palette.textTertiary
        // The amber is the same in both themes; white on it is 2.3:1, the dark
        // ground on it is 8.2:1.
        case .warning:   return ThemeManager.shared.theme.isDark ? Palette.background : .white
        case .danger:    return .white
        }
    }

    private var background: Color {
        switch fill {
        // An empty selection paints `accentDisabled` rather than fading the
        // whole button — the label must stay legible.
        case let .primary(tint):
            if !isEnabled { return Palette.accentDisabled }
            return tint ?? Palette.accent
        case .secondary: return Palette.surfaceRaised
        case .warning:   return Palette.warningButton
        case .danger:    return Palette.dangerFill
        }
    }

    private var border: Color? {
        switch fill {
        case .primary, .warning, .danger: return nil
        case .secondary: return Palette.borderStrong
        }
    }
}

/// Primary action — flat accent fill, radius 9.
public struct PrimaryButtonStyle: ButtonStyle {
    /// nil → the accent. Pass `Palette.dangerFill` for irreversible actions.
    var explicitTint: Color?
    var height: CGFloat

    public init(tint: Color? = nil, height: CGFloat = Metric.primaryButton) {
        self.explicitTint = tint
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, fill: .primary(explicitTint),
                   height: height, hPadding: 16, radius: Metric.action)
    }
}

/// Secondary action — white fill, `borderStrong`, radius 8.
public struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat

    public init(height: CGFloat = Metric.secondaryButton) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, fill: .secondary,
                   height: height, hPadding: 13, radius: Metric.control)
    }
}

/// Action that needs elevated privileges or attention — the banner button.
public struct WarningButtonStyle: ButtonStyle {
    var height: CGFloat

    public init(height: CGFloat = Metric.primaryButton) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, fill: .warning,
                   height: height, hPadding: 13, radius: Metric.control)
    }
}

/// Irreversible action — solid `dangerFill`.
public struct DangerButtonStyle: ButtonStyle {
    var height: CGFloat

    public init(height: CGFloat = Metric.primaryButton) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, fill: .danger,
                   height: height, hPadding: 13, radius: Metric.control)
    }
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryAction: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primaryAction(tint: Color? = nil,
                              height: CGFloat = Metric.primaryButton) -> PrimaryButtonStyle {
        PrimaryButtonStyle(tint: tint, height: height)
    }
}

public extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryAction: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondaryAction(height: CGFloat = Metric.secondaryButton) -> SecondaryButtonStyle {
        SecondaryButtonStyle(height: height)
    }
}

public extension ButtonStyle where Self == WarningButtonStyle {
    static var warningAction: WarningButtonStyle { WarningButtonStyle() }
    static func warningAction(height: CGFloat = Metric.primaryButton) -> WarningButtonStyle {
        WarningButtonStyle(height: height)
    }
}

public extension ButtonStyle where Self == DangerButtonStyle {
    static var dangerAction: DangerButtonStyle { DangerButtonStyle() }
    static func dangerAction(height: CGFloat) -> DangerButtonStyle { DangerButtonStyle(height: height) }
}

// MARK: - Icon button

public struct IconButton: View {
    let systemName: String
    let label: String
    var tone: Tone?
    var disabled: Bool
    let action: () -> Void

    @State private var hovered = false

    public init(_ systemName: String, label: String, tone: Tone? = nil,
                disabled: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.tone = tone
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: Metric.iconButton, height: Metric.iconButton)
                .background(
                    RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                        .fill(hovered && !disabled ? Palette.accentTint : Palette.surfaceControl)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                        .strokeBorder(hovered && !disabled ? Palette.accentBorder : Palette.borderStrong,
                                      lineWidth: 1)
                )
                .frame(width: Metric.tapTarget, height: Metric.tapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
        .help(label)
    }

    private var foreground: Color {
        if disabled { return Palette.textTertiary }
        if let tone { return tone.text }
        return hovered ? Palette.accentText : Palette.textNav
    }
}

/// The circular refresh button. 26×26, spins 360° over 0.6 s when pressed.
/// It sits in a **card header**, never in the screen header.
public struct RefreshButton: View {
    let label: String
    let action: () -> Void

    @State private var hovered = false
    @State private var turns = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button {
            turns += 1
            action()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered ? Palette.accentText : Palette.textNav)
                .rotationEffect(.degrees(turns * 360))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: turns)
                .frame(width: Metric.refreshButton, height: Metric.refreshButton)
                .background(Circle().fill(hovered ? Palette.accentTint : Palette.surfaceControl))
                .overlay(Circle().strokeBorder(hovered ? Palette.accentBorder : Palette.borderStrong,
                                               lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
        .help(label)
    }
}

// MARK: - Chips and plates

/// Filter toggle. 32pt, radius 8.
public struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    public init(_ title: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typo.secondary)
                .foregroundStyle(isOn ? Palette.accentText : Palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: Metric.chip)
                .background(
                    RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                        .fill(isOn ? Palette.accentTint : Palette.surfaceRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                        .strokeBorder(isOn ? Palette.accentBorder : Palette.borderStrong, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Fixed-width status plate — plates in one column never differ in width. Default 106pt.
public struct StatusPlate: View {
    let text: String
    let tone: Tone
    let width: CGFloat?

    public init(_ text: String, tone: Tone, width: CGFloat? = 106) {
        self.text = text
        self.tone = tone
        self.width = width
    }

    public var body: some View {
        Text(text)
            .font(Typo.micro)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(tone.text)
            .lineLimit(1)
            .frame(width: width, height: 22)
            .frame(minWidth: width == nil ? 0 : nil)
            .padding(.horizontal, width == nil ? 8 : 0)
            .background(
                RoundedRectangle(cornerRadius: Metric.checkboxRadius, style: .continuous)
                    .fill(tone.tint)
            )
    }
}

// MARK: - Screen header
//
// 26/600/−0.6 title, a 13pt secondary subtitle 5pt under it, and screen actions
// on the right aligned to the title's bottom edge. No divider: the cards below
// carry the structure.

public struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    public init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Typo.screenTitle)
                    .tracking(Typo.screenTitleTracking)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Typo.body)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

public extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The content column every screen sits in: `22 26 24 26`, 16pt between blocks.
public struct ScreenBody<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metric.blockGap) {
            content
        }
        .padding(.top, Metric.contentTop)
        .padding(.horizontal, Metric.gutter)
        .padding(.bottom, Metric.contentBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Staggered appearance (Reduce Motion aware)

private struct StaggeredAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    // Only the first screenful staggers. Clamping to 15 steps
                    // instead would hold every later row that scrolls into a
                    // `LazyVStack` at opacity 0 for 300 ms before it fades in.
                    let delay = index < 15 ? Double(index) * 0.02 : 0
                    withAnimation(.easeOut(duration: 0.15).delay(delay)) { shown = true }
                }
            }
    }
}

public extension View {
    /// Staggered fade-in for list rows; `index` drives the delay. The app uses no
    /// springs or bounce, so this is opacity only — no slide.
    func staggeredAppear(index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}

// MARK: - Animation dictionary
//
// No springs and no bounce: this is a tool, not a toy.

public enum Motion {
    public static var rowHover: Animation    { .easeInOut(duration: 0.12) }
    public static var tabSwitch: Animation   { .easeInOut(duration: 0.16) }
    public static var buttonPress: Animation { .easeOut(duration: 0.12) }
    /// Chart / filter change.
    public static var content: Animation     { .easeInOut(duration: 0.18) }
    /// Disclosure arrow, 90° in 0.15 s.
    public static var disclosure: Animation  { .easeInOut(duration: 0.15) }
    public static var panelReveal: Animation { .easeInOut(duration: 0.18) }
    public static var toast: Animation       { .easeOut(duration: 0.2) }
    /// Scan progress bar advances in ~190 ms steps.
    public static var progress: Animation    { .easeOut(duration: 0.19) }
}

// MARK: - Segmented control
//
// Track `surfaceControl`, radius 8, inner padding 3; the active segment is a
// white radius-6 plate at weight 600.

public struct SegmentOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let label: String
    /// Optional second line, e.g. the size a mode would clean.
    public let detail: String?
    public var id: Value { value }

    public init(value: Value, label: String, detail: String? = nil) {
        self.value = value
        self.label = label
        self.detail = detail
    }
}

public struct SegmentedControl<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [SegmentOption<Value>]
    private let height: CGFloat

    public init(selection: Binding<Value>, options: [SegmentOption<Value>],
                height: CGFloat = 26) {
        self._selection = selection
        self.options = options
        self.height = height
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(3)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                .fill(Palette.surfaceControl)
        )
        // The control is as wide as its labels need, and no narrower. Left
        // compressible it ends up sharing whatever a header row has spare, and
        // a short label such as "10m" comes out as "1…".
        .fixedSize(horizontal: true, vertical: false)
    }

    private func segment(_ option: SegmentOption<Value>) -> some View {
        let isOn = option.value == selection
        return Button { selection = option.value } label: {
            VStack(spacing: 0) {
                // Selecting a segment makes its label semibold, which is wider.
                // The hidden bold copy is what sets the width, so the segment is
                // already big enough before it is picked — and never has to
                // truncate. It has to be a `ZStack` sibling: a `.background` is
                // sized *to* its parent and cannot widen it.
                ZStack {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .hidden()
                    Text(option.label)
                        .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? Palette.textPrimary : Palette.textSecondary)
                }
                if let detail = option.detail {
                    Text(detail)
                        .font(Typo.numeric(10, weight: .regular))
                        .foregroundStyle(isOn ? Palette.accentText : Palette.textTertiary)
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Metric.segment, style: .continuous)
                    .fill(isOn ? Palette.surfaceRaised : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Toggle
//
// 40×24, radius 12, 2pt inset, a 20pt white knob with `0 1px 2px 20%`.

public struct AppToggle: View {
    @Binding var isOn: Bool
    let label: String

    public init(isOn: Binding<Bool>, label: String) {
        self._isOn = isOn
        self.label = label
    }

    public var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Palette.accent : Palette.toggleOff)
                Circle()
                    .fill(Color.white)
                    .frame(width: Metric.toggleHeight - 4, height: Metric.toggleHeight - 4)
                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                    .padding(2)
            }
            .frame(width: Metric.toggleWidth, height: Metric.toggleHeight)
            .animation(Motion.rowHover, value: isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        // `.isToggle` needs macOS 14; on 13 a word is what VoiceOver reads.
        .accessibilityValue(Text(Localizer.shared.s(isOn ? "a11y.on" : "a11y.off")))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
