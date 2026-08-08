import Foundation

/// Swift 前端与 Python 引擎共享的设置结构。
/// CodingKeys 必须和 Engine/voiceinput_engine/config.py 保持一致，否则保存后内核不会生效。
struct AppSettings: Codable, Equatable {
    var language = "auto"
    var modelVariant = "8bit"
    var autoPaste = true
    var removeFillers = true
    var llmEnabled = false
    var llmAPIBaseURL = "https://api.openai.com/v1"
    var llmModel = "gpt-4o-mini"
    var llmPrompt = """
        You are a conservative speech recognition error corrector.
        ONLY fix clear, obvious transcription mistakes. Do not rephrase, answer, translate,
        or add information. Return only the corrected text. If the input is already correct,
        return it exactly as-is.
        """
    var useHFMirror = false

    enum CodingKeys: String, CodingKey {
        case language
        case modelVariant = "model_variant"
        case autoPaste = "auto_paste"
        case removeFillers = "remove_fillers"
        case llmEnabled = "llm_enabled"
        case llmAPIBaseURL = "llm_api_base_url"
        case llmModel = "llm_model"
        case llmPrompt = "llm_prompt"
        case useHFMirror = "use_hf_mirror"
    }
}

enum VoiceInputPaths {
    static let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceInput", isDirectory: true)
    static let models = applicationSupport.appendingPathComponent("Models", isDirectory: true)
    static let runtime = applicationSupport.appendingPathComponent("Runtime", isDirectory: true)
    static let state = applicationSupport.appendingPathComponent("State", isDirectory: true)
    static let config = applicationSupport.appendingPathComponent("config.json")
    static let hotwords = applicationSupport.appendingPathComponent("hotwords.txt")
    static let engineState = state.appendingPathComponent("engine.json")
    static let enginePID = state.appendingPathComponent("engine.pid")
    static let python = runtime.appendingPathComponent("venv/bin/python")
    static let logs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VoiceInput", isDirectory: true)

    static func ensureDirectories() throws {
        for directory in [applicationSupport, models, runtime, state, logs] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    static func modelDirectory(for variant: String) -> URL {
        let name = variant == "4bit" ? "Qwen3-ASR-1.7B-4bit" : "Qwen3-ASR-1.7B-8bit"
        return models.appendingPathComponent(name, isDirectory: true)
    }

    static func modelIsInstalled(_ variant: String) -> Bool {
        let directory = modelDirectory(for: variant)
        let configExists = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("config.json").path
        )
        guard configExists,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else { return false }
        return files.contains { $0.pathExtension == "safetensors" }
    }
}

final class SettingsStore {
    static let shared = SettingsStore()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    private init() {}

    func load() -> AppSettings {
        do {
            try VoiceInputPaths.ensureDirectories()
            guard FileManager.default.fileExists(atPath: VoiceInputPaths.config.path) else {
                let defaults = AppSettings()
                try save(defaults)
                return defaults
            }
            let data = try Data(contentsOf: VoiceInputPaths.config)
            return try decoder.decode(AppSettings.self, from: data)
        } catch {
            // 配置损坏时使用内存默认值，不覆盖原文件，给用户保留手工修复的机会。
            NSLog("[VoiceInput] Failed to load settings: %@", error.localizedDescription)
            return AppSettings()
        }
    }

    func save(_ settings: AppSettings) throws {
        try VoiceInputPaths.ensureDirectories()
        let data = try encoder.encode(settings)
        try data.write(to: VoiceInputPaths.config, options: .atomic)
    }

    func loadHotwords() -> String {
        do {
            try VoiceInputPaths.ensureDirectories()
            if !FileManager.default.fileExists(atPath: VoiceInputPaths.hotwords.path) {
                let template = "# Format: final text | spoken alias 1 | spoken alias 2\n"
                try template.write(to: VoiceInputPaths.hotwords, atomically: true, encoding: .utf8)
            }
            return try String(contentsOf: VoiceInputPaths.hotwords, encoding: .utf8)
        } catch {
            return ""
        }
    }

    func saveHotwords(_ text: String) throws {
        try VoiceInputPaths.ensureDirectories()
        try text.write(to: VoiceInputPaths.hotwords, atomically: true, encoding: .utf8)
    }
}
