import AVFoundation
import WhisperKit

final class WhisperSpeechEngine {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var isTranscribing = false

    // Shared model instance — loaded once and reused across recordings
    private static var sharedKit: WhisperKit?
    private static var isLoading = false
    private static var pendingCallbacks: [(Bool) -> Void] = []

    static let modelName = "medium"

    // MARK: - Model Management

    var isModelLoaded: Bool { Self.sharedKit != nil }

    func loadModel(progress: ((String) -> Void)? = nil, completion: @escaping (Bool) -> Void) {
        if let _ = Self.sharedKit {
            completion(true)
            return
        }
        Self.pendingCallbacks.append(completion)
        guard !Self.isLoading else { return }
        Self.isLoading = true

        progress?("Downloading Whisper model (~1.5 GB)…")

        Task {
            do {
                let kit = try await WhisperKit(model: Self.modelName)
                await MainActor.run {
                    Self.sharedKit = kit
                    Self.isLoading = false
                    Self.pendingCallbacks.forEach { $0(true) }
                    Self.pendingCallbacks = []
                }
            } catch {
                await MainActor.run {
                    Self.isLoading = false
                    Self.pendingCallbacks.forEach { $0(false) }
                    Self.pendingCallbacks = []
                    self.onError?("Whisper load failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        tempFileURL = url

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            onError?("Cannot create audio file: \(error.localizedDescription)")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.audioFile?.write(from: buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength { sum += channelData[i] * channelData[i] }
            let rms = sqrtf(sum / Float(max(frameLength, 1)))
            let dB = 20 * log10(max(rms, 1e-6))
            let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
            DispatchQueue.main.async { self.onAudioLevel?(normalized) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("Audio engine failed: \(error.localizedDescription)")
            cleanupAudio()
        }
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioFile = nil  // Closes and flushes the file

        guard let url = tempFileURL, !isTranscribing else { return }
        guard let kit = Self.sharedKit else {
            onError?("Whisper model not loaded")
            return
        }
        isTranscribing = true

        Task {
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let results = try await kit.transcribe(audioPath: url.path)
                let text = results.map { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.isTranscribing = false
                    self.tempFileURL = nil
                    self.onFinalResult?(text)
                }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    self.tempFileURL = nil
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        cleanupAudio()
        isTranscribing = false
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    private func cleanupAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioFile = nil
    }
}
