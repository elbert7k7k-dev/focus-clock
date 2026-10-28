import AppKit

/// Edits a draft only. The application owns persistence and audio playback.
@MainActor
final class ReminderSettingsViewController: NSViewController, NSTextFieldDelegate {
    var settings = ReminderSettings()
    var voiceOptions: [(id: String, name: String)] = []
    var onSave: ((ReminderSettings, Bool) -> Void)?
    var onStop: (() -> Void)?

    private let modeControl = NSSegmentedControl(labels: ["提示音", "语音", "静音"],
                                                  trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let repeatField = NSTextField(string: "1")
    private let repeatStepper = NSStepper()
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speechField = NSTextField(string: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let ink = NSColor(srgbRed: 0.12, green: 0.20, blue: 0.31, alpha: 1)
    private let muted = NSColor(srgbRed: 0.43, green: 0.47, blue: 0.49, alpha: 1)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 330))
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(srgbRed: 0.985, green: 0.976, blue: 0.957, alpha: 1).cgColor

        addLabel("到点提醒", x: 24, y: 285, width: 392, height: 27, size: 21, weight: .semibold, color: ink)
        addLabel("选择提醒方式，保存后用于下一次到点提醒。", x: 24, y: 263,
                 width: 392, height: 18, size: 12, color: muted)

        addLabel("提醒方式", x: 24, y: 231, width: 80, height: 18)
        modeControl.frame = NSRect(x: 112, y: 225, width: 300, height: 28)
        modeControl.segmentStyle = .rounded
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel("提醒方式")
        view.addSubview(modeControl)

        addLabel("提示音次数", x: 24, y: 189, width: 80, height: 18)
        repeatField.frame = NSRect(x: 112, y: 184, width: 64, height: 26)
        repeatField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        repeatField.alignment = .center
        repeatField.delegate = self
        repeatField.setAccessibilityLabel("提示音次数，1到10的整数")
        view.addSubview(repeatField)
        repeatStepper.frame = NSRect(x: 184, y: 184, width: 19, height: 26)
        repeatStepper.minValue = 1
        repeatStepper.maxValue = 10
        repeatStepper.increment = 1
        repeatStepper.valueWraps = false
        repeatStepper.target = self
        repeatStepper.action = #selector(stepperChanged)
        repeatStepper.setAccessibilityLabel("调整提示音次数")
        view.addSubview(repeatStepper)
        addLabel("次（1—10）", x: 215, y: 189, width: 180, height: 18, color: muted)

        addLabel("本机人声", x: 24, y: 151, width: 80, height: 18)
        voicePopup.frame = NSRect(x: 110, y: 145, width: 304, height: 28)
        voicePopup.font = .systemFont(ofSize: 12)
        voicePopup.setAccessibilityLabel("本机已安装的人声")
        voicePopup.target = self
        voicePopup.action = #selector(draftChanged)
        view.addSubview(voicePopup)

        addLabel("语音内容", x: 24, y: 112, width: 80, height: 18)
        speechField.frame = NSRect(x: 112, y: 106, width: 300, height: 27)
        speechField.font = .systemFont(ofSize: 12)
        speechField.placeholderString = "输入到点时要说的话"
        speechField.delegate = self
        speechField.usesSingleLineMode = true
        speechField.lineBreakMode = .byClipping
        speechField.setAccessibilityLabel("自定义语音内容，1到120字")
        view.addSubview(speechField)
        addLabel("语音可输入1—120字，仅使用本机已安装人声。", x: 112, y: 84,
                 width: 304, height: 16, size: 10, color: muted)

        errorLabel.frame = NSRect(x: 24, y: 51, width: 392, height: 28)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        errorLabel.setAccessibilityLabel("提醒设置错误")
        view.addSubview(errorLabel)

