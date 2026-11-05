import SwiftUI
import UniformTypeIdentifiers

/// Root of the drop-down panel: one Liquid Glass card holding the whole conversation.
struct ChatPanelRoot: View {
    @EnvironmentObject private var state: AppState
    let onSize: (CGSize) -> Void
    let onScreenRecord: (ChatSummary) -> Void

    var body: some View {
        Group {
            if let guid = state.openChatGUID, let chat = state.chat(guid: guid) {
                ChatPanelView(chat: chat, composer: state.composer(for: guid), onScreenRecord: { onScreenRecord(chat) })
                    .id(guid)
                    // Always lay out at full natural height, so the window grows to fit
                    // (instead of the content being squeezed into the window's current size).
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(width: Theme.panelWidth(expanded: state.panelExpanded) + 12)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ChatPanelView: View {
    let chat: ChatSummary
    @ObservedObject var composer: ComposerModel
    let onScreenRecord: () -> Void
    @EnvironmentObject private var state: AppState
    @ViewState private var listHeight: CGFloat
    @ViewState private var dropTargeted = false

    init(chat: ChatSummary, composer: ComposerModel, onScreenRecord: @escaping () -> Void) {
        self.chat = chat
        self.composer = composer
        self.onScreenRecord = onScreenRecord
        _listHeight = ViewState(initialValue: ListHeightCache.shared[chat.guid] ?? 0)
    }

    private var width: CGFloat { Theme.panelWidth(expanded: state.panelExpanded) }

    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        let available = screen - 300 - (composer.files.isEmpty ? 0 : 100)
        return max(200, state.panelExpanded ? available : min(available, 470))
    }

    var body: some View {
        let messages = state.visibleMessages(for: chat.guid)
        let person = state.person(for: chat)

        VStack(spacing: 0) {
            ChatHeader(chat: chat, person: person)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider().opacity(0.5)

            if !messages.isEmpty {
                messageList(messages)
            } else if state.access != .granted {
                NoAccessNote().padding(16)
            } else {
                Text("No messages yet. Say hi!")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .padding(.vertical, 28)
            }

            ComposerView(composer: composer, person: person,
                         onSend: { state.send(from: composer) },
                         onScreenRecord: onScreenRecord)
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                    }
                }
                .padding(8)
        }
        .frame(width: width)
        .cardSurface()
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in composer.addFiles([url]) }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private func messageList(_ messages: [ChatMessage]) -> some View {
        let overflowing = listHeight > maxListHeight
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 3) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    let previous = index > 0 ? messages[index - 1] : nil
                    let separator = TimeSeparator.label(for: message.date, after: previous?.date)
                    if let separator {
                        Text(separator)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .frame(maxWidth: .infinity)
                            .padding(.top, index == 0 ? 2 : 10)
                            .padding(.bottom, 4)
                    }
                    let startsGroup = separator != nil || previous == nil
                        || previous?.isFromMe != message.isFromMe
                        || (!message.isFromMe && previous?.sender != message.sender)
                    MessageRow(message: message, chat: chat, startsGroup: startsGroup,
                               repliedTo: message.replyToGUID.flatMap { byID[$0] },
                               isReply: message.replyToGUID != nil)
                        .padding(.top, startsGroup && separator == nil && index > 0 ? 8 : 0)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                listHeight = height
                ListHeightCache.shared[chat.guid] = height
            }
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: min(listHeight, maxListHeight))
        .mask {
            // Soft edges where messages scroll under the header and composer.
            LinearGradient(stops: [
                .init(color: overflowing ? .clear : .black, location: 0),
                .init(color: .black, location: overflowing ? 0.06 : 0),
                .init(color: .black, location: 0.96),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: messages.map(\.id))
    }
}

/// Remembers each conversation's content height between openings.
@MainActor
final class ListHeightCache {
    static let shared = ListHeightCache()
    private var heights: [String: CGFloat] = [:]
    subscript(guid: String) -> CGFloat? {
        get { heights[guid] }
        set { heights[guid] = newValue }
    }
}

// MARK: - Header

private struct ChatHeader: View {
    let chat: ChatSummary
    let person: Person
    @EnvironmentObject private var state: AppState

    private var detail: String? {
        if chat.isGroup { return "\(chat.participants.count) people" }
        let handle = ContactResolver.prettyHandle(chat.primaryHandle)
        return handle == person.name ? nil : handle
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(person: person, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ServiceChip(service: chat.service)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            HeaderButton(symbol: "arrow.up.forward.app", help: "Open in Messages") { openInMessages() }
            HeaderButton(symbol: state.panelExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: state.panelExpanded ? "Collapse" : "Expand") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { state.panelExpanded.toggle() }
            }
        }
    }

    private func openInMessages() {
        ChatPanelController.shared.hide()
        let encoded = chat.primaryHandle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        if !chat.isGroup, let url = URL(string: "imessage:\(encoded)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Permissions.messagesBundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Small coloured tag: iMessage (accent) or SMS / RCS (green, like Messages).
private struct ServiceChip: View {
    let service: String
    private var isIMessage: Bool { service.lowercased() == "imessage" || service.lowercased() == "any" }

    var body: some View {
        Text(isIMessage ? "iMessage" : service.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(isIMessage ? Theme.accent : Color.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill((isIMessage ? Theme.accent : Color.green).opacity(0.13)))
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.9 : 0.6))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Time separators

enum TimeSeparator {
    /// "Today · 8:38" style label when a message starts a new session (first message, or >20 min gap).
    static func label(for date: Date, after previous: Date?) -> String? {
        if let previous, date.timeIntervalSince(previous) < 20 * 60 { return nil }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today · \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday · \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide)) + " · \(time)"
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year()) + " · \(time)"
    }
}

private struct NoAccessNote: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("OpenHoy needs Full Disk Access to show your iMessage history.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("Open Privacy Settings") { Permissions.openFullDiskAccessSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity)
    }
}
