import AppKit
import SwiftUI

/// Suspends click-outside-to-close while a modal (open panel, screen picker…) is up.
@MainActor
enum PanelAutoClose {
    private(set) static var suspensions = 0
    static var isSuspended: Bool { suspensions > 0 }
    static func suspend() { suspensions += 1 }
    static func resume() { suspensions = max(0, suspensions - 1) }
}

/// Borderless panel that can take keyboard focus without activating the app,
/// so typing works while the app you were in stays frontmost.
final class KeyablePanel: NSPanel {
    var onReturn: (() -> Bool)?
    var onEscape: (() -> Void)?
    /// ⌘V with files or an image on the clipboard: attach instead of pasting text.
    var onPasteAttachments: (([URL]) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// OpenHoy is a menu-bar app without an Edit menu, so the standard editing shortcuts
    /// have to be routed to the text field by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: Selector?
        switch (flags, key) {
        case ([.command], "v"):
            if let urls = Self.attachmentsOnPasteboard(), !urls.isEmpty, let onPasteAttachments {
                onPasteAttachments(urls)
                return true
            }
            action = #selector(NSText.paste(_:))
        case ([.command], "c"): action = #selector(NSText.copy(_:))
        case ([.command], "x"): action = #selector(NSText.cut(_:))
        case ([.command], "a"): action = #selector(NSText.selectAll(_:))
        case ([.command], "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        case ([.command, .option], "v"), ([.command, .shift, .option], "v"):
            action = #selector(NSTextView.pasteAsPlainText(_:))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Files copied in Finder, or a copied image (screenshot, browser image) with no text.
    private static func attachmentsOnPasteboard() -> [URL]? {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        guard pasteboard.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OpenHoy/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Pasted Image.png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return [url]
    }

    override func sendEvent(_ event: NSEvent) {
        let composingIME = (firstResponder as? NSTextView)?.hasMarkedText() ?? false
        if event.type == .keyDown, !composingIME {
            switch event.keyCode {
            case 36, 76:   // return / keypad enter
                if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                    (firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
                    return
                }
                if onReturn?() == true { return }
            case 53:       // escape
                onEscape?()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class ChatPanelController: NSObject {
    static let shared = ChatPanelController()

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<AnyView>?
    private var anchor: NSRect = .zero
    private var contentSize: CGSize = .zero
    private var clickMonitor: Any?
    var onScreenRecord: ((ChatSummary) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    private var state: AppState { .shared }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth + 12, height: 400),
                                 styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let root = ChatPanelRoot(
            onSize: { [weak self] size in self?.contentSizeChanged(size) },
            onScreenRecord: { [weak self] chat in self?.onScreenRecord?(chat) }
        ).environmentObject(state)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.hosting = hosting

        panel.onReturn = { [weak self] in self?.handleReturn() ?? false }
        panel.onEscape = { [weak self] in self?.handleEscape() }
        panel.onPasteAttachments = { [weak self] urls in
            guard let self, let guid = self.state.openChatGUID else { return }
            self.state.composer(for: guid).addFiles(urls)
        }
        return panel
    }

    // MARK: - Show / hide

    func toggle(chatGUID: String, anchor: NSRect) {
        if isVisible && state.openChatGUID == chatGUID {
            hide()
        } else {
            show(chatGUID: chatGUID, anchor: anchor)
        }
    }

    func show(chatGUID: String, anchor: NSRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        self.anchor = anchor
        state.openChatGUID = chatGUID
        state.markSeen(chatGUID)
        if state.visibleMessages(for: chatGUID).isEmpty {
            Task { await state.refresh(force: true) }   // first open before the poll caught up
        }

        // Lay out once so we know the height before showing.
        hosting?.layoutSubtreeIfNeeded()
        reposition(animated: false)

        // No open animation: an animated frame would land on the height measured at open
        // time and clip anything that grew meanwhile (attachments, new messages).
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        state.composer(for: chatGUID).focusToken += 1
        installClickMonitor()
        StatusBarController.shared?.refresh()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        removeClickMonitor()
        // Instant, so a quick re-open can't be hidden by a lagging close animation.
        panel.orderOut(nil)
        if let guid = state.openChatGUID { state.markSeen(guid) }
        state.openChatGUID = nil
        AudioPlayback.shared.stop()
        StatusBarController.shared?.refresh()
    }

    /// Steps aside (without closing the conversation) so a system dialog can sit on top.
    func stepAsideForModal() {
        panel?.orderOut(nil)
    }

    /// Brings the panel and keyboard focus back after a modal (e.g. the file picker) closes.
    func refocus() {
        guard let panel, state.openChatGUID != nil else { return }
        panel.makeKeyAndOrderFront(nil)
        if let guid = state.openChatGUID { state.composer(for: guid).focusToken += 1 }
    }

    // MARK: - Layout

    private func contentSizeChanged(_ size: CGSize) {
        guard size != contentSize else { return }
        contentSize = size
        reposition(animated: false)
    }

    private func reposition(animated: Bool) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let width = Theme.panelWidth(expanded: state.panelExpanded) + 12
        let height = max(120, min(contentSize.height, screen.visibleFrame.height))
        var x = anchor.midX - width / 2
        x = min(max(x, screen.frame.minX + 6), screen.frame.maxX - width - 6)
        let top = screen.visibleFrame.maxY - 2
        let frame = NSRect(x: x, y: top - height, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: animated) }
    }

    // MARK: - Keys

    private func handleReturn() -> Bool {
        guard let guid = state.openChatGUID else { return false }
        let composer = state.composer(for: guid)
        if composer.isRecording {
            composer.stopRecording()
            return true
        }
        if composer.canSend {
            state.send(from: composer)
        }
        return true
    }

    private func handleEscape() {
        guard let guid = state.openChatGUID else { hide(); return }
        let composer = state.composer(for: guid)
        if composer.hasContent {
            composer.discard()
        } else {
            hide()
        }
    }

    // MARK: - Debug

    /// Development aid: pastes a test string via ⌘V into the composer, then restores the clipboard.
    func pasteTest() {
        guard let panel, let guid = state.openChatGUID else { NSLog("PASTETEST no panel"); return }
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString("pasted ✓", forType: .string)
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                        windowNumber: panel.windowNumber, context: nil, characters: "v",
                                        charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) {
            let handled = panel.performKeyEquivalent(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            NSLog("PASTETEST handled=%d firstResponder=%@ text=%@", handled ? 1 : 0,
                  String(describing: panel.firstResponder.map { type(of: $0) }), state.composer(for: guid).text)
        }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    /// Writes the panel's contents to a PNG (development aid; blur isn't captured).
    func snapshot(to url: URL) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - Click outside

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.clickedOutside() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func clickedOutside() {
        guard !PanelAutoClose.isSuspended else { return }
        // A click on our own avatars is handled by the status item (switch / toggle),
        // even if macOS also reports it to us as a click in another process.
        if StatusBarController.shared?.containsMouse() == true { return }
        if let guid = state.openChatGUID, state.composer(for: guid).isRecording { return }
        hide()
    }
}
