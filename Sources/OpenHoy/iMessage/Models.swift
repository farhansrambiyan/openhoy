import Foundation
import UniformTypeIdentifiers

/// A conversation in Messages (1:1 or group), read from `chat.db`.
struct ChatSummary: Identifiable, Hashable, Sendable, Codable {
    /// `chat.ROWID`
    let rowID: Int64
    /// `chat.guid`, e.g. `iMessage;-;+15551234567` or `any;-;foo@icloud.com`.
    let guid: String
    /// `chat.chat_identifier` — the handle for 1:1 chats, `chatXXXX` for groups.
    let identifier: String
    /// User-assigned group name, if any.
    let displayName: String?
    /// `iMessage`, `SMS`, `RCS`, …
    let service: String
    /// Handle ids (phone numbers / emails) of the other participants.
    let participants: [String]
    let lastMessageDate: Date
    /// Every `chat.ROWID` Messages keeps for this conversation. Messages often has several
    /// rows for one person (iMessage, SMS, `any;-;…`), which its own UI shows as one thread.
    var mergedRowIDs: [Int64]? = nil
    /// Guid of the most recently active row — the one to send to.
    var latestGUID: String? = nil
    /// The group photo set in Messages, if any.
    var groupPhotoPath: String? = nil

    var id: String { guid }
    var allRowIDs: [Int64] { mergedRowIDs ?? [rowID] }
    var sendGUID: String { latestGUID ?? guid }
    var isGroup: Bool { participants.count > 1 }
    /// Best handle to address a 1:1 chat with when the chat guid can't be used.
    var primaryHandle: String { participants.first ?? identifier }
}

enum AttachmentKind: Sendable {
    case image, video, audio, file

    static func classify(mimeType: String?, uti: String?, filename: String?) -> AttachmentKind {
        if let mime = mimeType?.lowercased() {
            if mime.hasPrefix("image/") { return .image }
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
        }
        var type: UTType?
        if let uti { type = UTType(uti) }
        if type == nil, let ext = filename.map({ ($0 as NSString).pathExtension }), !ext.isEmpty {
            type = UTType(filenameExtension: ext)
        }
        if let type {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return .file
    }
}

struct MessageAttachment: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL?
    let mimeType: String?
    let transferName: String?
    let kind: AttachmentKind

    var displayName: String { transferName ?? url?.lastPathComponent ?? "Attachment" }
}

enum ReactionKind: Int, Sendable {
    case love = 2000, like, dislike, laugh, emphasize, question, emoji

    var symbol: String {
        switch self {
        case .love: return "heart.fill"
        case .like: return "hand.thumbsup.fill"
        case .dislike: return "hand.thumbsdown.fill"
        case .laugh: return "face.smiling.inverse"
        case .emphasize: return "exclamationmark.2"
        case .question: return "questionmark"
        case .emoji: return ""
        }
    }
}

struct Reaction: Hashable, Sendable {
    let kind: ReactionKind
    let fromMe: Bool
    let emoji: String?
}

/// Where a message is on its way out, as far as OpenHoy can honestly tell.
/// Messages.app owns delivery; OpenHoy only reflects what `chat.db` records.
enum DeliveryState: Hashable, Sendable {
    /// Handing the message to Messages.app (optimistic bubble).
    case sending
    /// Messages accepted it; no delivery receipt yet.
    case sent
    case delivered
    case read(Date)
    /// Messages recorded a send error (`message.error != 0`). Retry happens in Messages.
    case notDelivered
    /// OpenHoy couldn't hand it to Messages at all (AppleScript error). Dismissable.
    case failed(String)

    var isFailure: Bool {
        switch self {
        case .notDelivered, .failed: return true
        default: return false
        }
    }
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: String              // message guid (or local id for optimistic messages)
    let rowID: Int64
    var text: String?
    let isFromMe: Bool
    let date: Date
    /// Handle id of the sender for incoming messages.
    let sender: String?
    var attachments: [MessageAttachment]
    var reactions: [Reaction] = []
    let isAudioMessage: Bool
    var delivery: DeliveryState = .delivered
    /// Transcript shown under a voice note (merged from the text we sent alongside it).
    var transcript: String? = nil
    /// Guid of the message this one replies to (Messages' inline-reply threads).
    var replyToGUID: String? = nil
    /// The sender edited this message; `text` is the current version.
    var isEdited = false
    /// The sender unsent this message; it renders as a small notice, not a bubble.
    var isUnsent = false

    var trimmedText: String? {
        guard let text else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    var voiceAttachment: MessageAttachment? {
        guard attachments.count == 1, attachments[0].kind == .audio else { return nil }
        return attachments[0]
    }
}
