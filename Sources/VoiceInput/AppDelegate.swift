import AppKit
import ApplicationServices
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engineManager = EngineManager()
    private lazy var overlayPanel = OverlayPanel()
    private lazy var settingsWindow: SettingsWindow = {
        let window = SettingsWindow()
        window.onSaved = { [weak self] modelChanged in
            self?.refreshMenuState()
            if modelChanged {
                self?.engineManager.restart()
            }
        }
        return window
    }()

    private var statusHeaderItem: NSMenuItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var restartItem: NSMenuItem!
    private var copyItem: NSMenuItem!
    private var privacyItem: NSMenuItem!
    private var languageItems: [NSMenuItem] = []

    private var previousState = "stopped"
    private var overlayDismissWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        KeychainStore.migrateLegacyValueIfNeeded()
        setupStatusBar()
        setupAppMenu()
        engineManager.onSnapshot = { [weak self] snapshot in
            self?.handle(snapshot)
        }
        engineManager.startPolling()
        requestPermissions()
        engineManager.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // VoiceInput 是唯一可见生命周期所有者；退出前等待 Python 恢复 Caps Lock 映射。
        guard engineManager.isRunning else { return .terminateNow }
        engineManager.stop {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - 状态与胶囊

    private func handle(_ snapshot: EngineSnapshot) {
        refreshMenuState()
        updateStatusIcon(recording: snapshot.state == "recording")

        switch snapshot.state {
        case "starting", "loading_model":
            if previousState != snapshot.state {
                showOverlay(snapshot.message)
            }
        case "recording":
            if previousState != "recording" {
                showOverlay("Listening…")
                NSSound(named: .init("Tink"))?.play()
            }
            overlayPanel.updateAudioLevel(snapshot.audioLevel)
        case "transcribing":
            showOrUpdateOverlay("Transcribing…")
        case "refining":
            overlayPanel.showRefining()
        case "ready":
            if ["recording", "transcribing", "refining"].contains(previousState) {
                // 转写结果已经由引擎直接粘贴；胶囊只负责显示过程状态，完成后立即收起。
                NSSound(named: .init("Pop"))?.play()
                overlayPanel.dismiss()
            } else if ["starting", "loading_model"].contains(previousState) {
                overlayPanel.dismiss()
            }
        case "model_missing", "runtime_missing", "permission_required", "error":
            if previousState != snapshot.state {
                showOverlay(snapshot.message)
                dismissOverlay(after: 3.0)
            }
        case "stopped":
            overlayPanel.dismiss()
        default:
            break
        }
        previousState = snapshot.state
    }

    private func showOverlay(_ text: String) {
        overlayDismissWorkItem?.cancel()
        overlayPanel.show(text: text)
    }

    private func showOrUpdateOverlay(_ text: String) {
        overlayDismissWorkItem?.cancel()
        if overlayPanel.isVisible {
            overlayPanel.updateText(text)
        } else {
            overlayPanel.show(text: text)
        }
    }

    private func dismissOverlay(after delay: TimeInterval) {
        overlayDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.overlayPanel.dismiss() }
        overlayDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 菜单栏

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(recording: false)
        let menu = NSMenu()
        menu.autoenablesItems = false

        statusHeaderItem = NSMenuItem(title: "VoiceInput · Starting…", action: nil, keyEquivalent: "")
        statusHeaderItem.isEnabled = false
        menu.addItem(statusHeaderItem)
        menu.addItem(.separator())

        startItem = menuItem("Start Engine", action: #selector(startEngine), symbol: "play.fill")
        stopItem = menuItem("Stop Engine", action: #selector(stopEngine), symbol: "stop.fill")
        restartItem = menuItem("Restart Engine", action: #selector(restartEngine), symbol: "arrow.clockwise")
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(restartItem)
        menu.addItem(.separator())

        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let languages: [(String, String)] = [
            ("Automatic", "auto"),
            ("Chinese", "chinese"),
            ("English", "english"),
            ("Spanish", "spanish"),
            ("Italian", "italian"),
            ("French", "french"),
        ]
        for (title, value) in languages {
            let item = NSMenuItem(title: title, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            languageItems.append(item)
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        copyItem = menuItem("Copy Last Result", action: #selector(copyLastResult), symbol: "doc.on.clipboard")
        menu.addItem(copyItem)
        menu.addItem(menuItem("Settings…", action: #selector(openSettings), symbol: "gearshape"))
        privacyItem = menuItem(
            "Open Privacy Settings…",
            action: #selector(openPrivacySettings),
            symbol: "hand.raised"
        )
        menu.addItem(privacyItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit VoiceInput", action: #selector(quit), symbol: "power", keyEquivalent: "q"))
        statusItem.menu = menu
        refreshMenuState()
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        symbol: String,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func refreshMenuState() {
        guard statusHeaderItem != nil else { return }
        let snapshot = engineManager.snapshot
        statusHeaderItem.title = statusTitle(for: snapshot)
        let running = engineManager.isRunning
        startItem.isEnabled = !running
        stopItem.isEnabled = running
        restartItem.isEnabled = running
        copyItem.isEnabled = !snapshot.lastText.isEmpty
        privacyItem.isHidden = snapshot.state != "permission_required"
        let language = SettingsStore.shared.load().language
        for item in languageItems {
            item.state = (item.representedObject as? String) == language ? .on : .off
        }
    }

    private func statusTitle(for snapshot: EngineSnapshot) -> String {
        switch snapshot.state {
        case "ready": return "● VoiceInput · Ready"
        case "recording": return "● VoiceInput · Listening…"
        case "transcribing": return "● VoiceInput · Transcribing…"
        case "refining": return "● VoiceInput · Refining…"
        case "starting", "loading_model": return "VoiceInput · \(snapshot.message)"
        case "model_missing": return "VoiceInput · Model not installed"
        case "permission_required": return "VoiceInput · Permission required"
        case "runtime_missing": return "VoiceInput · Runtime not installed"
        case "error": return "VoiceInput · Error"
        default: return "VoiceInput · Stopped"
        }
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: recording ? "mic.fill" : "mic",
            accessibilityDescription: "VoiceInput"
        )
        button.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - 菜单动作

    @objc private func startEngine() {
        requestPermissions()
        engineManager.start()
    }

    @objc private func stopEngine() {
        engineManager.stop()
    }

    @objc private func restartEngine() {
        requestPermissions()
        engineManager.restart()
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        var settings = SettingsStore.shared.load()
        settings.language = value
        do {
            try SettingsStore.shared.save(settings)
            refreshMenuState()
        } catch {
            showAlert(title: "Could Not Save Language", message: error.localizedDescription)
        }
    }

    @objc private func copyLastResult() {
        let text = engineManager.snapshot.lastText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.show()
    }

    @objc private func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 权限

    private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !AXIsProcessTrusted() {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
            ] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        // 输入监控没有可靠的主动授权 API；Python 引擎首次创建 CGEventTap 时会让系统登记条目。
    }

    private func setupAppMenu() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit VoiceInput", action: #selector(quit), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
