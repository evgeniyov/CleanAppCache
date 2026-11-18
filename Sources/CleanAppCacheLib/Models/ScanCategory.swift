import Foundation

public enum ScanCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case systemCache = "System Cache"
    case userCache = "User Cache"
    case browserJunk = "Browser Caches"
    case logs = "Logs"
    case trash = "Trash"
    case tempFiles = "Temporary Files"
    case installers = "Installers"

    public var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .systemCache: return "cat.systemCache"
        case .userCache: return "cat.userCache"
        case .browserJunk: return "cat.browser"
        case .logs: return "cat.logs"
        case .trash: return "cat.trash"
        case .tempFiles: return "cat.tempFiles"
        case .installers: return "cat.installers"
        }
    }

    public var icon: String {
        switch self {
        case .systemCache: return "cpu"
        case .userCache: return "archivebox"
        case .browserJunk: return "globe"
        case .logs: return "doc.text.magnifyingglass"
        case .trash: return "trash"
        case .tempFiles: return "clock.arrow.circlepath"
        case .installers: return "shippingbox"
        }
    }

    public var description: String {
        switch self {
        case .systemCache: return "System and framework caches"
        case .userCache: return "Application caches"
        case .browserJunk: return "Safari, Chrome, Firefox & other browser caches"
        case .logs: return "System and app logs"
        case .trash: return "Deleted items"
        case .tempFiles: return "Temporary files"
        case .installers: return "Old .dmg/.pkg installers in Downloads"
        }
    }

    /// Whether items in this category are safe to preselect for cleaning.
    /// Deletion is permanent, so anything that deserves a second look (system
    /// caches, the Trash itself, browser caches best cleared with browsers
    /// closed, installers the user may still want) is left for the user to
    /// opt into rather than cleaned by default.
    public var isSafeToAutoClean: Bool {
        switch self {
        case .userCache, .logs, .tempFiles: return true
        case .systemCache, .trash, .browserJunk, .installers: return false
        }
    }
}
