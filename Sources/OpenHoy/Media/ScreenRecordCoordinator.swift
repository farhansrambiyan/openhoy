import AppKit
import SwiftUI

/// Drives the record-screen flow: pick a window/area → record (with face bubble) → attach to the draft.
@MainActor
final class ScreenRecordCoordinator: ObservableObject {
    static let shared = ScreenRecordCoordinator()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var microphoneOn: Bool { didSet { UserDefaults.standard.set(microphoneOn, forKey: "screenRecordMic") } }
    @Published var cameraOn: Bool { didSet { UserDefaults.standard.set(cameraOn, forKey: "screenRecordCamera") } }

    private var overlays: [SelectionOverlayWindow] = []
    private var recorder: ScreenRecorder?
    private var faceCamera: CameraRecorder?
    private var faceWindow: NSPanel?
    private var hud: NSPanel?
    private var chatGUID: String?
    private var startDate: Date?
    private var ticker: Timer?

    private init() {
        microphoneOn = UserDefaults.standard.object(forKey: "screenRecordMic") as? Bool ?? true
        cameraOn = UserDefaults.standard.object(forKey: "screenRecordCamera") as? Bool ?? true
    }

    // MARK: - Selection

    func begin(for chat: ChatSummary) {
        guard !isRecording, overlays.isEmpty else { return }
        chatGUID = chat.guid
        ChatPanelController.shared.hide()

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            reportError(ScreenRecorderError.permission.localizedDescription)
            return
        }

        let windows = Self.onScreenWindows()
        PanelAutoClose.suspend()
        NSApp.activate(ignoringOtherApps: true)
        overlays = NSScreen.screens.map { screen in
            let overlay = SelectionOverlayWindow(screen: screen, windows: windows, coordinator: self)
            overlay.orderFrontRegardless()
            return overlay
        }
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
    }

    func cancelSelection() {
        closeOverlays()
        if let guid = chatGUID { reopenPanel(guid) }
    }

    func select(_ target: ScreenTarget, recordingFrame: NSRect, screen: NSScreen) {
        closeOverlays()
        Task { await startRecording(target, frame: recordingFrame, screen: screen) }
    }

    private func closeOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        PanelAutoClose.resume()
    }

    // MARK: - Recording

    private func startRecording(_ target: ScreenTarget, frame: NSRect, screen: NSScreen) async {
        if microphoneOn, !(await MediaPermission.microphone()) {
            microphoneOn = false
        }
        if cameraOn { await showFaceBubble(near: frame) }
        showHUD(on: screen)

        let recorder = ScreenRecorder()
        self.recorder = recorder
        let excluded = [hud].compactMap { $0.map { CGWindowID($0.windowNumber) } }
        do {
            try await recorder.start(target: target, microphone: microphoneOn, excluding: excluded)
            isRecording = true
            startDate = Date()
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }
        } catch {
            tearDown()
            reportError(error.localizedDescription)
        }
    }

    func stop() {
        guard isRecording, let recorder else { return }
        isRecording = false
        Task {
            do {
                let url = try await recorder.stop()
                tearDown()
                if let guid = chatGUID {
                    AppState.shared.composer(for: guid).addFiles([url])
                    reopenPanel(guid)
                }
            } catch {
                tearDown()
                reportError(error.localizedDescription)
            }
        }
    }

    func cancelRecording() {
        recorder?.cancel()
        isRecording = false
        tearDown()
        if let guid = chatGUID { reopenPanel(guid) }
    }

    private func tearDown() {
        ticker?.invalidate()
        ticker = nil
        elapsed = 0
        startDate = nil
        recorder = nil
        hud?.orderOut(nil)
        hud = nil
        faceWindow?.orderOut(nil)
        faceWindow = nil
        faceCamera?.shutdown()
        faceCamera = nil
    }

    private func reportError(_ message: String) {
        guard let guid = chatGUID else { return }
        AppState.shared.composer(for: guid).error = message
        reopenPanel(guid)
    }

    private func reopenPanel(_ guid: String) {
        let anchor = StatusBarController.shared?.anchorRect(for: guid)
            ?? NSRect(x: (NSScreen.main?.frame.midX ?? 600), y: (NSScreen.main?.frame.maxY ?? 800) - 24, width: 1, height: 1)
        ChatPanelController.shared.show(chatGUID: guid, anchor: anchor)
    }

    // MARK: - Face bubble & HUD

    private func showFaceBubble(near frame: NSRect) async {
        let camera = CameraRecorder()
        do {
            try await camera.startPreview(withAudio: false)
        } catch {
            cameraOn = false
            return
        }
        faceCamera = camera
        let size: CGFloat = 170
        let panel = NSPanel(contentRect: NSRect(x: frame.minX + 28, y: frame.minY + 28, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            CameraPreview(session: camera.session)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 3))
        )
        panel.orderFrontRegardless()
        faceWindow = panel
    }

    private func showHUD(on screen: NSScreen) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none          // never show up in the recording
        let view = NSHostingView(rootView: RecordingHUD(coordinator: self))
        view.layoutSubtreeIfNeeded()
        panel.contentView = view
        let size = view.fittingSize
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 8,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        hud = panel
    }

    // MARK: - Window list

    struct WindowInfo {
        let id: CGWindowID
        let frame: NSRect   // Cocoa global coordinates
    }

    /// Normal app windows on screen, front to back.
    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 60, bounds.height > 40 else { return nil }
            let frame = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return WindowInfo(id: id, frame: frame)
        }
    }
}

