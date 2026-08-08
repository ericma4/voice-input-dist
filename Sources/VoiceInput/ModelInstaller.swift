import Foundation

struct ModelInstallProgress {
    let event: String
    let progress: Double
    let downloadedBytes: Int64
    let totalBytes: Int64
    let message: String?
}

/// 应用内模型安装器。Python 下载器负责 Hugging Face 细节，Swift 只消费 JSON 进度行。
final class ModelInstaller {
    var onProgress: ((ModelInstallProgress) -> Void)?
    var onCompletion: ((Result<Void, Error>) -> Void)?
    private var process: Process?
    private var lineBuffer = Data()

    var isRunning: Bool { process?.isRunning == true }

    func start(variant: String, useMirror: Bool) {
        guard !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: VoiceInputPaths.python.path),
              let engineRoot = Bundle.main.resourceURL?.appendingPathComponent("Engine") else {
            onCompletion?(.failure(InstallerError.runtimeMissing))
            return
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = VoiceInputPaths.python
        task.arguments = ["-m", "voiceinput_engine.model_download", variant]
            + (useMirror ? ["--mirror"] : [])
        task.currentDirectoryURL = VoiceInputPaths.applicationSupport
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = engineRoot.path
        environment["PYTHONUNBUFFERED"] = "1"
        task.environment = environment
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        task.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.process = nil
                if finished.terminationStatus == 0 {
                    self?.onCompletion?(.success(()))
                } else {
                    self?.onCompletion?(.failure(InstallerError.downloadFailed))
                }
            }
        }
        do {
            try task.run()
            process = task
        } catch {
            onCompletion?(.failure(error))
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.prefix(upTo: newline)
            lineBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            onProgress?(ModelInstallProgress(
                event: object["event"] as? String ?? "progress",
                progress: (object["progress"] as? NSNumber)?.doubleValue ?? 0,
                downloadedBytes: (object["downloaded_bytes"] as? NSNumber)?.int64Value ?? 0,
                totalBytes: (object["total_bytes"] as? NSNumber)?.int64Value ?? 0,
                message: object["message"] as? String
            ))
        }
    }

    enum InstallerError: LocalizedError {
        case runtimeMissing
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .runtimeMissing: return "VoiceInput runtime is not installed."
            case .downloadFailed: return "Model download failed."
            }
        }
    }
}
