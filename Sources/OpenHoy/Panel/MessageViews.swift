import AVKit
import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    let chat: ChatSummary
    /// First message of a run from one sender: show their avatar (and name in groups).
    let startsGroup: Bool
    /// The message this one answers (if it's loaded), for the quote above the bubble.
    var repliedTo: ChatMessage? = nil
    var isReply = false
    @EnvironmentObject private var state: AppState

    static let avatarSize: CGFloat = 24
    private var fromMe: Bool { message.isFromMe }
    private var alignment: HorizontalAlignment { fromMe ? .trailing : .leading }
    private var showSender: Bool { startsGroup }
    /// Only group chats need to say who's talking.
    private var showsAvatars: Bool { chat.isGroup && !fromMe }

    @ViewBuilder private var avatarColumn: some View {
        if startsGroup {
            AvatarView(person: state.person(forHandle: message.sender, in: chat), size: Self.avatarSize)
        } else {
            Color.clear.frame(width: Self.avatarSize, height: 1)
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if fromMe { Spacer(minLength: 48) } else if showsAvatars { avatarColumn }
            VStack(alignment: alignment, spacing: 6) {
                if showSender, !fromMe, chat.isGroup {
                    Text(state.senderName(message.sender))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 12)
                }
                if isReply {
                    ReplyQuote(original: repliedTo, chat: chat, alignTrailing: fromMe)
                }
                content
                deliveryFooter
            }
            .opacity(message.delivery == .sending ? 0.65 : 1)
            if !fromMe { Spacer(minLength: 48) }
        }
        .help(message.date.formatted(date: .abbreviated, time: .shortened))
    }

    @ViewBuilder private var content: some View {
        let images = message.attachments.filter { $0.kind == .image }
        let videos = message.attachments.filter { $0.kind == .video }
        let others = message.attachments.filter { $0.kind == .file || ($0.kind == .audio && message.voiceAttachment == nil) }

        if let voice = message.voiceAttachment {
            VoiceBubble(attachment: voice, transcript: message.transcript, fromMe: fromMe)
                .reactionBadge(message.reactions, leading: fromMe)
        }
        if !images.isEmpty {
            ImageGroup(images: images, alignTrailing: fromMe)
                .reactionBadge(message.trimmedText == nil ? message.reactions : [], leading: fromMe)
        }
        ForEach(videos) { video in
            VideoBubble(attachment: video)
                .reactionBadge(message.trimmedText == nil && images.isEmpty ? message.reactions : [], leading: fromMe)
        }
        ForEach(others) { file in
            FileBubble(attachment: file, fromMe: fromMe)
        }
        if let text = message.trimmedText {
            TextBubble(text: text, fromMe: fromMe)
                .reactionBadge(message.reactions, leading: fromMe)
        }
    }

    @ViewBuilder private var deliveryFooter: some View {
        if case .failed(let reason) = message.delivery {
            Button {
                state.dismissFailed(message, in: chat.guid)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text("Not delivered · dismiss").foregroundStyle(Theme.secondary)
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(reason)
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - Bubbles

struct TextBubble: View {
    let text: String
    var fromMe = false

    var body: some View {
        Text(Self.linkified(text))
            .font(Theme.bubbleFont)
            .foregroundStyle(fromMe ? Color.white : Theme.text)
            .tint(fromMe ? Color.white : Theme.accent)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .messageBubble(fromMe: fromMe)
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Plain text with URLs made clickable (no Markdown interpretation of message content).
    static func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }
}

struct VoiceBubble: View {
    let attachment: MessageAttachment
    let transcript: String?
    var fromMe = false
    @ObservedObject private var playback = AudioPlayback.shared
    @ViewState private var duration: TimeInterval = 0
    @ViewState private var peaks: [Float] = Array(repeating: 0.15, count: 36)

    private var isPlaying: Bool { attachment.url != nil && playback.playingURL == attachment.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if let url = attachment.url { playback.toggle(url) }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(fromMe ? Theme.accent : Color.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(fromMe ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.bubbleGradient)))
                }
                .buttonStyle(.plain)
                WaveformBars(levels: peaks, progress: isPlaying ? playback.progress : nil, maxHeight: 16,
                             color: fromMe ? .white : .primary.opacity(0.8),
                             dimColor: fromMe ? .white.opacity(0.4) : .primary.opacity(0.3))
                Text(Theme.duration(isPlaying ? duration * playback.progress : duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(fromMe ? Color.white : Theme.text)
            if let transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 12.5))
                    .foregroundStyle(fromMe ? Color.white.opacity(0.85) : Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 13)
        .padding(.vertical, 8)
        .messageBubble(fromMe: fromMe)
        .task(id: attachment.url) {
            guard let url = attachment.url else { return }
            let (d, p) = await WaveformCache.shared.waveform(for: url)
            duration = d
            peaks = p.map { max(0.12, $0) }
        }
    }
}

struct ImageGroup: View {
    let images: [MessageAttachment]
    let alignTrailing: Bool

    var body: some View {
        if images.count == 1, let image = images.first {
            Thumbnail(url: image.url, size: CGSize(width: 440, height: 440), contentMode: .fill)
                .frame(maxWidth: 220, maxHeight: 220)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .onTapGesture { open(image) }
        } else {
            let columns = Array(repeating: GridItem(.fixed(84), spacing: 6), count: min(3, images.count))
            LazyVGrid(columns: columns, alignment: alignTrailing ? .trailing : .leading, spacing: 6) {
                ForEach(images) { image in
                    Thumbnail(url: image.url, size: CGSize(width: 168, height: 168))
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        .onTapGesture { open(image) }
                }
            }
            .fixedSize()
        }
    }

    private func open(_ attachment: MessageAttachment) {
        if let url = attachment.url { NSWorkspace.shared.open(url) }
    }
}

struct VideoBubble: View {
    let attachment: MessageAttachment
    @ViewState private var duration: TimeInterval = 0
    @ViewState private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let player {
                InlineVideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else {
                Thumbnail(url: attachment.url, size: CGSize(width: 520, height: 340))
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                    Text(Theme.duration(duration)).font(.system(size: 13, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .smokyGlass(Capsule(), darkness: 0.35, shadow: false)
                .padding(10)
            }
        }
        .frame(width: 260, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        .contentShape(Rectangle())
        .onTapGesture {
            guard player == nil, let url = attachment.url else { return }
            AudioPlayback.shared.stop()
            let p = AVPlayer(url: url)
            p.actionAtItemEnd = .pause
            player = p
            p.play()
        }
        .contextMenu {
            if let url = attachment.url {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        .task(id: attachment.url) {
            guard let url = attachment.url else { return }
            duration = await ThumbnailCache.shared.duration(of: url)
            if ProcessInfo.processInfo.environment["OPENHOY_AUTOPLAY"] != nil, player == nil {   // development aid
                let p = AVPlayer(url: url)
                player = p
                p.play()
                NSLog("AUTOPLAY started %@", url.lastPathComponent)
            }
        }
    }
}

/// Plays a video right inside its bubble (AppKit's AVPlayerView with inline controls).
struct InlineVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct FileBubble: View {
    let attachment: MessageAttachment
    var fromMe = false

    var body: some View {
        Button {
            if let url = attachment.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: attachment.kind == .audio ? "waveform" : "doc.fill")
                    .foregroundStyle(fromMe ? Color.white.opacity(0.85) : Theme.secondary)
                Text(attachment.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(fromMe ? Color.white : Theme.text)
            }
            .font(Theme.bubbleFont)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .messageBubble(fromMe: fromMe)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reactions

/// Small "↩︎ original text" line above a reply, like Messages' thread quote.
struct ReplyQuote: View {
    let original: ChatMessage?
    let chat: ChatSummary
    let alignTrailing: Bool
    @EnvironmentObject private var state: AppState

    private var snippet: String {
        guard let original else { return "Reply" }
        if let text = original.trimmedText { return text }
        switch original.attachments.first?.kind {
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Voice note"
        case .file: return original.attachments.first?.displayName ?? "Attachment"
        case nil: return "Message"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 8, weight: .bold))
            Text(snippet).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
        .frame(maxWidth: 220, alignment: alignTrailing ? .trailing : .leading)
        .help(original?.trimmedText ?? "")
    }
}

struct ReactionBadge: View {
    let reactions: [Reaction]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(reactions.prefix(3).enumerated()), id: \.offset) { _, reaction in
                Group {
                    if reaction.kind == .emoji, let emoji = reaction.emoji {
                        Text(emoji).font(.system(size: 11))
                    } else if reaction.kind == .laugh {
                        Text("HA").font(.system(size: 8, weight: .heavy))
                    } else {
                        Image(systemName: reaction.kind.symbol).font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundStyle(reaction.kind == .love ? Color(red: 1, green: 0.33, blue: 0.55) : Color.primary.opacity(0.75))
            }
        }
        .padding(.horizontal, 5)
        .frame(minWidth: 22, minHeight: 22)
        .bubbleSurface(Capsule())
    }
}

extension View {
    @ViewBuilder
    func reactionBadge(_ reactions: [Reaction], leading: Bool) -> some View {
        if reactions.isEmpty {
            self
        } else {
            self.overlay(alignment: leading ? .topLeading : .topTrailing) {
                ReactionBadge(reactions: reactions)
                    .offset(x: leading ? -8 : 8, y: -10)
            }
            .padding(.top, 6)
        }
    }
}
