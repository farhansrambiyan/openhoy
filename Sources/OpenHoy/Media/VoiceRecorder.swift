import AVFoundation
import Speech

enum MediaPermission {
    static func microphone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func camera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    static func speech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

enum RecorderError: LocalizedError {
    case microphoneDenied, cameraDenied, noDevice

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access is off for OpenHoy (System Settings › Privacy & Security › Microphone)."
        case .cameraDenied: return "Camera access is off for OpenHoy (System Settings › Privacy & Security › Camera)."
        case .noDevice: return "No camera or microphone found."
        }
    }
}

/// Records a voice note to AAC while transcribing it live and publishing levels for the waveform.
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var levels: [Float] = []
    @Published private(set) var transcript = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isRecording = false

    static let barCount = 44

    let fileURL: URL
    let languageLabel: String

    private let engine = AVAudioEngine()
    /// Boxed so the audio tap doesn't keep the file open after we stop (closing finalizes the m4a).
    private final class FileBox: @unchecked Sendable { var file: AVAudioFile? }
    private let fileBox = FileBox()
    private var converter: AVAudioConverter?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer?
    private var startDate: Date?
    private var ticker: Timer?
    private var finalizedTranscript = ""

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OpenHoy/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("Voice Note.m4a")
        recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let code = recognizer?.locale.language.languageCode?.identifier ?? "en"
        languageLabel = code.prefix(1).uppercased() + code.dropFirst().lowercased()
        levels = Array(repeating: 0, count: Self.barCount)
    }

    func start() async throws {
        guard await MediaPermission.microphone() else { throw RecorderError.microphoneDenied }
        let speechAllowed = await MediaPermission.speech()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noDevice }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                       channels: 1, interleaved: false) else { throw RecorderError.noDevice }
        converter = AVAudioConverter(from: inputFormat, to: mono)

        fileBox.file = try AVAudioFile(forWriting: fileURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: mono.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        if speechAllowed, let recognizer, recognizer.isAvailable {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
                guard let text = result?.bestTranscription.formattedString else { return }
                Task { @MainActor in self?.transcript = text }
            }
        }

        let box = fileBox, converter = self.converter!, request = self.request
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * mono.sampleRate / inputFormat.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }
            try? box.file?.write(from: out)
            request?.append(out)
            let level = Self.level(of: out)
            Task { @MainActor in self?.push(level: level) }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        startDate = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate, self.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    /// Stops recording; returns once the file is closed. The transcript keeps
    /// updating briefly while the recognizer finalizes.
    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        ticker?.invalidate()
        ticker = nil
        fileBox.file = nil
        isRecording = false
        if let start = startDate { elapsed = Date().timeIntervalSince(start) }
    }

    func cancel() {
        stop()
        task?.cancel()
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func push(level: Float) {
        levels.append(level)
        if levels.count > Self.barCount { levels.removeFirst(levels.count - Self.barCount) }
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 40))
    }
}

/// Plays local audio files and reports progress; one shared instance so only one thing plays at a time.
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    @Published private(set) var playingURL: URL?
    @Published private(set) var progress: Double = 0
    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playingURL = url
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        ticker?.invalidate()
        ticker = nil
        playingURL = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// Duration + downsampled peaks for drawing voice-note waveforms in bubbles.
actor WaveformCache {
    static let shared = WaveformCache()
    private var cache: [URL: (TimeInterval, [Float])] = [:]

    func waveform(for url: URL, bars: Int = 36) -> (TimeInterval, [Float]) {
        if let hit = cache[url] { return hit }
        var result: (TimeInterval, [Float]) = (0, Array(repeating: 0.1, count: bars))
        if let file = try? AVAudioFile(forReading: url) {
            let format = file.processingFormat
            let total = AVAudioFrameCount(file.length)
            let duration = Double(file.length) / format.sampleRate
            if total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
               (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                let step = max(1, n / bars)
                var peaks: [Float] = []
                for b in 0..<bars {
                    let start = b * step
                    guard start < n else { peaks.append(0); continue }
                    var peak: Float = 0
                    for i in stride(from: start, to: min(n, start + step), by: 4) { peak = max(peak, abs(data[i])) }
                    peaks.append(peak)
                }
                let maxPeak = max(peaks.max() ?? 1, 0.01)
                result = (duration, peaks.map { min(1, $0 / maxPeak) })
            } else {
                result = (duration, result.1)
            }
        }
        cache[url] = result
        return result
    }
}
