import AppKit
import Combine

/// Per-chat draft: text, staged files, and any in-progress voice / camera note.
@MainActor
final class ComposerModel: ObservableObject {
    enum Mode: Equatable { case idle, recordingVoice, reviewingVoice, recordingCamera }

    struct Draft {
        var text: String
        var files: [URL]
        var voiceNote: URL?
        var voiceTranscript: String?
    }

    let chatGUID: String
    @Published var text = ""
    @Published private(set) var files: [URL] = []
    @Published private(set) var mode: Mode = .idle
    @Published private(set) var voice: VoiceRecorder?
    @Published private(set) var camera: CameraRecorder?
    @Published var error: String?
    /// Bumped to ask the text field to take focus.
    @Published var focusToken = 0

    var subscriptions = Set<AnyCancellable>()

    init(chatGUID: String) {
        self.chatGUID = chatGUID
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasContent: Bool { !trimmedText.isEmpty || !files.isEmpty || mode != .idle }
    var hasAttachmentsOrVoice: Bool { !files.isEmpty || mode != .idle }
    var isRecording: Bool { mode == .recordingVoice || mode == .recordingCamera }
    var canSend: Bool {
        switch mode {
        case .idle: return !trimmedText.isEmpty || !files.isEmpty
        case .reviewingVoice: return true
        case .recordingVoice, .recordingCamera: return false
        }
    }

    // MARK: - Files

    func addFiles(_ urls: [URL]) {
        let fresh = urls.filter { url in !files.contains(url) }
        guard !fresh.isEmpty else { return }
        files.append(contentsOf: fresh)
        focusToken += 1
    }

    func removeFile(_ url: URL) {
        files.removeAll { $0 == url }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add"
        PanelAutoClose.suspend()
        ChatPanelController.shared.stepAsideForModal()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            PanelAutoClose.resume()
            if response == .OK { self?.addFiles(panel.urls) }
            ChatPanelController.shared.refocus()
        }
    }

    // MARK: - Voice

    func startVoice() {
        guard mode == .idle else { return }
        let recorder = VoiceRecorder()
        voice = recorder
        mode = .recordingVoice
        Task {
            do {
                try await recorder.start()
            } catch {
                self.error = error.localizedDescription
                self.voice = nil
                self.mode = .idle
            }
        }
    }

    func stopVoice() {
        guard mode == .recordingVoice, let voice else { return }
        voice.stop()
        if voice.elapsed < 0.4 {
            discardVoice()
        } else {
            mode = .reviewingVoice
        }
    }

    private func discardVoice() {
        AudioPlayback.shared.stop()
        voice?.cancel()
        voice = nil
        if mode == .recordingVoice || mode == .reviewingVoice { mode = .idle }
    }

    // MARK: - Camera

    func startCamera() {
        guard mode == .idle else { return }
        let recorder = CameraRecorder()
        camera = recorder
        mode = .recordingCamera
        Task {
            do {
                try await recorder.startPreview(withAudio: true)
                recorder.startRecording()
            } catch {
                self.error = error.localizedDescription
                recorder.shutdown()
                self.camera = nil
                self.mode = .idle
            }
        }
    }

    func stopCamera() {
        guard mode == .recordingCamera, let camera else { return }
        Task {
            do {
                let url = try await camera.stopRecording()
                camera.shutdown()
                self.camera = nil
                self.mode = .idle
                self.addFiles([url])
            } catch {
                camera.shutdown()
                self.camera = nil
                self.mode = .idle
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Lifecycle

    /// Enter / Stop button: stops whatever is recording.
    func stopRecording() {
        switch mode {
        case .recordingVoice: stopVoice()
        case .recordingCamera: stopCamera()
        default: break
        }
    }

    /// Esc / trash: throws away the whole draft.
    func discard() {
        discardVoice()
        camera?.shutdown()
        camera = nil
        mode = .idle
        files = []
        text = ""
        error = nil
    }

    func takeDraft() -> Draft {
        let draft = Draft(text: text, files: files,
                          voiceNote: mode == .reviewingVoice ? voice?.fileURL : nil,
                          voiceTranscript: mode == .reviewingVoice ? voice?.transcript : nil)
        AudioPlayback.shared.stop()
        voice = nil
        mode = .idle
        files = []
        text = ""
        error = nil
        return draft
    }
}
