import AppKit
import Combine
import SwiftUI

/// Shows every pinned person as a row of avatars in **one** status item.
///
/// Which avatar was clicked is resolved from the real cursor position on screen
/// (`NSEvent.mouseLocation`) against each avatar's on-screen rect. Event-relative
/// coordinates are only a fallback, because on recent macOS releases clicks on status
/// items can arrive forwarded/synthesized with coordinates that don't match the avatar
/// under the pointer. Clicks are accepted both as raw mouse events on the strip and via
/// the status button's action, whichever path macOS uses.
@MainActor
final class StatusBarController: NSObject {
    static private(set) var shared: StatusBarController?

    private let item: NSStatusItem
    private let strip = AvatarStripView()
    private var cancellables = Set<AnyCancellable>()
    private let tooltip = AvatarTooltip()

    var onOpenSettings: (() -> Void)?
    var onStopScreenRecording: (() -> Void)?

    private var state: AppState { .shared }

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        Self.shared = self
        item.autosaveName = "OpenHoyAvatars"
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.imagePosition = .noImage
            // Fallback path: if macOS delivers the click to the button rather than our view.
            button.target = self
            button.action = #selector(buttonAction(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            strip.frame = button.bounds
            strip.autoresizingMask = [.width, .height]
            button.addSubview(strip)
        }
        strip.onActivate = { [weak self] hit, rightClick in self?.activate(hit, rightClick: rightClick) }
        strip.onDropFiles = { [weak self] guid, urls in self?.dropped(urls, on: guid) }
        strip.onHover = { [weak self] guid in self?.hover(guid) }
        strip.onWidthChange = { [weak self] width in
            guard let self, abs(self.item.length - width) > 0.25 else { return }
            self.item.length = width
        }

        Publishers.MergeMany(
            state.$pinnedGUIDs.map { _ in () }.eraseToAnyPublisher(),
            state.$unread.map { _ in () }.eraseToAnyPublisher(),
            state.$drafts.map { _ in () }.eraseToAnyPublisher(),
            state.$openChatGUID.map { _ in () }.eraseToAnyPublisher(),
            state.$contactsVersion.map { _ in () }.eraseToAnyPublisher(),
            state.$recentChats.map { _ in () }.eraseToAnyPublisher(),
            ScreenRecordCoordinator.shared.$isRecording.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refresh() }
        .store(in: &cancellables)
        refresh()
    }

    func refresh() {
        strip.entries = state.pinnedChats.map { chat in
            AvatarEntry(guid: chat.guid, person: state.person(for: chat),
                        unread: state.unread.contains(chat.guid),
                        draft: state.hasDraft(chat.guid) && state.openChatGUID != chat.guid,
                        active: state.openChatGUID == chat.guid)
        }
        strip.isRecording = ScreenRecordCoordinator.shared.isRecording
        item.length = strip.preferredWidth
        strip.needsDisplay = true
    }

    /// Screen rect of a pinned person's avatar, used to anchor the panel.
    func anchorRect(for guid: String) -> NSRect? {
        strip.screenRect(for: guid)
    }

    /// True when the pointer is over our status item (so the panel shouldn't treat the
    /// click as "outside").
    func containsMouse() -> Bool {
        strip.screenBounds.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    // MARK: - Actions

    /// Debounces the two delivery paths (view mouse event + button action) for one click.
    private var lastActivation: TimeInterval = 0
    private var lastHit: AvatarStripView.Hit?

    @objc private func buttonAction(_ sender: Any?) {
        let event = NSApp.currentEvent
        let right = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        activate(strip.hit(event: event), rightClick: right)
    }

    private func activate(_ hit: AvatarStripView.Hit, rightClick: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if hit == lastHit, now - lastActivation < 0.2 { return }
        lastActivation = now
        lastHit = hit
        tooltip.hide()

        if rightClick {
            showMenu()
            return
        }
        switch hit {
        case .avatar(let guid):
            let anchor = strip.screenRect(for: guid) ?? strip.screenBounds
            ChatPanelController.shared.toggle(chatGUID: guid, anchor: anchor)
        case .stopRecording:
            onStopScreenRecording?()
        case .empty:
            if strip.entries.isEmpty { onOpenSettings?() }
        }
    }

    private func dropped(_ urls: [URL], on guid: String) {
        tooltip.hide()
        state.composer(for: guid).addFiles(urls)
        ChatPanelController.shared.show(chatGUID: guid, anchor: strip.screenRect(for: guid) ?? strip.screenBounds)
    }

    private func hover(_ guid: String?) {
        guard let guid, let chat = state.chat(guid: guid), state.openChatGUID != guid,
              let rect = strip.screenRect(for: guid) else {
            tooltip.hide()
            return
        }
        tooltip.show(text: state.person(for: chat).name, below: rect)
    }

    private func showMenu() {
        guard let button = item.button else { return }
        menu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        let pinMenu = NSMenu()
        for chat in state.recentChats.prefix(30) {
            let entry = NSMenuItem(title: state.person(for: chat).name, action: #selector(togglePin(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = chat.guid
            let pinned = state.pinnedGUIDs.contains(chat.guid)
            entry.state = pinned ? .on : .off
            if !pinned && state.pinnedGUIDs.count >= AppState.maxPinned { entry.action = nil }
            pinMenu.addItem(entry)
        }
        if pinMenu.items.isEmpty {
            pinMenu.addItem(NSMenuItem(title: "No conversations found", action: nil, keyEquivalent: ""))
        }
        let pinItem = NSMenuItem(title: "Pinned People (\(state.pinnedGUIDs.count)/\(AppState.maxPinned))", action: nil, keyEquivalent: "")
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenHoy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let guid = sender.representedObject as? String, let chat = state.chat(guid: guid) else { return }
        state.togglePin(chat)
    }

    @objc private func openSettings() { onOpenSettings?() }

    // MARK: - Debug

    func snapshot(to url: URL) {
        guard let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else { return }
        strip.cacheDisplay(in: strip.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Development aid: clicks every avatar through both delivery paths and logs what opens.
    func selfTest() {
        guard let window = strip.window else { NSLog("SELFTEST no window"); return }
        NSLog("SELFTEST window=%@ strip=%@ entries=%d", NSStringFromRect(window.frame), NSStringFromRect(strip.frame), strip.entries.count)
        for (index, entry) in strip.entries.enumerated() {
            guard let rect = strip.screenRect(for: entry.guid) else { continue }
            let center = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            lastActivation = 0
            lastHit = nil
            if ProcessInfo.processInfo.environment["OPENHOY_SELFTEST"] == "pointer" {
                // Simulates macOS routing the click to the button action with no usable
                // coordinates: only the real pointer position can identify the avatar.
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: primaryHeight - rect.midY))
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                buttonAction(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                NSLog("SELFTEST pointer %@ → open=%@", entry.guid, state.openChatGUID ?? "nil")
                continue
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            NSLog("SELFTEST clicked %@ → open=%@", entry.guid, state.openChatGUID ?? "nil")
            ChatPanelController.shared.snapshot(to: URL(fileURLWithPath: "/tmp/openhoy-scratch/selftest-\(index).png"))
        }
    }
}

// MARK: - Avatar strip

struct AvatarEntry: Equatable {
    let guid: String
    let person: Person
    let unread: Bool
    let draft: Bool
    let active: Bool
}

final class AvatarStripView: NSView {
    enum Hit: Equatable { case avatar(String), stopRecording, empty }

    var entries: [AvatarEntry] = [] {
        didSet {
            guard entries != oldValue else { return }
            needsDisplay = true
            onWidthChange?(preferredWidth)
        }
    }
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            needsDisplay = true
            onWidthChange?(preferredWidth)
        }
    }

    var onActivate: ((Hit, Bool) -> Void)?
    var onDropFiles: ((String, [URL]) -> Void)?
    var onHover: ((String?) -> Void)?
    /// The status item must follow the strip's width when people are added or removed.
    var onWidthChange: ((CGFloat) -> Void)?

    // Geometry (points): faces side by side with a small gap, always.
    static let avatarSize: CGFloat = 20
    private let step: CGFloat = 20 + 5
    private let padding: CGFloat = 4
    private var recordWidth: CGFloat { isRecording ? 30 : 0 }

    private var hovered: String? {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            onHover?(hovered)
        }
    }
    private var dragTarget: String? { didSet { if dragTarget != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    var preferredWidth: CGFloat {
        if entries.isEmpty { return 26 + recordWidth }
        return padding * 2 + recordWidth + Self.avatarSize + CGFloat(entries.count - 1) * step
    }

    private func avatarRect(_ index: Int) -> NSRect {
        let d = min(Self.avatarSize, bounds.height)
        let x = padding + recordWidth + CGFloat(index) * step
        return NSRect(x: x, y: (bounds.height - d) / 2, width: d, height: d)
    }

    /// Hit slots: each face plus half the gap on either side, full bar height (no dead zones).
    private func hitSlot(_ index: Int) -> NSRect {
        let r = avatarRect(index)
        let gap = step - r.width
        return NSRect(x: r.minX - gap / 2, y: bounds.minY - 4, width: r.width + gap, height: bounds.height + 8)
    }

    var screenBounds: NSRect { toScreen(bounds) }

    func screenRect(for guid: String) -> NSRect? {
        guard let i = entries.firstIndex(where: { $0.guid == guid }) else { return nil }
        return toScreen(avatarRect(i))
    }

    private func toScreen(_ rect: NSRect) -> NSRect {
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func hit(local point: NSPoint) -> Hit {
        if isRecording, point.x < padding + recordWidth { return .stopRecording }
        for i in entries.indices where hitSlot(i).contains(point) { return .avatar(entries[i].guid) }
        return .empty
    }

    /// What the user clicked: trust the real pointer position when it's over us; fall back
    /// to the event's own coordinates (e.g. for synthesized events).
    func hit(event: NSEvent?) -> Hit {
        if let window {
            let pointer = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if bounds.insetBy(dx: -2, dy: -4).contains(pointer) {
                let h = hit(local: pointer)
                if h != .empty { return h }
            }
        }
        if let event, event.window === window {
            return hit(local: convert(event.locationInWindow, from: nil))
        }
        return .empty
    }

    // MARK: Drawing

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isRecording {
                AvatarRenderer.drawRecordingBadge(in: NSRect(x: padding, y: 0, width: 26, height: bounds.height))
            }
            if entries.isEmpty {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                if let image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "OpenHoy")?
                    .withSymbolConfiguration(config) {
                    let tinted = image.tinted(.labelColor)
                    let s = tinted.size
                    tinted.draw(in: NSRect(x: recordWidth + (26 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
                }
                return
            }
            for (i, entry) in entries.enumerated() {
                let isHovered = hovered == entry.guid
                var rect = avatarRect(i)
                if isHovered || dragTarget == entry.guid { rect = rect.insetBy(dx: -1.25, dy: -1.25) }
                AvatarRenderer.draw(entry, emphasized: dragTarget == entry.guid, hovered: isHovered, in: rect)
            }
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    private func updateHover(_ event: NSEvent) {
        if case .avatar(let guid) = hit(event: event) { hovered = guid } else { hovered = nil }
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?(hit(event: event), event.modifierFlags.contains(.control))
    }

    override func rightMouseDown(with event: NSEvent) {
        onActivate?(hit(event: event), true)
    }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdated(sender) }

    private func dragTargetGUID(_ sender: NSDraggingInfo) -> String? {
        if case .avatar(let guid) = hit(event: nil) { return guid }
        if case .avatar(let guid) = hit(local: convert(sender.draggingLocation, from: nil)) { return guid }
        return nil
    }

    private func dragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragTarget = dragTargetGUID(sender) ?? (entries.count == 1 ? entries[0].guid : nil)
        hovered = dragTarget
        return dragTarget == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragTarget = nil
        hovered = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dragTarget = nil }
        guard let guid = dragTarget ?? dragTargetGUID(sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(guid, urls)
        return true
    }
}

// MARK: - Drawing

enum AvatarRenderer {
    static let brandGradient = NSGradient(colors: [
        NSColor(srgbRed: 0.98, green: 0.42, blue: 0.22, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.16, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.50, green: 0.22, blue: 0.95, alpha: 1),
    ])!
    static let unreadColor = NSColor(srgbRed: 0.93, green: 0.16, blue: 0.55, alpha: 1)

    /// Menu bar faces are plain circles.
    static func shape(in rect: NSRect) -> NSBezierPath {
        NSBezierPath(ovalIn: rect)
    }

    static func drawRecordingBadge(in bounds: NSRect) {
        let r = NSRect(x: bounds.minX + 1, y: (bounds.height - 18) / 2, width: 24, height: 18)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.midX - 3.5, y: r.midY - 3.5, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5).fill()
    }

    static func draw(_ entry: AvatarEntry, emphasized: Bool, hovered: Bool, in rect: NSRect) {
        let ink = NSColor.labelColor

        NSGraphicsContext.saveGraphicsState()
        shape(in: rect).addClip()
        if let image = entry.person.image {
            image.draw(in: rect.aspectFill(image.size), from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            drawInitials(entry.person, in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.12).setStroke()
        let hairline = shape(in: rect.insetBy(dx: 0.25, dy: 0.25))
        hairline.lineWidth = 0.5
        hairline.stroke()

        if entry.active || emphasized {
            // OpenHoy's sunset gradient ring marks the open conversation.
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                let ring = CGPath(ellipseIn: rect.insetBy(dx: 1, dy: 1), transform: nil)
                    .copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
                ctx.addPath(ring)
                ctx.clip()
                brandGradient.draw(in: rect, angle: -45)
                ctx.restoreGState()
            }
        } else if hovered {
            // Soft halo on hover.
            let halo = shape(in: rect.insetBy(dx: -1.2, dy: -1.2))
            halo.lineWidth = 1.5
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            halo.stroke()
        }

        if entry.unread {
            let dot = NSRect(x: rect.maxX - 5.5, y: rect.maxY - 6.5, width: 7, height: 7)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.3, dy: -1.3)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            unreadColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        if entry.draft {
            let badge = NSRect(x: rect.maxX - 8, y: rect.minY - 0.5, width: 10, height: 10)
            ink.setFill()
            NSBezierPath(ovalIn: badge).fill()
            if let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 6, weight: .bold)) {
                let tinted = pencil.tinted(NSColor.windowBackgroundColor)
                let s = tinted.size
                tinted.draw(in: NSRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height))
            }
        }
    }

    private static func drawInitials(_ person: Person, in rect: NSRect) {
        let top = NSColor(hue: person.hue, saturation: 0.45, brightness: 0.85, alpha: 1)
        let bottom = NSColor(hue: person.hue, saturation: 0.6, brightness: 0.6, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
        if person.initials.isEmpty {
            if let glyph = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: rect.height * 0.5, weight: .semibold)) {
                let tinted = glyph.tinted(.white)
                let s = tinted.size
                tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return
        }
        let font = NSFont.systemFont(ofSize: rect.height * 0.4, weight: .semibold)
        let text = NSAttributedString(string: String(person.initials.prefix(2)),
                                      attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

// MARK: - Tooltip

@MainActor
final class AvatarTooltip {
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var currentText: String?

    func show(text: String, below rect: NSRect) {
        if currentText == text, panel?.isVisible == true { position(below: rect); return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.present(text: text, below: rect) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel?.isVisible == true ? 0 : 0.25), execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        currentText = nil
        panel?.orderOut(nil)
    }

    private func present(text: String, below rect: NSRect) {
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .popUpMenu
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = p
            return p
        }()
        let view = NSHostingView(rootView: TooltipView(text: text))
        view.layoutSubtreeIfNeeded()
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        currentText = text
        position(below: rect)
        panel.orderFrontRegardless()
    }

    private func position(below rect: NSRect) {
        guard let panel else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 3))
    }
}

private struct TooltipView: View {
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(0.6)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(white: 0.16).opacity(0.92)))
        .padding(4)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Helpers

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

extension NSRect {
    /// Rect that fills `self` with content of `size`, centered (for drawing photos into circles).
    func aspectFill(_ size: NSSize) -> NSRect {
        guard size.width > 0, size.height > 0 else { return self }
        let scale = max(width / size.width, height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }
}
