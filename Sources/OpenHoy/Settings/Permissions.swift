import AVFoundation
import AppKit
import Contacts
import CoreServices
import Speech

enum PermissionStatus: Equatable {
    case granted, denied, notDetermined, unknown

    var symbol: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined, .unknown: return "circle.dashed"
        }
    }
}

@MainActor
enum Permissions {
    /// Opens System Settings › Privacy & Security at the given pane (e.g. `Privacy_AllFiles`).
    static func open(_ anchor: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",  // macOS 13+
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",                  // legacy
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openFullDiskAccessSettings() { open("Privacy_AllFiles") }

    /// Selects OpenHoy.app in Finder so it can be dragged into the Full Disk Access list.
    static func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static var contacts: PermissionStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        default: return .granted   // .limited
        }
    }

    static func capture(_ type: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static var speech: PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static var screenRecording: PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    static let messagesBundleID = "com.apple.MobileSMS"

    /// Whether we may send Apple Events to Messages (never prompts).
    static var messagesAutomation: PermissionStatus {
        mapAutomation(automationStatus(ask: false))
    }

    /// Shows macOS's "OpenHoy wants to control Messages" prompt. The prompt only appears
    /// while Messages is running, so launch it (in the background) first. The request comes
    /// from OpenHoy's own process so the permission is recorded against OpenHoy.
    static func requestMessagesAutomation() async -> PermissionStatus {
        if NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            for _ in 0..<20 where NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Blocks until the user answers, so keep it off the main thread.
        let status = await Task.detached(priority: .userInitiated) { automationStatus(ask: true) }.value
        return mapAutomation(status)
    }

    /// Clears a previous "Don't Allow" so macOS will ask again.
    static func resetMessagesAutomation() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.openhoy.OpenHoy"
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "AppleEvents", bundleID]
            try? process.run()
            process.waitUntilExit()
        }.value
    }

    nonisolated private static func automationStatus(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        // 'core'/'getd' is exactly what sending needs (and asking with a concrete event is
        // more reliable than wildcards).
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), ask)
    }

    private static func mapAutomation(_ status: OSStatus) -> PermissionStatus {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown   // e.g. Messages isn't running, so macOS can't tell yet
        }
    }
}
