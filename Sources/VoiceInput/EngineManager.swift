import Darwin
import Foundation

/// Python 引擎写出的完整状态快照。字段名与 Engine/voiceinput_engine/state.py 对齐。
struct EngineSnapshot: Codable, Equatable {
    var state: String
    var message: String
    var audioLevel: Float
    var lastText: String
    var modelVariant: String
    var language: String
    var pid: Int32
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case state, message, pid, language
        case audioLevel = "audio_level"
        case lastText = "last_text"
        case modelVariant = "model_variant"
        case updatedAt = "updated_at"
    }

    static func local(state: String, message: String) -> EngineSnapshot {
        EngineSnapshot(
            state: state,
            message: message,
            audioLevel: 0,
            lastText: "",
            modelVariant: SettingsStore.shared.load().modelVariant,
            language: SettingsStore.shared.load().language,
            pid: 0,
            updatedAt: nil
        )
    }
}

final class EngineManager {
    var onSnapshot: ((EngineSnapshot) -> Void)?
    private(set) var snapshot = EngineSnapshot.local(state: "stopped", message: "Stopped")

    private var process: Process?
    private var pollTimer: Timer?
    private var requestedStop = false
    private let decoder = JSONDecoder()

    var isRunning: Bool {
        let pid = currentPID()
        return pid > 0 && kill(pid, 0) == 0
    }

    func start() {
        requestedStop = false
        startPolling()
        if isRunning { return }

        do {
            try VoiceInputPaths.ensureDirectories()
            guard FileManager.default.isExecutableFile(atPath: VoiceInputPaths.python.path) else {
                publish(.local(
                    state: "runtime_missing",
                    message: "VoiceInput runtime is not installed. Run make install."
                ))
                return
            }
            guard let engineRoot = Bundle.main.resourceURL?.appendingPathComponent("Engine"),
                  FileManager.default.fileExists(
                    atPath: engineRoot.appendingPathComponent("voiceinput_engine/service.py").path
                  ) else {
                publish(.local(state: "error", message: "Bundled engine files are missing."))
                return
            }

            let task = Process()
            task.executableURL = VoiceInputPaths.python
            task.arguments = ["-m", "voiceinput_engine.service"]
            task.currentDirectoryURL = VoiceInputPaths.applicationSupport
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = engineRoot.path
            environment["PYTHONUNBUFFERED"] = "1"
            // 引擎源码位于已签名的应用包。禁止 Python 在其中生成 __pycache__，避免
            // 首次运行后改变签名资源，也让应用包始终只包含仓库中可审计的源码。
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            task.environment = environment
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { [weak self, weak task] _ in
                DispatchQueue.main.async {
                    guard let self, self.process === task else { return }
                    self.process = nil
                    if !self.requestedStop {
                        self.publish(.local(state: "error", message: "VoiceInput engine exited."))
                    }
                }
            }
            try task.run()
            process = task
            publish(.local(state: "starting", message: "Starting…"))
        } catch {
            publish(.local(state: "error", message: "Failed to start engine: \(error.localizedDescription)"))
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        requestedStop = true
        let pid = currentPID()
        if pid > 0 {
            _ = kill(pid, SIGTERM)
        } else if process?.isRunning == true {
            process?.terminate()
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let deadline = Date().addingTimeInterval(10)
            while pid > 0 && kill(pid, 0) == 0 && Date() < deadline {
                usleep(100_000)
            }
            // 正常路径会在一秒内响应 SIGTERM。唯一可能拖延的是 MLX 正在执行不可中断的
            // 原生加载；十秒后强制结束可确保退出应用时绝不遗留一个后台 Python 进程。
            if pid > 0 && kill(pid, 0) == 0 {
                _ = kill(pid, SIGKILL)
                let forcedDeadline = Date().addingTimeInterval(2)
                while kill(pid, 0) == 0 && Date() < forcedDeadline {
                    usleep(100_000)
                }
            }
            let processStillAlive = pid > 0 && kill(pid, 0) == 0
            DispatchQueue.main.async {
                self?.process = nil
                self?.publish(.local(
                    state: processStillAlive ? "error" : "stopped",
                    message: processStillAlive ? "Failed to stop VoiceInput engine." : "Stopped"
                ))
                completion?()
            }
        }
    }

    func restart() {
        stop { [weak self] in self?.start() }
    }

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollState()
        }
    }

    private func pollState() {
        guard let data = try? Data(contentsOf: VoiceInputPaths.engineState),
              let value = try? decoder.decode(EngineSnapshot.self, from: data),
              value.state == "stopped" || (value.pid > 0 && kill(value.pid, 0) == 0),
              value != snapshot else { return }
        publish(value)
    }

    private func publish(_ value: EngineSnapshot) {
        snapshot = value
        onSnapshot?(value)
    }

    private func currentPID() -> Int32 {
        if let running = process, running.isRunning {
            return running.processIdentifier
        }
        guard let text = try? String(contentsOf: VoiceInputPaths.enginePID, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return value
    }
}
