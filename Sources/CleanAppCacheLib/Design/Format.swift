import Foundation

// MARK: - Number formatting
//
// The rules are mandatory and identical everywhere, so they live in one place
// rather than in each screen:
//
//   • decimal separator from the locale (comma in Russian), thousands grouped
//     with a narrow space
//   • volume ≥1 GB → "12.4 GB"; two decimals below 10, one at 10 and above.
//     Below 1 GB → MB, below 1 MB → KB
//   • zero defaults to an em dash. A confirmed empty folder uses `zeroBytes`.
//   • speed follows the same ladder, per second
//
// Sizes are decimal (1 GB = 1000³), matching Finder.
//
// `ByteCountFormatter` is not used because it follows the **system** locale
// rather than the in-app language switch: with macOS in one language and the
// switch in another it prints "57,91 GB" into a Russian interface. Its units are
// not translated, and its decimal count does not follow the rule above.

public enum Fmt {

    /// A formatted figure split from its unit, because big figures paint the
    /// unit smaller and in `textTertiary`. `unit` is nil when the value is "—".
    public struct Value: Sendable {
        public let number: String
        public let unit: String?

        public init(number: String, unit: String?) {
            self.number = number
            self.unit = unit
        }

        /// The two joined with a space — for places that take a plain string.
        public var joined: String {
            guard let unit, !unit.isEmpty else { return number }
            return "\(number) \(unit)"
        }
    }

    /// Em dash, the default for a zero or unavailable value.
    public static let none = "—"

