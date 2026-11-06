import AppKit
import AVFoundation
import QuickLookThumbnailing
import SwiftUI

// MARK: - Glass

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    /// Force the dark look (HUDs); otherwise follow the system appearance.
    var forceDark = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        if forceDark { view.appearance = NSAppearance(named: .darkAqua) }
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Smoky, back-lit dark glass (used by the screen-recording HUDs).
struct SmokyGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var darkness: Double = 0.42
    var shadow = true

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    VisualEffectBlur()
                    Color.black.opacity(darkness)
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.06), .white.opacity(0.03), .white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(shadow ? 0.28 : 0), radius: 14, y: 6)
    }
}

extension View {
    func smokyGlass<S: InsettableShape>(_ shape: S, darkness: Double = 0.42, shadow: Bool = true) -> some View {
        modifier(SmokyGlass(shape: shape, darkness: darkness, shadow: shadow))
    }

    func smokyGlass(cornerRadius: CGFloat, darkness: Double = 0.42, shadow: Bool = true) -> some View {
        smokyGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), darkness: darkness, shadow: shadow)
    }
}

// MARK: - Liquid Glass controls

/// Groups nearby glass controls so they render, blend and morph together (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// A pressable control on Liquid Glass (macOS 26+); a soft filled shape before that.
    @ViewBuilder
    func glassControl<S: Shape>(_ shape: S, fallback: Color = Color.primary.opacity(0.08)) -> some View {
        if #available(macOS 26.0, *), Theme.liquidGlass {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(shape.fill(fallback))
        }
    }

    /// A non-pressable glass field, such as the composer (macOS 26+); frosted before that.
    @ViewBuilder
    func glassField(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *), Theme.liquidGlass {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            bubbleSurface(cornerRadius: cornerRadius, shadow: false)
        }
    }

    /// Identity for glass morphing inside a `GlassGroup` (macOS 26+; no-op before).
    @ViewBuilder
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

// MARK: - Card & bubble surfaces

/// The chat card: Liquid Glass on macOS 26+, a frosted material before that.
struct CardSurface: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            // No drop shadow: it would be clipped by the panel window into a grey box.
            content
                .glassEffect(.regular.tint(scheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.22)), in: shape)
        } else {
            content
                .background {
                    VisualEffectBlur(material: .popover, forceDark: false).clipShape(shape)
                }
                .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.14 : 0.65), lineWidth: 1))
        }
    }
}

/// Bubbles and the composer box inside the card: a brighter frosted layer.
struct BubbleSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var shadow = true
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background(shape.fill(dark ? Color.white.opacity(0.10) : Color.white.opacity(0.58)))
            .overlay(shape.strokeBorder(
                LinearGradient(colors: dark ? [.white.opacity(0.20), .white.opacity(0.05)] : [.white.opacity(0.95), .white.opacity(0.4)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8))
            .shadow(color: .black.opacity(shadow && !dark ? 0.05 : 0), radius: 6, y: 2)
    }
}

/// Message bubble: rounded with a tighter "tail" corner on the sender's side. Your own
/// messages are filled with the brand gradient; theirs are frosted and neutral.
struct MessageBubbleStyle: ViewModifier {
    let fromMe: Bool
    var radius: CGFloat = 18
    @Environment(\.isSMSChat) private var isSMS

    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: fromMe ? radius : 6,
            bottomTrailingRadius: fromMe ? 6 : radius,
            topTrailingRadius: radius,
            style: .continuous)
        if fromMe {
            content
                .background(shape.fill(Theme.sentFill(sms: isSMS)))
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
        } else {
            content.bubbleSurface(shape, shadow: false)
        }
    }
}

extension View {
    func messageBubble(fromMe: Bool, radius: CGFloat = 18) -> some View {
        modifier(MessageBubbleStyle(fromMe: fromMe, radius: radius))
    }

    func cardSurface(radius: CGFloat = Theme.cardRadius) -> some View { modifier(CardSurface(radius: radius)) }

    func bubbleSurface<S: InsettableShape>(_ shape: S, shadow: Bool = true) -> some View {
        modifier(BubbleSurface(shape: shape, shadow: shadow))
    }

    func bubbleSurface(cornerRadius: CGFloat, shadow: Bool = true) -> some View {
        bubbleSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), shadow: shadow)
    }
}