        addButton("停止提醒", frame: NSRect(x: 22, y: 13, width: 96, height: 31),
                  action: #selector(stopClicked))
        let save = addButton("保存", frame: NSRect(x: 232, y: 13, width: 74, height: 31),
                             action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        addButton("保存并试听", frame: NSRect(x: 310, y: 13, width: 108, height: 31),
                  action: #selector(previewClicked))
        reloadSettings()
    }

    /// Called after the application injects settings/installed voices, before
    /// each showing. It does not trigger callbacks, persistence or playback.
    func reloadSettings() {
        guard isViewLoaded else { return }
        modeControl.selectedSegment = index(for: settings.mode)
        repeatField.stringValue = String(settings.repeatCount)
        repeatStepper.integerValue = min(10, max(1, settings.repeatCount))
        speechField.stringValue = settings.speechText
        voicePopup.removeAllItems()
        voicePopup.addItem(withTitle: voiceOptions.isEmpty ? "本机暂无可用人声" : "自动选择（优先中文）")
        voicePopup.item(at: 0)?.representedObject = nil
        var seen = Set<String>()
        for option in voiceOptions where seen.insert(option.id).inserted {
            voicePopup.addItem(withTitle: option.name)
            voicePopup.lastItem?.representedObject = option.id
        }
        voicePopup.selectItem(at: 0)
        errorLabel.stringValue = ""
        if let savedID = settings.voiceID {
            if let item = voicePopup.itemArray.first(where: { ($0.representedObject as? String) == savedID }) {
                voicePopup.select(item)
            } else {
                // Make the fallback visible; do not download or invent a voice.
                errorLabel.stringValue = "原人声当前不可用，已选自动选择；请确认后保存。"
            }
        }
        if voiceOptions.isEmpty && settings.mode == .speech {
            errorLabel.stringValue = "本机暂无可用系统人声，请选提示音或静音；不会自动下载。"
        }
        updateEnabledFields()
    }

    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                          size: CGFloat = 12, weight: NSFont.Weight = .regular,
                          color: NSColor? = nil) {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: x, y: y, width: width, height: height)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color ?? ink
        view.addSubview(label)
    }

    @discardableResult
    private func addButton(_ title: String, frame: NSRect, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = frame
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        view.addSubview(button)
        return button
    }

    private func index(for mode: ReminderMode) -> Int {
        switch mode {
        case .sound: return 0
        case .speech: return 1
        case .silent: return 2
        }
    }

    private var selectedMode: ReminderMode {
        switch modeControl.selectedSegment {
        case 1: return .speech
        case 2: return .silent
        default: return .sound
        }
    }

    private func updateEnabledFields() {
        let isSpeech = selectedMode == .speech
        repeatField.isEnabled = selectedMode == .sound
        repeatStepper.isEnabled = selectedMode == .sound
        voicePopup.isEnabled = isSpeech
        speechField.isEnabled = isSpeech
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === repeatField,
           let count = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
           (1...10).contains(count) {
            repeatStepper.integerValue = count
        }
        errorLabel.stringValue = ""
    }

    @objc private func stepperChanged() {
        repeatField.stringValue = String(repeatStepper.integerValue)
        errorLabel.stringValue = ""
    }

    @objc private func modeChanged() {
        errorLabel.stringValue = ""
        updateEnabledFields()
    }

    @objc private func draftChanged() { errorLabel.stringValue = "" }
    @objc private func saveClicked() { submit(preview: false) }
    @objc private func previewClicked() { submit(preview: true) }
    @objc private func stopClicked() { onStop?() }

    private func submit(preview: Bool) {
        view.window?.makeFirstResponder(nil)
        guard let count = Int(repeatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...10).contains(count) else {
            errorLabel.stringValue = "提示音次数请输入1—10的整数。"
            view.window?.makeFirstResponder(repeatField)
            return
        }
        let candidate = ReminderSettings(mode: selectedMode, repeatCount: count,
                                         speechText: speechField.stringValue,
                                         voiceID: voicePopup.selectedItem?.representedObject as? String)
        do {
            let valid = try candidate.validated()
            settings = valid
            errorLabel.stringValue = ""
            onSave?(valid, preview)
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
    }
}
