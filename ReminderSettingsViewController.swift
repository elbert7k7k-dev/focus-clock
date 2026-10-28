import AppKit
import UniformTypeIdentifiers

/// Receives only an explicitly dragged, single local file. The library callback
/// validates decoding and owns the copy; this view does not traverse folders.
@MainActor
private final class ReminderAudioDropView: NSView {
    var onDrop: ((URL) -> Void)?
    var isEnabled = true
    var audioTitle: String? {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(audioTitle.map { "已载入提醒音乐：\($0)" } ?? "拖入一首本地音乐作为到点提醒")
        }
    }
    private var highlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("拖入一首本地音乐作为到点提醒")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func oneFile(_ board: NSPasteboard) -> URL? {
        guard let urls = board.readObjects(forClasses: [NSURL.self],
             options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == 1,
              urls[0].isFileURL else { return nil }
        return urls[0]
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = isEnabled && oneFile(sender.draggingPasteboard) != nil
        needsDisplay = true
        return highlighted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
        needsDisplay = true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        needsDisplay = true
        guard isEnabled, let url = oneFile(sender.draggingPasteboard) else { return false }
        onDrop?(url)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.08)
         : NSColor.white.withAlphaComponent(0.65)).setFill()
        path.fill()
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1.5
        let dash: [CGFloat] = [5, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.stroke()
        let title = audioTitle ?? "拖入一首本地提醒音乐"
        let detail = audioTitle == nil ? "或点击上方“选择音频”" : "已导入 · 到点完整播放一次，可随时停止"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        (title as NSString).draw(in: NSRect(x: 12, y: 52, width: self.bounds.width - 24, height: 25),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                             .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        (detail as NSString).draw(in: NSRect(x: 12, y: 26, width: self.bounds.width - 24, height: 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
    }
}

/// Edits a draft only. The application owns persistence and managed audio files.
@MainActor
final class ReminderSettingsViewController: NSViewController, NSTextFieldDelegate {
    var settings = ReminderSettings()
    var voiceOptions: [(id: String, name: String)] = []
    var onSave: ((ReminderSettings, Bool) -> Void)?
    var onStop: (() -> Void)?
    var onImportAudio: ((URL) throws -> (fileName: String, title: String))?
    /// Completion returns on the main queue; heavy copy/probe work belongs on a worker queue.
    var onImportAudioAsync: ((URL, @escaping (Result<(fileName: String, title: String), Error>) -> Void) -> Void)?

    private let modeControl = NSSegmentedControl(labels: ["闹钟", "自定义音乐", "语音", "静音"],
                                                  trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 0.85, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeLabel = NSTextField(labelWithString: "85%")
    private let repeatField = NSTextField(string: "1")
    private let repeatStepper = NSStepper()
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speechField = NSTextField(string: "")
    private let dropView = ReminderAudioDropView(frame: .zero)
    private var importButton: NSButton!
    private var saveButton: NSButton!
    private var previewButton: NSButton!
    private var isImporting = false
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var soundViews: [NSView] = []
    private var speechViews: [NSView] = []
    private var draftFileName: String?
    private var draftAudioTitle: String?
    private let ink = NSColor(srgbRed: 0.12, green: 0.20, blue: 0.31, alpha: 1)
    private let muted = NSColor(srgbRed: 0.43, green: 0.47, blue: 0.49, alpha: 1)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 430))
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(srgbRed: 0.985, green: 0.976, blue: 0.957, alpha: 1).cgColor

        addLabel("声音设置", x: 24, y: 385, width: 392, height: 27, size: 21, weight: .semibold, color: ink)
        addLabel("选择到点提醒，保存后生效。", x: 24, y: 362,
                 width: 392, height: 18, size: 12, color: muted)

        modeControl.frame = NSRect(x: 24, y: 320, width: 392, height: 28)
        modeControl.segmentStyle = .rounded
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel("到点提醒方式")
        view.addSubview(modeControl)

        addLabel("提醒音量", x: 24, y: 281, width: 80, height: 18)
        volumeSlider.frame = NSRect(x: 112, y: 274, width: 234, height: 28)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.isContinuous = true
        volumeSlider.setAccessibilityLabel("到点提醒音量，仅控制本应用")
        view.addSubview(volumeSlider)
        volumeLabel.frame = NSRect(x: 354, y: 281, width: 62, height: 18)
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        volumeLabel.alignment = .right
        volumeLabel.textColor = ink
        view.addSubview(volumeLabel)

        soundViews.append(addLabel("闹钟次数", x: 24, y: 232, width: 80, height: 18))
        repeatField.frame = NSRect(x: 112, y: 226, width: 64, height: 26)
        repeatField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        repeatField.alignment = .center
        repeatField.delegate = self
        repeatField.setAccessibilityLabel("闹钟次数，1到10的整数")
        view.addSubview(repeatField)
        repeatStepper.frame = NSRect(x: 184, y: 226, width: 19, height: 26)
        repeatStepper.minValue = 1
        repeatStepper.maxValue = 10
        repeatStepper.increment = 1
        repeatStepper.valueWraps = false
        repeatStepper.target = self
        repeatStepper.action = #selector(stepperChanged)
        repeatStepper.setAccessibilityLabel("调整闹钟次数")
        view.addSubview(repeatStepper)
        soundViews += [repeatField, repeatStepper]
        soundViews.append(addLabel("声（1—10）", x: 215, y: 232, width: 180, height: 18, color: muted))
        soundViews.append(addLabel("清晰叮铃声，按选定次数完整响完。", x: 24, y: 194,
                                    width: 392, height: 18, color: muted))

        speechViews.append(addLabel("本机人声", x: 24, y: 232, width: 80, height: 18))
        voicePopup.frame = NSRect(x: 110, y: 225, width: 304, height: 28)
        voicePopup.font = .systemFont(ofSize: 12)
        voicePopup.setAccessibilityLabel("本机已安装的人声")
        voicePopup.target = self
        voicePopup.action = #selector(draftChanged)
        view.addSubview(voicePopup)
        speechViews.append(voicePopup)
        speechViews.append(addLabel("语音内容", x: 24, y: 190, width: 80, height: 18))
        speechField.frame = NSRect(x: 112, y: 182, width: 300, height: 27)
        speechField.font = .systemFont(ofSize: 12)
        speechField.placeholderString = "输入到点时要说的话"
        speechField.delegate = self
        speechField.usesSingleLineMode = true
        speechField.lineBreakMode = .byClipping
        speechField.setAccessibilityLabel("自定义语音内容，1到120字")
        view.addSubview(speechField)
        speechViews.append(speechField)
        speechViews.append(addLabel("1—120字，仅使用本机已安装人声。", x: 112, y: 159,
                                    width: 304, height: 16, size: 10, color: muted))

        importButton = addButton("选择音频…", frame: NSRect(x: 302, y: 232, width: 116, height: 30),
                                 action: #selector(importClicked))
        dropView.frame = NSRect(x: 24, y: 128, width: 392, height: 102)
        dropView.onDrop = { [weak self] url in self?.importFile(url) }
        view.addSubview(dropView)

        hintLabel.frame = NSRect(x: 24, y: 88, width: 392, height: 33)
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = muted
        hintLabel.maximumNumberOfLines = 2
        view.addSubview(hintLabel)
        errorLabel.frame = NSRect(x: 24, y: 49, width: 392, height: 35)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        errorLabel.setAccessibilityLabel("提醒设置错误")
        view.addSubview(errorLabel)

        addButton("停止提醒", frame: NSRect(x: 22, y: 12, width: 96, height: 31), action: #selector(stopClicked))
        saveButton = addButton("保存", frame: NSRect(x: 232, y: 12, width: 74, height: 31), action: #selector(saveClicked))
        saveButton.keyEquivalent = "\r"
        previewButton = addButton("保存并试听", frame: NSRect(x: 310, y: 12, width: 108, height: 31), action: #selector(previewClicked))
        reloadSettings()
    }

    /// Loading values never starts playback or persists a draft.
    func reloadSettings() {
        guard isViewLoaded, !isImporting else { return }
        modeControl.selectedSegment = index(for: settings.mode)
        repeatField.stringValue = String(settings.repeatCount)
        repeatStepper.integerValue = min(10, max(1, settings.repeatCount))
        volumeSlider.doubleValue = settings.volume
        volumeLabel.stringValue = "\(Int((settings.volume * 100).rounded()))%"
        speechField.stringValue = settings.speechText
        draftFileName = settings.customAudioFileName
        draftAudioTitle = settings.customAudioTitle
        dropView.audioTitle = draftAudioTitle
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
                errorLabel.stringValue = "原人声当前不可用，已选自动选择；请确认后保存。"
            }
        }
        if voiceOptions.isEmpty && settings.mode == .speech {
            errorLabel.stringValue = "本机暂无可用系统人声，请选择其他提醒方式。"
        }
        updateEnabledFields()
    }

    @discardableResult
    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                          size: CGFloat = 12, weight: NSFont.Weight = .regular,
                          color: NSColor? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: x, y: y, width: width, height: height)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color ?? ink
        view.addSubview(label)
        return label
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
        case .custom: return 1
        case .speech: return 2
        case .silent: return 3
        }
    }
    private var selectedMode: ReminderMode {
        switch modeControl.selectedSegment {
        case 1: return .custom
        case 2: return .speech
        case 3: return .silent
        default: return .sound
        }
    }
    private func updateEnabledFields() {
        let mode = selectedMode
        soundViews.forEach { $0.isHidden = mode != .sound }
        speechViews.forEach { $0.isHidden = mode != .speech }
        dropView.isHidden = mode != .custom
        importButton.isHidden = mode != .custom
        modeControl.isEnabled = !isImporting
        volumeSlider.isEnabled = !isImporting && mode != .silent
        repeatField.isEnabled = !isImporting
        repeatStepper.isEnabled = !isImporting
        voicePopup.isEnabled = !isImporting
        speechField.isEnabled = !isImporting
        importButton.isEnabled = !isImporting
        saveButton.isEnabled = !isImporting
        previewButton.isEnabled = !isImporting
        dropView.isEnabled = !isImporting
        switch mode {
        case .sound: hintLabel.stringValue = "仅控制本应用音量；电脑静音或输出设备音量较低时仍会受影响。"
        case .custom: hintLabel.stringValue = "支持本地可播放音频，导入到本工具保存；不会改动原文件或自动下载音乐。"
        case .speech: hintLabel.stringValue = "保存的文字会原样播报；不会下载人声。"
        case .silent: hintLabel.stringValue = "到点仅结束本轮，不播放提醒。"
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === repeatField,
           let count = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), (1...10).contains(count) {
            repeatStepper.integerValue = count
        }
        errorLabel.stringValue = ""
    }
    @objc private func stepperChanged() {
        repeatField.stringValue = String(repeatStepper.integerValue)
        errorLabel.stringValue = ""
    }
    @objc private func modeChanged() { errorLabel.stringValue = ""; updateEnabledFields() }
    @objc private func draftChanged() { errorLabel.stringValue = "" }
    @objc private func volumeChanged() {
        volumeLabel.stringValue = "\(Int((volumeSlider.doubleValue * 100).rounded()))%"
        errorLabel.stringValue = ""
    }
    @objc private func saveClicked() { submit(preview: false) }
    @objc private func previewClicked() { submit(preview: true) }
    @objc private func stopClicked() { onStop?() }

    @objc private func importClicked() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "添加到点提醒音乐"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.importFile(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url { importFile(url) }
    }

    private func importFile(_ url: URL) {
        guard !isImporting else { return }
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            errorLabel.textColor = .systemRed
            errorLabel.stringValue = ReminderError.customAudioUnavailable.localizedDescription
            return
        }
        if let importer = onImportAudioAsync {
            isImporting = true
            updateEnabledFields()
            errorLabel.textColor = muted
            errorLabel.stringValue = "正在载入提醒音乐…"
            importer(url) { [weak self] result in
                DispatchQueue.main.async { self?.finishImport(result) }
            }
        } else if let importer = onImportAudio {
            finishImport(Result { try importer(url) })
        } else {
            finishImport(.failure(ReminderError.customAudioUnavailable))
        }
    }

    private func finishImport(_ result: Result<(fileName: String, title: String), Error>) {
        isImporting = false
        switch result {
        case .success(let imported):
            draftFileName = imported.fileName
            draftAudioTitle = imported.title
            dropView.audioTitle = imported.title
            modeControl.selectedSegment = index(for: .custom)
            errorLabel.stringValue = "已添加，点击保存后设为到点提醒。"
            errorLabel.textColor = muted
        case .failure(let error):
            // Failed imports keep the previous draft selection and file intact.
            errorLabel.textColor = .systemRed
            errorLabel.stringValue = error.localizedDescription
        }
        updateEnabledFields()
    }

    private func submit(preview: Bool) {
        guard !isImporting else { return }
        view.window?.makeFirstResponder(nil)
        // Unused repeat text does not block speech/custom/silent saving.
        let typedCount = Int(repeatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        if selectedMode == .sound && (typedCount == nil || !(1...10).contains(typedCount!)) {
            errorLabel.textColor = .systemRed
            errorLabel.stringValue = "闹钟次数请输入1—10的整数。"
            view.window?.makeFirstResponder(repeatField)
            return
        }
        let count = typedCount.flatMap { (1...10).contains($0) ? $0 : nil } ?? settings.repeatCount
        let candidate = ReminderSettings(mode: selectedMode, repeatCount: count,
            speechText: speechField.stringValue,
            voiceID: voicePopup.selectedItem?.representedObject as? String,
            volume: volumeSlider.doubleValue,
            customAudioFileName: draftFileName, customAudioTitle: draftAudioTitle)
        do {
            let valid = try candidate.validated()
            settings = valid
            errorLabel.stringValue = ""
            errorLabel.textColor = .systemRed
            onSave?(valid, preview)
        } catch {
            errorLabel.textColor = .systemRed
            errorLabel.stringValue = error.localizedDescription
        }
    }
}