    // MARK: Locale context
    //
    // Sizes are formatted from background scanners as well as from view bodies,
    // so this cannot be `@MainActor`. `Localizer` pushes a snapshot of the unit
    // strings and the locale here on launch and on every language change, and
    // everything below reads that snapshot under a lock.

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var locale: Locale = .current
        var units: [String: String] = [:]
        /// One formatter per decimal count (0, 1, 2). Setting the fraction
        /// digits on a shared formatter per call would re-configure ICU on every
        /// number the view layer prints.
        var formatters: [NumberFormatter] = Fmt.makeFormatters(.current)
        var clock: DateFormatter = Fmt.makeClock(.current)
    }

    private static let storage = Storage()

    /// Unit keys the context carries. Declared here so `Localizer` and `Fmt`
    /// cannot drift apart on the spelling.
    public static let unitKeys = ["unit.b", "unit.bytes", "unit.kb", "unit.mb", "unit.gb",
                                  "unit.tb", "unit.perSec"]

    private static func makeFormatters(_ locale: Locale) -> [NumberFormatter] {
        (0...2).map { decimals in
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = locale
            f.usesGroupingSeparator = true
            f.minimumFractionDigits = decimals
            f.maximumFractionDigits = decimals
            // Thousands are grouped with a narrow space. Locales that already
            // group with whitespace (ru) get the narrow form; locales that group
            // with a comma (en) keep theirs.
            if let sep = f.groupingSeparator,
               !sep.isEmpty,
               sep.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) {
                f.groupingSeparator = "\u{202F}"
            }
            return f
        }
    }

    private static func makeClock(_ locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "HH:mm"
        return f
    }

    /// Called by `Localizer` whenever the effective language changes.
    public static func setContext(locale: Locale, units: [String: String]) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.locale = locale
        storage.units = units
        storage.formatters = makeFormatters(locale)
        storage.clock = makeClock(locale)
    }

    private static func unit(_ key: String) -> String {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        // A background scanner can format a size before anything has touched
        // `Localizer`, and an empty table would print the figure with no unit at
        // all — "1.80" instead of "1.80 KB". Seed from the bundle on first use;
        // `Localizer` overrides it the moment the user picks a language.
        if storage.units.isEmpty {
            for k in unitKeys {
                storage.units[k] = Bundle.module.localizedString(forKey: k, value: k, table: nil)
            }
        }
        return storage.units[key] ?? ""
    }

    // MARK: Core decimal formatting

    /// A number with a fixed count of decimals, thousands grouped.
    public static func decimal(_ value: Double, decimals: Int) -> String {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        // The formatting rules never ask for more than two decimals; anything else falls
        // through to a plain format rather than configuring a formatter.
        guard storage.formatters.indices.contains(decimals) else {
            return String(format: "%.\(max(0, decimals))f", locale: storage.locale, value)
        }
        return storage.formatters[decimals].string(from: NSNumber(value: value))
            ?? String(format: "%.\(decimals)f", value)
    }

    /// An integer count — "8 412".
    public static func count(_ value: Int) -> String {
        decimal(Double(value), decimals: 0)
    }

    // MARK: Volume

    /// Two decimals below 10, one at 10 and above.
    private static func scaled(_ value: Double) -> String {
        decimal(value, decimals: value < 10 ? 2 : 1)
    }

    /// Bytes as a figure and its unit. Zero is "—" with no unit.
    public static func size(_ bytes: UInt64) -> Value {
        guard bytes > 0 else { return Value(number: none, unit: nil) }
        let b = Double(bytes)
        if b >= 1_000_000_000_000 {
            return Value(number: scaled(b / 1_000_000_000_000), unit: unit("unit.tb"))
        }
        if b >= 1_000_000_000 {
            return Value(number: scaled(b / 1_000_000_000), unit: unit("unit.gb"))
        }
        if b >= 1_000_000 {
            return Value(number: scaled(b / 1_000_000), unit: unit("unit.mb"))
        }
        if b >= 1_000 {
            return Value(number: scaled(b / 1_000), unit: unit("unit.kb"))
        }
        return Value(number: count(Int(bytes)), unit: unit("unit.b"))
    }

    /// Bytes as one string — "12.4 GB".
    public static func bytes(_ bytes: UInt64) -> String { size(bytes).joined }

    static var zeroBytes: String { Value(number: count(0), unit: unit("unit.bytes")).joined }

    /// Signed variant of the same, for a byte count that may be negative.
    public static func bytes(_ value: Int64) -> String {
        bytes(UInt64(max(0, value)))
    }

    /// Two volumes sharing one unit — "187.2 / 245.1 GB".
    ///
    /// The unit is printed once, at the end, and both figures are scaled to the
    /// larger one so the pair reads as a ratio rather than as two measurements.
    public static func bytesPair(_ lhs: UInt64, _ rhs: UInt64) -> String {
        guard rhs > 0 else { return none }
        let r = Double(rhs)
        let (divisor, unitKey): (Double, String) = {
            if r >= 1_000_000_000_000 { return (1_000_000_000_000, "unit.tb") }
            if r >= 1_000_000_000     { return (1_000_000_000,     "unit.gb") }
            if r >= 1_000_000         { return (1_000_000,         "unit.mb") }
            if r >= 1_000             { return (1_000,             "unit.kb") }
            return (1, "unit.b")
        }()
        return "\(scaled(Double(lhs) / divisor)) / \(scaled(r / divisor)) \(unit(unitKey))"
    }

    /// Signed delta for the "free space after cleanup" line — "+7,33".
    public static func delta(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return none }
        let b = Double(bytes)
        let value = b >= 1_000_000_000 ? b / 1_000_000_000
            : b >= 1_000_000 ? b / 1_000_000 : b / 1_000
        return "+" + scaled(value)
    }

    // MARK: Speed

    /// Bytes per second — the same ladder, per second. Idle is "—".
    public static func speed(_ bytesPerSec: Double) -> Value {
        // Below a byte per second is idle, not "0.5 B/s".
        guard bytesPerSec >= 1 else { return Value(number: none, unit: nil) }
        let perSec = unit("unit.perSec")
        let base: (Double, String)
        if bytesPerSec >= 1_000_000  { base = (bytesPerSec / 1_000_000, "unit.mb") }
        else if bytesPerSec >= 1_000 { base = (bytesPerSec / 1_000,     "unit.kb") }
        else                         { base = (bytesPerSec,             "unit.b")  }
        return Value(number: scaled(base.0),
                     unit: String(format: perSec, unit(base.1)))
    }

    public static func speedString(_ bytesPerSec: Double) -> String { speed(bytesPerSec).joined }

    // MARK: Percent

    /// "22.4%" — one decimal by default, as process shares use.
    public static func percent(_ value: Double, decimals: Int = 1) -> String {
        "\(decimal(value, decimals: decimals))%"
    }

    /// A percentage split from its sign, for the big figures.
    public static func percentValue(_ value: Double, decimals: Int = 1) -> Value {
        Value(number: decimal(value, decimals: decimals), unit: "%")
    }

    // MARK: Time

    /// "14:31" — the clock beside a refresh button. The formatter is
    /// cached in `Storage`: callers sit in view bodies, and building one per
    /// call would be an ICU setup per render.
    public static func clock(_ date: Date) -> String {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.clock.string(from: date)
    }

    // MARK: Plurals
    //
    // Russian needs three forms and the 11–14 exception; English needs two. Both
    // come from `Localizable.stringsdict`, which is what the platform's plural
    // machinery reads — hand-rolled `% 10` arithmetic in Swift would only ever be
    // correct for one of the two languages.

    /// "3 files" — `key` names a stringsdict entry.
    @MainActor
    public static func plural(_ key: String, _ n: Int) -> String {
        Localizer.shared.f(key, n)
    }
}
