import AppKit

/// VoiceInput 的统一设置窗口。复杂配置留在四个分页，菜单栏只保留高频动作。
final class SettingsWindow: NSWindow, NSWindowDelegate {
    var onSaved: ((Bool) -> Void)?

    private var settings = AppSettings()
    private let installer = ModelInstaller()

    private let languagePopup = NSPopUpButton()
    private let autoPasteButton = NSButton(checkboxWithTitle: "Paste automatically", target: nil, action: nil)
    private let fillerButton = NSButton(
        checkboxWithTitle: "Remove Chinese and English filler words",
        target: nil,
        action: nil
    )

    private let modelPopup = NSPopUpButton()
    private let mirrorButton = NSButton(
        checkboxWithTitle: "Use mainland China mirror",
        target: nil,
        action: nil
    )
    private let modelStatusLabel = NSTextField(labelWithString: "")
    private let modelProgress = NSProgressIndicator()
    private lazy var installButton = NSButton(
        title: "Install Model",
        target: self,
        action: #selector(installModel)
    )
    private lazy var cancelInstallButton = NSButton(
        title: "Cancel",
        target: self,
        action: #selector(cancelModelInstall)
    )
    private lazy var removeModelButton = NSButton(
        title: "Remove Model…",
        target: self,
        action: #selector(removeModel)
    )

    private let hotwordTextView = NSTextView()

