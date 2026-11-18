import Foundation
import SwiftUI

/// Runtime localization with an in-app language switch (System / English / Russian).
/// Views observe this object, so changing the language re-renders the whole UI.
@MainActor
public final class Localizer: ObservableObject {
    public static let shared = Localizer()

    public enum Language: String, CaseIterable, Identifiable, Sendable {
        case system, en, ru
        public var id: String { rawValue }

        /// Key used to localize the language's own display name.
        var labelKey: String {
            switch self {
            case .system: return "lang.system"
            case .en: return "lang.en"
            case .ru: return "lang.ru"
            }
        }
    }

    private static let defaultsKey = "app.language"

    @Published public var language: Language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            resolveBundle()
        }
    }

    /// Locale to push into the environment so system formatters follow the UI language.
    public var locale: Locale {
        switch language {
        case .system: return Locale.current
        case .en: return Locale(identifier: "en")
        case .ru: return Locale(identifier: "ru")
        }
    }

    private var bundle: Bundle = .module

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        language = Language(rawValue: saved ?? "") ?? .system
        resolveBundle()
    }

    private func resolveBundle() {
        switch language {
        case .system:
            bundle = .module
        case .en, .ru:
            if let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
               let b = Bundle(path: path) {
                bundle = b
            } else {
                bundle = .module
            }
        }
        publishFormattingContext()
    }

    /// `Fmt` formats sizes from background scanners too, so it cannot reach into
    /// this `@MainActor` object. It gets a snapshot of the locale and the unit
    /// strings instead, refreshed whenever the language changes.
    private func publishFormattingContext() {
        var units: [String: String] = [:]
        for key in Fmt.unitKeys { units[key] = s(key) }
        Fmt.setContext(locale: locale, units: units)
    }

    /// Localized string for a key.
    public func s(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Localized string for a key, or nil if the key is not defined.
    public func opt(_ key: String) -> String? {
        let sentinel = "\u{1}"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }

    /// Localizes a data-layer name (e.g. storage breakdown categories) via
    /// "bk.<name>" keys, falling back to the raw name when not translated.
    public func name(_ raw: String) -> String {
        opt("bk." + raw) ?? raw
    }

    private var cachedDateFormatter: DateFormatter?

    /// Shared medium-style date formatter for the current UI language.
    ///
    /// Building a `DateFormatter` and setting its locale costs roughly a
    /// millisecond. Built *per row, per render*, a 200-app list would pay
    /// 20–200 ms every time any `@Published` value changed.
    public var mediumDateFormatter: DateFormatter {
        let current = locale
        if let cached = cachedDateFormatter, cached.locale == current { return cached }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = current
        cachedDateFormatter = formatter
        return formatter
    }

    /// Medium date, or an em dash when the date is unknown.
    public func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return mediumDateFormatter.string(from: date)
    }

    private var cachedDateTimeFormatter: DateFormatter?

    /// Short date **and** time — "when was this last scanned". Cached for the
    /// same reason as `mediumDateFormatter`.
    public var shortDateTimeFormatter: DateFormatter {
        let current = locale
        if let cached = cachedDateTimeFormatter, cached.locale == current { return cached }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = current
        cachedDateTimeFormatter = formatter
        return formatter
    }

    /// Short date and time, or an em dash when unknown.
    public func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return shortDateTimeFormatter.string(from: date)
    }

    /// Localized format string filled with arguments.
    public func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: bundle.localizedString(forKey: key, value: key, table: nil),
               locale: locale,
               arguments: args)
    }
}
