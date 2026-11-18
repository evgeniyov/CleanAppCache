import SwiftUI
import AppKit

// MARK: - Toast model

public struct Toast: Identifiable, Equatable {
    public enum Style {
        case info, success, warning, error
        /// A result read back from the cross-launch cache rather than scanned
        /// just now. Without a distinct style, data up to 24 hours old would be
        /// presented as fresh.
        case cached
    }

    public let id = UUID()
    public let style: Style
    public let title: String
    public let message: String?
    /// Optional action (e.g. "Undo"). When tapped, `action` runs and the toast
    /// is dismissed.
    public let actionTitle: String?
    public let action: (() -> Void)?
    public let duration: TimeInterval

    /// The toast hides itself after 4 s by default.
    public init(style: Style, title: String, message: String? = nil,
                actionTitle: String? = nil, duration: TimeInterval = 4,
                action: (() -> Void)? = nil) {
        self.style = style
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.duration = duration
    }

    public static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }

    var icon: String {
        switch style {
        case .info:    return "info.circle"
        case .success: return "checkmark"
        case .warning: return "exclamationmark.triangle"
        case .error:   return "xmark"
        case .cached:  return "clock.arrow.circlepath"
        }
    }

    /// Colour appears only in the 8pt dot. The success dot is `#4ADE80`;
    /// the other styles take their semantic fill, which reads on the dark card.
    @MainActor var tint: Color {
        switch style {
        case .info, .cached: return Palette.accentOnDark
        case .success:       return Palette.toastDot
        case .warning:       return Palette.warningFill
        case .error:         return Palette.dangerText
        }
    }
}

// MARK: - Toast center (shared)

@MainActor
public final class ToastCenter: ObservableObject {
    public static let shared = ToastCenter()
    @Published public private(set) var toasts: [Toast] = []
    /// Reason kept on screen after an error toast expires, until dismissed.
    @Published public var stickyDetail: String?
    private var timers: [UUID: Task<Void, Never>] = [:]

    private init() {}

    public func show(_ toast: Toast) {
        toasts.append(toast)
        // Nothing else tells VoiceOver a toast appeared. `AccessibilityNotification
        // .Announcement` needs macOS 14; the AppKit post works on 13. `NSApp` is
        // nil under the test host, which has no application object.
        if let app = NSApp {
            NSAccessibility.post(element: app, notification: .announcementRequested,
                                 userInfo: [.announcement: [toast.title, toast.message]
                                                .compactMap { $0 }.joined(separator: ". "),
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        // Auto-dismiss after the toast's duration.
        timers[toast.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    public func dismiss(_ id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
        // No spring animations anywhere in the app; this uses the toast curve.
        withAnimation(Motion.toast) {
            toasts.removeAll { $0.id == id }
        }
    }

    public func runAction(_ toast: Toast) {
        toast.action?()
        dismiss(toast.id)
    }

    // Convenience builders
    public func success(_ title: String, _ message: String? = nil) {
        show(Toast(style: .success, title: title, message: message))
    }
    /// An error toast carries a "Details" button by default: the card lives 7
    /// seconds and the reason is needed for longer than that.
    public func error(_ title: String, _ message: String? = nil) {
        show(Toast(style: .error, title: title, message: message,
                   actionTitle: message == nil ? nil : Localizer.shared.s("toast.details"),
                   duration: 7,
                   action: message == nil ? nil : {
                       ToastCenter.shared.stickyDetail = message
                   }))
    }
}

// MARK: - Toast overlay view

public struct ToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 10) {
            Spacer()
            if let detail = center.stickyDetail {
                StickyDetailCard(text: detail) { center.stickyDetail = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ForEach(center.toasts) { toast in
                ToastCard(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Fixed to the bottom centre, 34 from the edge.
        .padding(.bottom, 34)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(true)
        .animation(Motion.toast, value: center.toasts)
    }
}

/// The toast — the second dark surface the design allows, and the only one
/// outside History. A dot, one line of text, and a dismiss word; nothing else.
private struct ToastCard: View {
    @ObservedObject private var center = ToastCenter.shared
    let toast: Toast

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(toast.tint)
                .frame(width: 8, height: 8)

            Text(toast.title)
                .font(Typo.body)
                .foregroundStyle(Palette.heroDarkText)
                .lineLimit(1)

            if let message = toast.message {
                Text(message)
                    .help(message)
                    .font(Typo.body)
                    .foregroundStyle(Palette.heroDarkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(toast.actionTitle ?? Localizer.shared.s("toast.gotIt")) {
                if toast.actionTitle != nil {
                    center.runAction(toast)
                } else {
                    center.dismiss(toast.id)
                }
            }
            .buttonStyle(.plain)
            .font(Typo.bodyStrong)
            .foregroundStyle(Palette.accentOnDark)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Palette.heroDark)
        )
        .shadow(color: Shadow.toastColor, radius: Shadow.toastRadius, x: 0, y: Shadow.toastY)
        .frame(maxWidth: 560)
    }
}

// MARK: - Sticky error detail
//
// A toast is gone in seconds; the reason an operation failed is needed for
// longer. "Details" moves the message here, where it stays until dismissed.

private struct StickyDetailCard: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(Typo.footnote)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            IconButton("xmark", label: Localizer.shared.s("common.close"), action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.selectedRow)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.dangerFill).frame(width: 3) }
        .overlay(Rectangle().strokeBorder(Palette.borderStrong, lineWidth: 1))
        .frame(maxWidth: 460)
    }
}
