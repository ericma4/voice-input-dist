import AVFoundation
import Foundation

private final class PipeCollector {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.unlock()
        return value
    }
}

final class SenseVoiceSpeechEngine {
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var isTranscribing = false
    private var process: Process?
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VoiceInput-SenseVoice.log")

    var isAvailable: Bool {
        scriptURL != nil && pythonURL != nil
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
        audioFile = nil

        guard let url = tempFileURL, !isTranscribing else { return }
        guard let scriptURL else {
            onError?("SenseVoice script was not found in the app bundle.")
            return
        }
        guard let pythonURL else {
            onError?("Python was not found. Run Scripts/setup_sensevoice.sh from the project directory.")
            return
        }

        isTranscribing = true
        transcribe(audioURL: url, scriptURL: scriptURL, pythonURL: pythonURL)
    }

    func cancel() {
        cleanupAudio()
        process?.terminate()
        process = nil
        isTranscribing = false
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    // MARK: - Process

    private func transcribe(audioURL: URL, scriptURL: URL, pythonURL: URL) {
        let task = Process()
        task.executableURL = pythonURL
        task.arguments = [
            scriptURL.path,
            audioURL.path,
            "--language",
            "auto",
        ]
        appendLog("""

        --- SenseVoice run ---
        python: \(pythonURL.path)
        script: \(scriptURL.path)
        audio: \(audioURL.path)
        arguments: \(task.arguments?.joined(separator: " ") ?? "")
        """)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        process = task

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: audioURL)
            }

            do {
                try task.run()
            } catch {
                DispatchQueue.main.async {
                    self.finishWithError("SenseVoice failed to start: \(error.localizedDescription)")
                }
                return
            }

            let outputCollector = PipeCollector()
            let errorCollector = PipeCollector()
            let readers = DispatchGroup()

            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                outputCollector.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }

            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                errorCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }

            task.waitUntilExit()
            readers.wait()

            let output = outputCollector.stringValue
            let errorOutput = errorCollector.stringValue

            DispatchQueue.main.async {
                if task.terminationStatus == 0 {
                    self.appendLog("""
                    exit: 0
                    stdout:
                    \(output)
                    stderr:
                    \(errorOutput)
                    """)
                    self.finishWithText(output)
                } else {
                    let message = errorOutput.isEmpty ? "SenseVoice failed with exit code \(task.terminationStatus)" : errorOutput
                    self.appendLog("""
                    exit: \(task.terminationStatus)
                    stdout:
                    \(output)
                    stderr:
                    \(errorOutput)
                    """)
                    self.finishWithError(message)
                }
            }
        }
    }

    private func finishWithText(_ text: String) {
        isTranscribing = false
        process = nil
        tempFileURL = nil
        onFinalResult?(text)
    }

    private func finishWithError(_ message: String) {
        isTranscribing = false
        process = nil
        tempFileURL = nil
        onError?(message)
    }

    // MARK: - Locations

    private var scriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "sensevoice_transcribe", withExtension: "py") {
            return bundled
        }

        let cwdScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/sensevoice_transcribe.py")
        if FileManager.default.fileExists(atPath: cwdScript.path) {
            return cwdScript
        }

        return nil
    }

    private var pythonURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["SENSEVOICE_PYTHON"],
            "~/Library/Application Support/VoiceInput/sensevoice-venv/bin/python",
            repositoryRelativePythonPath,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let expanded = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }

        return nil
    }

    private var repositoryRelativePythonPath: String? {
        let repoURL = Bundle.main.bundleURL.deletingLastPathComponent()
        let path = repoURL.appendingPathComponent(".venv/bin/python").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private func cleanupAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioFile = nil
    }

    private func appendLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"
        let data = entry.data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: logURL.path, contents: data)
        }
    }
}
