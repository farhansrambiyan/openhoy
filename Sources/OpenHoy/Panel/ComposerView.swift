import SwiftUI

/// OpenHoy's composer: a glass "+" button beside a glass input field holding the text and a
/// round send button. Voice / video recording and attachments appear inside the field, above
/// the text. On macOS 26 the two pieces share one glass container, so they blend and morph.
struct ComposerView: View {
    @ObservedObject var composer: ComposerModel
    let person: Person
    var dropTargeted = false
    let onSend: () -> Void
    let onScreenRecord: () -> Void

    @FocusState private var textFocused: Bool
    @Namespace private var glass

    private static let fieldRadius: CGFloat = 20

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                leadingControl
                    .glassID("leading", in: glass)
                field
                    .glassID("field", in: glass)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: composer.mode)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: composer.files)
        .onAppear { textFocused = true }
        .onChange(of: composer.focusToken) { textFocused = true }
        .onChange(of: composer.mode) { _, mode in if mode == .idle { textFocused = true } }
    }

    @ViewBuilder private var leadingControl: some View {
        switch composer.mode {
        case .idle:
            AddMenu(onFiles: composer.pickFiles, onVoice: composer.startVoice,
                    onVideo: composer.startCamera, onScreen: onScreenRecord)
        case .recordingVoice, .recordingCamera, .reviewingVoice:
            RoundIconButton(symbol: "trash", help: "Discard (Esc)", size: 34, onGlass: true) { composer.discard() }
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            if composer.mode == .recordingCamera, let camera = composer.camera {
                CameraComposer(camera: camera)
            }
            if let voice = composer.voice, composer.mode == .recordingVoice || composer.mode == .reviewingVoice {
                VoiceTranscript(recorder: voice)
            }
            if !composer.files.isEmpty {
                AttachmentStrip(files: composer.files) { composer.removeFile($0) }
            }
            if let error = composer.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.95, green: 0.3, blue: 0.3))
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { composer.error = nil }
                    .padding(.horizontal, 6)
            }
            inputRow
        }
        .padding(.leading, 8)
        .padding([.vertical, .trailing], 2)
        .frame(minHeight: 34)
        .glassField(cornerRadius: Self.fieldRadius)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Self.fieldRadius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
    }

    @ViewBuilder private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // Middle
            Group {
                switch composer.mode {
                case .idle:
                    TextField("", text: $composer.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1...8)
                        .focused($textFocused)
                        // Our own placeholder: macOS ignores styling on the system prompt.
                        .background(alignment: .topLeading) {
                            if composer.text.isEmpty {
                                Text("Message \(person.firstName)…")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.primary.opacity(0.5))
                                    .lineLimit(1)
                                    .allowsHitTesting(false)
                            }
                        }
                case .recordingVoice:
                    if let voice = composer.voice { LiveVoiceRow(recorder: voice) }
                case .recordingCamera:
                    if let camera = composer.camera { CameraElapsed(camera: camera) }
                case .reviewingVoice:
                    if let voice = composer.voice { ReviewPlayback(url: voice.fileURL, duration: voice.elapsed) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 4)

            // Trailing control
            switch composer.mode {
            case .recordingVoice, .recordingCamera:
                StopButton { composer.stopRecording() }
            case .reviewingVoice:
                SendButton(enabled: true, action: onSend)
            case .idle:
                if composer.canSend {
                    SendButton(enabled: true, action: onSend)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    RoundIconButton(symbol: "mic", help: "Voice note") { composer.startVoice() }
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: composer.canSend)
    }
}

/// Re-render the camera timer as the recorder ticks.
private struct CameraElapsed: View {
    @ObservedObject var camera: CameraRecorder
    var body: some View { RecordingIndicator(elapsed: camera.elapsed, label: "Video") }
}

// MARK: - Pieces

/// "+" button: attach files, voice note, video note, screen recording.
struct AddMenu: View {
    let onFiles: () -> Void
    let onVoice: () -> Void
    let onVideo: () -> Void
    let onScreen: () -> Void

