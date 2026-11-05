@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// Camera session used both for "video note" recording in the composer and for the
/// floating face bubble during screen recordings (preview only).
@MainActor
final class CameraRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isRunning = false

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var startDate: Date?
    private var ticker: Timer?
    private var finishContinuation: CheckedContinuation<URL, Error>?
    private let sessionQueue = DispatchQueue(label: "openhoy.camera")

    /// Configures and starts the capture session. `withAudio` adds the microphone (for video notes).
    func startPreview(withAudio: Bool) async throws {
        guard await MediaPermission.camera() else { throw RecorderError.cameraDenied }
        if withAudio, !(await MediaPermission.microphone()) { throw RecorderError.microphoneDenied }
        guard let camera = AVCaptureDevice.default(for: .video) else { throw RecorderError.noDevice }

        session.beginConfiguration()
        session.sessionPreset = .high
        if let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) { session.addInput(input) }
        if withAudio, let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
        }
        if withAudio, session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()

        let session = self.session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                session.startRunning()
                continuation.resume()
            }
        }
        isRunning = true
    }

    func startRecording() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OpenHoy/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Video Note.mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        startDate = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    func stopRecording() async throws -> URL {
        ticker?.invalidate()
        ticker = nil
        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            movieOutput.stopRecording()
        }
    }

    func shutdown() {
        ticker?.invalidate()
        ticker = nil
        if movieOutput.isRecording { movieOutput.stopRecording() }
        let session = self.session
        sessionQueue.async { session.stopRunning() }
        isRunning = false
        isRecording = false
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            let success = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
            if success {
                self.finishContinuation?.resume(returning: outputFileURL)
            } else {
                self.finishContinuation?.resume(throwing: error ?? RecorderError.noDevice)
            }
            self.finishContinuation = nil
        }
    }
}

/// Mirrored live camera preview.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer          // layer-hosting: assign before enabling wantsLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
