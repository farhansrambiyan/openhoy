import AppKit
import SwiftUI

/// The colour theme picked in Settings. `messages` matches Messages.app: blue for
/// iMessage, green for SMS.
enum ThemeChoice: String, CaseIterable, Identifiable, Sendable {
    case messages, systemAccent, graphite, ocean, sunset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: return "Messages"
        case .systemAccent: return "System Accent"
        case .graphite: return "Graphite"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .messages:
            return ThemePalette(accent: .systemBlue, sent: [.systemBlue], sms: [.systemGreen], unread: .systemBlue)
        case .systemAccent:
            return ThemePalette(accent: .controlAccentColor, sent: [.controlAccentColor], sms: nil, unread: .controlAccentColor)
        case .graphite:
            let graphite = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.36, green: 0.36, blue: 0.39, alpha: 1)
                    : NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1)
            }
            return ThemePalette(accent: .systemGray, sent: [graphite], sms: nil, unread: .systemRed)
        case .ocean:
            return ThemePalette(accent: NSColor(srgbRed: 0.05, green: 0.55, blue: 0.80, alpha: 1),
                                sent: [NSColor(srgbRed: 0.02, green: 0.62, blue: 0.72, alpha: 1),
                                       NSColor(srgbRed: 0.16, green: 0.38, blue: 0.92, alpha: 1)],
                                sms: nil, unread: NSColor(srgbRed: 0.05, green: 0.55, blue: 0.85, alpha: 1))
        case .sunset:
            return ThemePalette(accent: NSColor(srgbRed: 0.70, green: 0.20, blue: 0.86, alpha: 1),
                                sent: [NSColor(srgbRed: 0.91, green: 0.20, blue: 0.56, alpha: 1),
                                       NSColor(srgbRed: 0.55, green: 0.24, blue: 0.93, alpha: 1)],
                                sms: nil, unread: NSColor(srgbRed: 0.93, green: 0.16, blue: 0.55, alpha: 1),
                                ring: [NSColor(srgbRed: 0.98, green: 0.42, blue: 0.22, alpha: 1),
                                       NSColor(srgbRed: 0.93, green: 0.16, blue: 0.55, alpha: 1),
                                       NSColor(srgbRed: 0.50, green: 0.22, blue: 0.95, alpha: 1)])
        }
    }
}

/// Colours for one theme. Gradients with a single stop draw as a solid colour.
struct ThemePalette {
    /// Tints: links, chips, waveforms, the drop-target outline.
    let accent: NSColor
    /// Your messages and the send button.
    let sent: [NSColor]
    /// Your messages in SMS conversations, when the theme colours them differently.
    let sms: [NSColor]?
    /// The unread dot in the menu bar.
    let unread: NSColor
    /// The ring around the open conversation's avatar (defaults to `sent`).
    var ring: [NSColor]? = nil

    var ringColors: [NSColor] { ring ?? sent }
}

// MARK: - SMS environment

private struct IsSMSChatKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The open conversation goes over SMS / RCS rather than iMessage.
    var isSMSChat: Bool {
        get { self[IsSMSChatKey.self] }
        set { self[IsSMSChatKey.self] = newValue }
    }
}