// MARK: - Selection overlay

final class SelectionOverlayWindow: NSWindow {
    init(screen: NSScreen, windows: [ScreenRecordCoordinator.WindowInfo], coordinator: ScreenRecordCoordinator) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar, but below pop-up menus so the HUD's dropdowns stay visible.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let overlay = SelectionOverlayView(frame: root.bounds, screen: screen, windows: windows, coordinator: coordinator)
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay)

        let hud = NSHostingView(rootView: SelectionHUD(coordinator: coordinator))
        hud.layoutSubtreeIfNeeded()
        let size = hud.fittingSize
        hud.frame = NSRect(x: (root.bounds.width - size.width) / 2, y: (root.bounds.height - size.height) / 2,
                           width: size.width, height: size.height)
        hud.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        root.addSubview(hud)
        contentView = root
        makeFirstResponder(overlay)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionOverlayView: NSView {
    private let screen: NSScreen
    private let windows: [ScreenRecordCoordinator.WindowInfo]
    private weak var coordinator: ScreenRecordCoordinator?
    private var hovered: ScreenRecordCoordinator.WindowInfo?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var tracking: NSTrackingArea?

    init(frame: NSRect, screen: NSScreen, windows: [ScreenRecordCoordinator.WindowInfo], coordinator: ScreenRecordCoordinator) {
        self.screen = screen
        self.windows = windows
        self.coordinator = coordinator
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private var selectionRect: NSRect? {
        guard let a = dragStart, let b = dragCurrent, hypot(a.x - b.x, a.y - b.y) > 4 else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Global Cocoa rect → this view's coordinates.
    private func local(_ global: NSRect) -> NSRect {
        global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tint = NSColor(calibratedRed: 0.32, green: 0.28, blue: 0.85, alpha: 0.30)
        let hole: NSRect? = selectionRect ?? hovered.map { local($0.frame) }

        let path = NSBezierPath(rect: bounds)
        if let hole {
            path.appendRoundedRect(hole, xRadius: 10, yRadius: 10)
            path.windingRule = .evenOdd
        }
        tint.setFill()
        path.fill()

        if let hole {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(roundedRect: hole.insetBy(dx: -1, dy: -1), xRadius: 11, yRadius: 11)
            border.lineWidth = 2
            border.stroke()
            if selectionRect != nil {
                let label = "\(Int(hole.width)) × \(Int(hole.height))" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                            .foregroundColor: NSColor.white]
                let size = label.size(withAttributes: attrs)
                let box = NSRect(x: hole.midX - size.width / 2 - 8, y: hole.minY - size.height - 14, width: size.width + 16, height: size.height + 6)
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
                label.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 3), withAttributes: attrs)
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let global = NSEvent.mouseLocation
        let hit = windows.first { $0.frame.contains(global) }
        if hit?.id != hovered?.id {
            hovered = hit
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragCurrent = nil; needsDisplay = true }
        guard let coordinator else { return }
        if let rect = selectionRect, rect.width > 24, rect.height > 24 {
            let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            coordinator.select(.display(screen.displayID, rect: global), recordingFrame: global, screen: screen)
        } else if let window = hovered {
            coordinator.select(.window(window.id), recordingFrame: window.frame, screen: screen)
        } else {
            coordinator.select(.display(screen.displayID, rect: nil), recordingFrame: screen.frame, screen: screen)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { coordinator?.cancelSelection() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        coordinator?.cancelSelection()
    }
}

// MARK: - HUDs

private struct SelectionHUD: View {
    @ObservedObject var coordinator: ScreenRecordCoordinator

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Record Screen with")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                OptionMenu(title: "Microphone", isOn: $coordinator.microphoneOn)
                OptionMenu(title: "Camera", isOn: $coordinator.cameraOn)
            }
            Text("Click window · Drag to select area · Esc to cancel")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .smokyGlass(cornerRadius: 22, darkness: 0.45)
        .padding(20)
        .environment(\.colorScheme, .dark)
    }

    private struct OptionMenu: View {
        let title: String
        @Binding var isOn: Bool

        var body: some View {
            Menu {
                Button { isOn = true } label: { Label(title, systemImage: isOn ? "checkmark" : "") }
                Button { isOn = false } label: { Label("No \(title)", systemImage: isOn ? "" : "checkmark") }
            } label: {
                HStack(spacing: 5) {
                    Text(isOn ? title : "No \(title)")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(isOn ? 1 : 0.6))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(.white.opacity(0.14)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct RecordingHUD: View {
    @ObservedObject var coordinator: ScreenRecordCoordinator
    @ViewState private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 9, height: 9)
                .opacity(pulse ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text(Theme.duration(coordinator.elapsed))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
            Button { coordinator.stop() } label: {
                Text("Stop").font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            Button { coordinator.cancelRecording() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Cancel recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .smokyGlass(Capsule(), darkness: 0.5)
        .padding(12)
        .environment(\.colorScheme, .dark)
    }
}