enum Theme {
    /// The theme picked in Settings (kept in sync by `AppState.theme`).
    nonisolated(unsafe) static var choice: ThemeChoice = .messages
    static var palette: ThemePalette { choice.palette }

    /// Tint for links, chips, waveforms and outlines.
    static var accent: Color { Color(nsColor: palette.accent) }
    /// The send button.
    static var brandGradient: LinearGradient { gradient(palette.sent) }
    /// Your message bubbles.
    static var bubbleGradient: LinearGradient { gradient(palette.sent) }
    /// Your message bubbles, coloured for the conversation's service (green SMS in Messages).
    static func sentFill(sms: Bool) -> LinearGradient { gradient(sms ? (palette.sms ?? palette.sent) : palette.sent) }

    private static func gradient(_ colors: [NSColor]) -> LinearGradient {
        let stops = colors.map { Color(nsColor: $0) }
        return LinearGradient(colors: stops.count == 1 ? [stops[0], stops[0]] : stops,
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Offscreen snapshots can't draw Liquid Glass controls, so README screenshot runs
    /// (OPENHOY_FLAT_GLASS=1) use the frosted fallback instead.
    static let liquidGlass = ProcessInfo.processInfo.environment["OPENHOY_FLAT_GLASS"] == nil
    static let recordingOrange = Color(red: 0.98, green: 0.55, blue: 0.24)
    // Semantic, so the panel follows light / dark mode.
    static let text = Color.primary.opacity(0.92)
    static let secondary = Color.secondary
    static let tertiary = Color.primary.opacity(0.32)
    static let bubbleFont = Font.system(size: 14, weight: .regular)
    static let panelWidth: CGFloat = 360
    static let expandedPanelWidth: CGFloat = 480
    /// Squircle radius of the chat card.
    static let cardRadius: CGFloat = 24

    static func panelWidth(expanded: Bool) -> CGFloat { expanded ? expandedPanelWidth : panelWidth }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Thumbnails

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    /// Readable synchronously from views, so already-seen images never flash a placeholder.
    nonisolated(unsafe) static let memory = NSCache<NSString, NSImage>()   // NSCache is thread-safe
    private var cache: [String: NSImage] = [:]
    private var durations: [URL: TimeInterval] = [:]

    nonisolated static func key(_ url: URL, _ size: CGSize) -> String {
        "\(url.path)#\(Int(size.width))x\(Int(size.height))"
    }

    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let key = Self.key(url, size)
        if let hit = cache[key] { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
        if let image {
            cache[key] = image
            Self.memory.setObject(image, forKey: key as NSString)
        }
        return image
    }

    func duration(of url: URL) async -> TimeInterval {
        if let hit = durations[url] { return hit }
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let value = seconds.isFinite ? seconds : 0
        durations[url] = value
        return value
    }
}

struct Thumbnail: View {
    let url: URL?
    var size: CGSize = CGSize(width: 160, height: 160)
    var contentMode: ContentMode = .fill
    @ViewState private var image: NSImage?

    init(url: URL?, size: CGSize = CGSize(width: 160, height: 160), contentMode: ContentMode = .fill) {
        self.url = url
        self.size = size
        self.contentMode = contentMode
        let cached = url.flatMap { ThumbnailCache.memory.object(forKey: ThumbnailCache.key($0, size) as NSString) }
        _image = ViewState(initialValue: cached)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color.primary.opacity(0.06)
                ProgressView().controlSize(.small).opacity(url == nil ? 0 : 0.6)
            }
        }
        .task(id: url) {
            guard let url, image == nil else { return }
            image = await ThumbnailCache.shared.thumbnail(for: url, size: size)
        }
    }
}

// MARK: - Waveform

struct WaveformBars: View {
    let levels: [Float]
    var progress: Double? = nil
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 18
    var color: Color = .primary.opacity(0.8)
    var dimColor: Color = .primary.opacity(0.3)

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let played = progress.map { Double(index) / Double(max(1, levels.count)) <= $0 } ?? true
                Capsule()
                    .fill(played ? color : dimColor)
                    .frame(width: barWidth, height: max(barWidth, CGFloat(level) * maxHeight))
            }
        }
        .frame(height: maxHeight)
    }
}

/// `@State` is a compiler macro in recent SDKs whose plugin ships only with Xcode.
/// Referring to the underlying property wrapper through an alias lets OpenHoy build
/// with just the Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