    var body: some View {
        Menu {
            Button { onFiles() } label: { Label("Attach Files…", systemImage: "paperclip") }
            Button { onVoice() } label: { Label("Voice Note", systemImage: "waveform") }
            Button { onVideo() } label: { Label("Video Note", systemImage: "video") }
            Divider()
            Button { onScreen() } label: { Label("Record Screen…", systemImage: "record.circle") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassControl(Circle())
        .help("Attach, voice note, video note or screen recording")
    }
}

/// Round icon button. `onGlass` makes it a standalone glass control; otherwise it sits
/// inside a glass field and only shows a soft highlight on hover.
struct RoundIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 30
    var onGlass = false
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.9 : 0.7))
                .frame(width: size, height: size)
                .background {
                    if !onGlass { Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        if onGlass {
            button.glassControl(Circle())
        } else {
            button
        }
    }
}

/// Round brand-gradient send button (⏎ also sends).
struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(enabled ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.15))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Send (⏎)")
    }
}

struct StopButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.white)
                .frame(width: 10, height: 10)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(red: 0.95, green: 0.27, blue: 0.27)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Stop (⏎)")
    }
}

struct RecordingIndicator: View {
    let elapsed: TimeInterval
    var label: String? = nil
    @ViewState private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(red: 0.95, green: 0.27, blue: 0.27))
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text(Theme.duration(elapsed)).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text)
            if let label { Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
        }
    }
}

/// Timer + live waveform while a voice note records.
private struct LiveVoiceRow: View {
    @ObservedObject var recorder: VoiceRecorder
    var body: some View {
        HStack(spacing: 10) {
            RecordingIndicator(elapsed: recorder.elapsed)
            WaveformBars(levels: recorder.levels.map { $0 < 0.06 ? 0 : $0 }, maxHeight: 18,
                         color: Theme.accent, dimColor: Theme.accent.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Live (then final) transcript of the voice note, above the input bar.
struct VoiceTranscript: View {
    @ObservedObject var recorder: VoiceRecorder

    var body: some View {
        if !recorder.transcript.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recorder.languageLabel.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
                Text(recorder.transcript)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: recorder.transcript)
        }
    }
}

struct ReviewPlayback: View {
    let url: URL
    let duration: TimeInterval
    @ObservedObject private var playback = AudioPlayback.shared

    var body: some View {
        let playing = playback.playingURL == url
        Button {
            playback.toggle(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 10, weight: .bold))
                Text("Voice note").font(.system(size: 13))
                Text(Theme.duration(playing ? duration * playback.progress : duration))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(Theme.text.opacity(0.8))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

struct CameraComposer: View {
    @ObservedObject var camera: CameraRecorder

    var body: some View {
        HStack {
            Spacer()
            ZStack {
                if camera.isRunning {
                    CameraPreview(session: camera.session)
                } else {
                    Color.black.opacity(0.4)
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 168, height: 168)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
            Spacer()
        }
    }
}

struct AttachmentStrip: View {
    let files: [URL]
    let onRemove: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(files, id: \.self) { url in
                    ZStack(alignment: .topTrailing) {
                        AttachmentThumb(url: url)
                        Button { onRemove(url) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

private struct AttachmentThumb: View {
    let url: URL
    var body: some View {
        let kind = AttachmentKind.classify(mimeType: nil, uti: nil, filename: url.lastPathComponent)
        ZStack(alignment: .bottomLeading) {
            if kind == .image || kind == .video {
                Thumbnail(url: url, size: CGSize(width: 160, height: 160))
            } else {
                ZStack {
                    Color.primary.opacity(0.06)
                    VStack(spacing: 4) {
                        Image(systemName: "doc.fill").font(.system(size: 20)).foregroundStyle(Theme.secondary)
                        Text(url.pathExtension.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            if kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
        .help(url.lastPathComponent)
    }
}