    private let llmEnabledButton = NSButton(
        checkboxWithTitle: "Enable LLM refinement",
        target: nil,
        action: nil
    )
    private let apiBaseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let llmModelField = NSTextField()
    private let llmPromptTextView = NSTextView()
    private let llmStatusLabel = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "VoiceInput Settings"
        isReleasedWhenClosed = false
        delegate = self
        setupUI()
        connectInstaller()
        center()
    }

    func show() {
        loadValues()
        makeKeyAndOrderFront(nil)
    }

    private func setupUI() {
        guard let contentView else { return }
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeGeneralTab())
        tabView.addTabViewItem(makeModelTab())
        tabView.addTabViewItem(makeHotwordsTab())
        tabView.addTabViewItem(makeLLMTab())

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(tabView)
        contentView.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tabView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func makeGeneralTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "general")
        item.label = "General"
        let view = paddedView()

        let languages: [(String, String)] = [
            ("Automatic", "auto"),
            ("Chinese", "chinese"),
            ("English", "english"),
            ("Spanish", "spanish"),
            ("Italian", "italian"),
            ("French", "french"),
        ]
        for (title, value) in languages {
            languagePopup.addItem(withTitle: title)
            languagePopup.lastItem?.representedObject = value
        }
        let languageRow = formRow(label: "Recognition language:", control: languagePopup)
        let note = secondaryLabel(
            "Automatic is recommended for mixed Chinese and English speech. " +
            "Hold Caps Lock to record; a short tap still toggles capitalization."
        )
        let stack = verticalStack([languageRow, autoPasteButton, fillerButton, note])
        attach(stack, to: view)
        item.view = view
        return item
    }

    private func makeModelTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "model")
        item.label = "Model"
        let view = paddedView()

        modelPopup.addItem(withTitle: "Qwen3-ASR 1.7B 8-bit (recommended)")
        modelPopup.lastItem?.representedObject = "8bit"
        modelPopup.addItem(withTitle: "Qwen3-ASR 1.7B 4-bit")
        modelPopup.lastItem?.representedObject = "4bit"
        modelPopup.target = self
        modelPopup.action = #selector(modelSelectionChanged)

        modelProgress.minValue = 0
        modelProgress.maxValue = 1
        modelProgress.isIndeterminate = false
        modelProgress.controlSize = .small
        modelProgress.isHidden = true
        modelStatusLabel.textColor = .secondaryLabelColor
        modelStatusLabel.lineBreakMode = .byWordWrapping
        modelStatusLabel.maximumNumberOfLines = 2

        let modelRow = formRow(label: "Active model:", control: modelPopup)
        let buttonRow = NSStackView(views: [installButton, cancelInstallButton, removeModelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        cancelInstallButton.isHidden = true
        let location = secondaryLabel("Models are stored in ~/Library/Application Support/VoiceInput/Models.")
        let stack = verticalStack([
            modelRow,
            mirrorButton,
            modelStatusLabel,
            modelProgress,
            buttonRow,
            location,
        ])
        attach(stack, to: view)
        item.view = view
        return item
    }

    private func makeHotwordsTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "hotwords")
        item.label = "Hotwords"
        let view = paddedView()
        let note = secondaryLabel(
            "One entry per line: final text | spoken alias 1 | spoken alias 2. " +
            "Changes take effect without restarting VoiceInput."
        )
        hotwordTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        hotwordTextView.isRichText = false
        hotwordTextView.isAutomaticQuoteSubstitutionEnabled = false
        let scroll = scrollView(containing: hotwordTextView)
        let stack = verticalStack([note, scroll])
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        attach(stack, to: view)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 310).isActive = true
        item.view = view
        return item
    }

    private func makeLLMTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "llm")
        item.label = "LLM"
        let view = paddedView()
        apiBaseURLField.placeholderString = "https://api.openai.com/v1"
        apiKeyField.placeholderString = "Stored securely in macOS Keychain"
        llmModelField.placeholderString = "gpt-4o-mini"
        llmPromptTextView.font = .systemFont(ofSize: 12)
        llmPromptTextView.isRichText = false
        let promptScroll = scrollView(containing: llmPromptTextView)
        promptScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let clearButton = NSButton(title: "Clear Key", target: self, action: #selector(clearAPIKey))
        let testButton = NSButton(title: "Test Connection", target: self, action: #selector(testLLM))
        let actionRow = NSStackView(views: [clearButton, testButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        llmStatusLabel.textColor = .secondaryLabelColor
        llmStatusLabel.lineBreakMode = .byTruncatingTail

        let stack = verticalStack([
            llmEnabledButton,
            formRow(label: "API base URL:", control: apiBaseURLField),
            formRow(label: "API key:", control: apiKeyField),
            formRow(label: "Model:", control: llmModelField),
            NSTextField(labelWithString: "Correction prompt:"),
            promptScroll,
            actionRow,
            llmStatusLabel,
        ])
        attach(stack, to: view)
        item.view = view
        return item
    }

    private func loadValues() {
        settings = SettingsStore.shared.load()
        select(popup: languagePopup, representedValue: settings.language)
        select(popup: modelPopup, representedValue: settings.modelVariant)
        autoPasteButton.state = settings.autoPaste ? .on : .off
        fillerButton.state = settings.removeFillers ? .on : .off
        mirrorButton.state = settings.useHFMirror ? .on : .off
        hotwordTextView.string = SettingsStore.shared.loadHotwords()
        llmEnabledButton.state = settings.llmEnabled ? .on : .off
        apiBaseURLField.stringValue = settings.llmAPIBaseURL
        apiKeyField.stringValue = ""
        apiKeyField.placeholderString = KeychainStore.readAPIKey() == nil
            ? "sk-…"
            : "•••••••• (saved in Keychain)"
        llmModelField.stringValue = settings.llmModel
        llmPromptTextView.string = settings.llmPrompt
        llmStatusLabel.stringValue = ""
        updateModelStatus()
    }

    private func collectValues() -> AppSettings {
        var value = settings
        value.language = languagePopup.selectedItem?.representedObject as? String ?? "auto"
        value.modelVariant = selectedModelVariant
        value.autoPaste = autoPasteButton.state == .on
        value.removeFillers = fillerButton.state == .on
        value.llmEnabled = llmEnabledButton.state == .on
        value.llmAPIBaseURL = apiBaseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.llmModel = llmModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.llmPrompt = llmPromptTextView.string
        value.useHFMirror = mirrorButton.state == .on
        return value
    }

    private func persistFields() throws -> Bool {
        let newValue = collectValues()
        let modelChanged = newValue.modelVariant != settings.modelVariant
        try SettingsStore.shared.save(newValue)
        try SettingsStore.shared.saveHotwords(hotwordTextView.string)
        let enteredKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enteredKey.isEmpty {
            try KeychainStore.saveAPIKey(enteredKey)
            apiKeyField.stringValue = ""
            apiKeyField.placeholderString = "•••••••• (saved in Keychain)"
        }
        settings = newValue
        return modelChanged
    }

    @objc private func save() {
        do {
            let modelChanged = try persistFields()
            close()
            onSaved?(modelChanged)
        } catch {
            showAlert(title: "Could Not Save Settings", message: error.localizedDescription)
        }
    }

    @objc private func cancel() {
        close()
    }

    @objc private func modelSelectionChanged() {
        updateModelStatus()
    }

    @objc private func installModel() {
        guard !installer.isRunning else { return }
        do {
            // “安装所选模型”同时把它设为活动模型，下载完成后的自动重启才会加载正确规格。
            var value = collectValues()
            value.modelVariant = selectedModelVariant
            try SettingsStore.shared.save(value)
            settings = value
        } catch {
            showAlert(title: "Could Not Save Model Selection", message: error.localizedDescription)
            return
        }
        modelProgress.doubleValue = 0
        modelProgress.isHidden = false
        installButton.isEnabled = false
        cancelInstallButton.isHidden = false
        modelStatusLabel.stringValue = "Preparing download…"
        installer.start(
            variant: selectedModelVariant,
            useMirror: mirrorButton.state == .on
        )
    }

    @objc private func cancelModelInstall() {
        installer.cancel()
    }

    @objc private func removeModel() {
        let variant = selectedModelVariant
        let directory = VoiceInputPaths.modelDirectory(for: variant)
        guard VoiceInputPaths.modelIsInstalled(variant) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the \(variant) model?"
        alert.informativeText = "The model will be moved to Trash and can be downloaded again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
            updateModelStatus()
            onSaved?(true)
        } catch {
            showAlert(title: "Could Not Remove Model", message: error.localizedDescription)
        }
    }

    @objc private func clearAPIKey() {
        do {
            try KeychainStore.deleteAPIKey()
            apiKeyField.stringValue = ""
            apiKeyField.placeholderString = "sk-…"
            showLLMStatus("API key removed from Keychain.", success: true)
        } catch {
            showLLMStatus(error.localizedDescription, success: false)
        }
    }

    @objc private func testLLM() {
        do {
            _ = try persistFields()
        } catch {
            showLLMStatus(error.localizedDescription, success: false)
            return
        }
        showLLMStatus("Testing…", success: nil)
        LLMRefiner.shared.refine("Hello, this is a test.", settings: settings) { [weak self] result in
            switch result {
            case .success:
                self?.showLLMStatus("Connection succeeded.", success: true)
            case .failure(let error):
                self?.showLLMStatus(error.localizedDescription, success: false)
            }
        }
    }

    private func connectInstaller() {
        installer.onProgress = { [weak self] progress in
            guard let self else { return }
            self.modelProgress.doubleValue = progress.progress
            if progress.totalBytes > 0 {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let downloaded = formatter.string(fromByteCount: progress.downloadedBytes)
                let total = formatter.string(fromByteCount: progress.totalBytes)
                self.modelStatusLabel.stringValue = "Downloading \(downloaded) of \(total)…"
            } else if let message = progress.message {
                self.modelStatusLabel.stringValue = message
            }
        }
        installer.onCompletion = { [weak self] result in
            guard let self else { return }
            self.installButton.isEnabled = true
            self.cancelInstallButton.isHidden = true
            self.modelProgress.isHidden = true
            switch result {
            case .success:
                self.updateModelStatus()
                self.onSaved?(true)
            case .failure(let error):
                self.modelStatusLabel.stringValue = error.localizedDescription
                self.modelStatusLabel.textColor = .systemRed
            }
        }
    }

    private var selectedModelVariant: String {
        modelPopup.selectedItem?.representedObject as? String ?? "8bit"
    }

    private func updateModelStatus() {
        let installed = VoiceInputPaths.modelIsInstalled(selectedModelVariant)
        modelStatusLabel.stringValue = installed ? "Installed and ready." : "Not installed."
        modelStatusLabel.textColor = installed ? .systemGreen : .secondaryLabelColor
        installButton.title = installed ? "Model Installed" : "Install Model"
        installButton.isEnabled = !installed && !installer.isRunning
        removeModelButton.isEnabled = installed
    }

    private func showLLMStatus(_ text: String, success: Bool?) {
        llmStatusLabel.stringValue = text
        switch success {
        case true?: llmStatusLabel.textColor = .systemGreen
        case false?: llmStatusLabel.textColor = .systemRed
        case nil: llmStatusLabel.textColor = .secondaryLabelColor
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - 小型布局辅助

    private func paddedView() -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 590, height: 420))
    }

    private func verticalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func attach(_ stack: NSStackView, to view: NSView) {
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
    }

    private func formRow(label: String, control: NSView) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 130).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        return row
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 3
        return label
    }

    private func scrollView(containing textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 540).isActive = true
        return scroll
    }

    private func select(popup: NSPopUpButton, representedValue: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == representedValue }) {
            popup.select(item)
        }
    }
}
