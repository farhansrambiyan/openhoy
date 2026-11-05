import AVFoundation
import AppKit
import ScreenCaptureKit

enum ScreenTarget {
    /// A single window, captured on its own (other windows never leak in).
    case window(CGWindowID)
    /// A whole display, or `rect` of it (Cocoa global coordinates).
    case display(CGDirectDisplayID, rect: NSRect?)
}

enum ScreenRecorderError: LocalizedError {
    case permission, targetGone, failed(String)

    var errorDescription: String? {
        switch self {
        case .permission: return "Screen recording is off for OpenHoy (System Settings › Privacy & Security › Screen & System Audio Recording)."
        case .targetGone: return "That window or display is no longer available."
        case .failed(let reason): return reason
        }
    }
}

/// Records the screen (plus optional microphone) straight to an .mp4 using ScreenCaptureKit.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    let outputURL: URL
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private let queue = DispatchQueue(label: "openhoy.screen")
    private let lock = NSLock()
    private var finished = false
    private var finishError: Error?
    private var finishContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OpenHoy/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outputURL = dir.appendingPathComponent("Screen Recording.mp4")
        super.init()
    }

    func start(target: ScreenTarget, microphone: Bool, excluding excludedIDs: [CGWindowID]) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenRecorderError.permission
        }

        let config = SCStreamConfiguration()
        let filter: SCContentFilter

        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw ScreenRecorderError.targetGone }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Self.even(filter.contentRect.width * scale)
            config.height = Self.even(filter.contentRect.height * scale)
        case .display(let displayID, let rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenRecorderError.targetGone }
            let excluded = content.windows.filter { excludedIDs.contains($0.windowID) }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            let screen = NSScreen.screens.first { $0.displayID == displayID }
            let scale = screen?.backingScaleFactor ?? CGFloat(filter.pointPixelScale)
            if let rect, let screen {
                // ScreenCaptureKit wants display-local points with a top-left origin.
                let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
                config.sourceRect = local
                config.width = Self.even(local.width * scale)
                config.height = Self.even(local.height * scale)
            } else {
                config.width = Self.even(CGFloat(display.width) * scale)
                config.height = Self.even(CGFloat(display.height) * scale)
            }
        }

        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.capturesAudio = false
        if microphone {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = outputURL
        recordingConfig.outputFileType = .mp4
        recordingConfig.videoCodecType = .h264
        let recording = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        try stream.addRecordingOutput(recording)

        self.stream = stream
        self.recording = recording
        try await stream.startCapture()
    }

    func stop() async throws -> URL {
        guard let stream else { throw ScreenRecorderError.failed("Not recording.") }
        try? await stream.stopCapture()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if finished {
                lock.unlock()
                if let finishError { continuation.resume(throwing: finishError) } else { continuation.resume() }
                return
            }
            finishContinuation = continuation
            lock.unlock()
            // Safety net in case the delegate never fires.
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.complete(nil) }
        }
        self.stream = nil
        return outputURL
    }

    func cancel() {
        Task { try? await stream?.stopCapture() }
        stream = nil
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func complete(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        finishError = error
        let continuation = finishContinuation
        finishContinuation = nil
        lock.unlock()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    private static func even(_ value: CGFloat) -> Int {
        let v = max(2, Int(value.rounded()))
        return v - v % 2
    }

    // MARK: Delegates

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        complete(error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        complete(nil)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        complete(error)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
