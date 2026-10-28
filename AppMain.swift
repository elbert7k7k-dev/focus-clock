import AppKit

private enum Palette {
    static let background = NSColor(srgbRed: 0.985, green: 0.976, blue: 0.957, alpha: 1)
    static let ink = NSColor(srgbRed: 0.12, green: 0.20, blue: 0.31, alpha: 1)
    static let teal = NSColor(srgbRed: 0.08, green: 0.51, blue: 0.46, alpha: 1)
    static let muted = NSColor(srgbRed: 0.43, green: 0.47, blue: 0.49, alpha: 1)
    static let track = NSColor(srgbRed: 0.88, green: 0.91, blue: 0.88, alpha: 1)
}

private enum MonotonicTime {
    static let origin = ContinuousClock.now
    static func seconds() -> Double {
        let parts = origin.duration(to: ContinuousClock.now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

@MainActor
private final class RingView: NSView {
    var progress: Double = 1 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: bounds.width / 208, y: bounds.height / 208)
        // All decoration stays within the clock canvas; no image assets needed.
        let rect = NSRect(x: 20, y: 26, width: 168, height: 168)
        let feet = NSBezierPath()
        feet.move(to: NSPoint(x: 58, y: 37))
        feet.line(to: NSPoint(x: 45, y: 17))
        feet.move(to: NSPoint(x: 150, y: 37))
        feet.line(to: NSPoint(x: 163, y: 17))
        feet.lineWidth = 6
        feet.lineCapStyle = .round
        Palette.teal.setStroke()
        feet.stroke()
        let hands = NSBezierPath()
        hands.move(to: NSPoint(x: 104, y: 148))
        hands.line(to: NSPoint(x: 104, y: 110))
        hands.line(to: NSPoint(x: 132, y: 95))
        hands.lineWidth = 6
        hands.lineCapStyle = .round
        hands.lineJoinStyle = .round
        Palette.ink.setStroke()
        hands.stroke()
        for (x, angle) in [(CGFloat(52), CGFloat(25)), (CGFloat(156), CGFloat(-25))] {
            let bell = NSBezierPath(ovalIn: NSRect(x: -26, y: -10, width: 52, height: 20))
            var transform = AffineTransform()
            transform.translate(x: x, y: 193)
            transform.rotate(byDegrees: angle)
            bell.transform(using: transform)
            Palette.teal.setFill()
            bell.fill()
        }
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 7
        Palette.track.setStroke()
        track.stroke()
        let fraction = min(1, max(0, progress))
        guard fraction > 0 else { return }
        let path: NSBezierPath
        if fraction >= 0.999999 {
            path = NSBezierPath(ovalIn: rect)
        } else {
            path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                           radius: rect.width / 2,
                           startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        }
        path.lineWidth = 7
        path.lineCapStyle = .round
        Palette.teal.setStroke()
        path.stroke()
    }
}

private func focusDurationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    let h = value / 3600, m = (value % 3600) / 60, sec = value % 60
    if h > 0 { return "\(h)小时\(m)分\(sec)秒" }
    if m > 0 { return "\(m)分\(sec)秒" }
    return "\(sec)秒"
}

@MainActor
private final class TimerViewController: NSViewController {
    enum Event {
        case primary, reset, stop, mode(FocusMode), configure(Double), history
        case reminderSettings, previewSound, closePanel, quit
    }
    var onEvent: ((Event) -> Void)?
    private let ring = RingView(frame: NSRect(x: 24, y: 181, width: 124, height: 124))
    private let timeLabel = NSTextField(labelWithString: "25:00")
    private let phaseLabel = NSTextField(labelWithString: "准备好，再开始")
    private let primary = NSButton(title: "开始", target: nil, action: nil)
    private let history = NSButton(title: "今日专注 0秒 · 查看记录", target: nil, action: nil)
    private let minutes = NSTextField(string: "25")
    private var modes: NSSegmentedControl!
    private let sound = NSButton(title: "到点提醒：提示音 ×1", target: nil, action: nil)
    private let end = NSButton(title: "结束", target: nil, action: nil)

    private func label(_ text: String, _ frame: NSRect, _ size: CGFloat,
                       _ color: NSColor = Palette.muted, _ weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func button(_ title: String, _ frame: NSRect, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = frame
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        view.addSubview(button)
        return button
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 480))
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.background.cgColor
        view.addSubview(label("专注小闹钟", NSRect(x: 24, y: 437, width: 330, height: 26), 21, Palette.ink, .semibold))
        view.addSubview(label("把注意力留在这一件事上", NSRect(x: 24, y: 413, width: 330, height: 20), 12))
        modes = NSSegmentedControl(labels: ["倒计时", "5分休息", "10秒体验", "正计时"],
                                   trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modes.frame = NSRect(x: 24, y: 369, width: 332, height: 29)
        modes.segmentStyle = .rounded
        for index in 0..<4 { modes.setWidth(80, forSegment: index) }
        modes.setAccessibilityLabel("计时模式")
        view.addSubview(modes)
        view.addSubview(label("专注时长", NSRect(x: 24, y: 335, width: 65, height: 20), 12))
        minutes.frame = NSRect(x: 92, y: 331, width: 48, height: 25)
        minutes.alignment = .center
        minutes.setAccessibilityLabel("倒计时分钟数，1至180")
        view.addSubview(minutes)
        view.addSubview(label("分钟", NSRect(x: 145, y: 335, width: 30, height: 20), 12))
        _ = button("应用", NSRect(x: 177, y: 329, width: 62, height: 29), #selector(applyMinutes))
        _ = button("30 分钟", NSRect(x: 243, y: 329, width: 113, height: 29), #selector(thirtyMinutes))
        view.addSubview(ring)
        timeLabel.frame = NSRect(x: 162, y: 222, width: 194, height: 62)
        timeLabel.textColor = Palette.ink
        timeLabel.alignment = .center
        timeLabel.setAccessibilityLabel("当前计时")
        view.addSubview(timeLabel)
        phaseLabel.frame = NSRect(x: 162, y: 200, width: 194, height: 20)
        phaseLabel.font = .systemFont(ofSize: 12, weight: .medium)
        phaseLabel.textColor = Palette.muted
        phaseLabel.alignment = .center
        view.addSubview(phaseLabel)
        primary.frame = NSRect(x: 24, y: 146, width: 160, height: 35)
        primary.bezelStyle = .rounded
        primary.bezelColor = Palette.teal
        primary.isBordered = false
        primary.wantsLayer = true
        primary.layer?.backgroundColor = Palette.teal.cgColor
        primary.layer?.cornerRadius = 6
        primary.target = self
        primary.action = #selector(primaryClicked)
        view.addSubview(primary)
        end.frame = NSRect(x: 192, y: 146, width: 76, height: 35)
        end.bezelStyle = .rounded
        end.target = self
        end.action = #selector(stopClicked)
        view.addSubview(end)
        _ = button("重置", NSRect(x: 276, y: 146, width: 80, height: 35), #selector(resetClicked))
        history.frame = NSRect(x: 24, y: 107, width: 332, height: 31)
        history.bezelStyle = .rounded
        history.font = .systemFont(ofSize: 12)
        history.target = self
        history.action = #selector(historyClicked)
        view.addSubview(history)
        sound.frame = NSRect(x: 24, y: 75, width: 246, height: 29)
        sound.bezelStyle = .rounded
        sound.font = .systemFont(ofSize: 12)
        sound.target = self
        sound.action = #selector(soundChanged)
        view.addSubview(sound)
        _ = button("试听", NSRect(x: 280, y: 75, width: 76, height: 29), #selector(previewClicked))
        let note = label("暂停、休息和体验不计入专注记录", NSRect(x: 20, y: 48, width: 340, height: 18), 11)
        note.alignment = .center
        view.addSubview(note)
        view.addSubview(label("本机专注 · 记录只保存在这台 Mac", NSRect(x: 24, y: 14, width: 180, height: 16), 10))
        let hide = button("收起", NSRect(x: 246, y: 8, width: 56, height: 25), #selector(closeClicked))
        let quit = button("退出", NSRect(x: 304, y: 8, width: 56, height: 25), #selector(quitClicked))
        hide.isBordered = false
        quit.isBordered = false
    }

    func render(_ engine: CountdownEngine, today: Double, error: String?, reminder: ReminderSettings, reminderError: String?) {
        _ = view
        timeLabel.stringValue = engine.display
        timeLabel.font = .monospacedDigitSystemFont(ofSize: engine.display.count > 5 ? 32 : 42, weight: .medium)
        ring.progress = engine.progress
        modes.selectedSegment = engine.mode.rawValue
        if view.window?.firstResponder !== minutes.currentEditor() {
            minutes.stringValue = String(Int(engine.focusDurationSeconds / 60))
        }
        sound.title = reminder.mode == .sound ? "到点提醒：提示音 ×\(reminder.repeatCount) · 设置" : "到点提醒：\(reminder.mode.title) · 设置"
        if reminderError != nil { sound.title = "提醒播放异常 · 设置 / 试听" }
        sound.toolTip = reminderError
        end.isEnabled = engine.phase == .running || engine.phase == .paused
        history.title = error == nil ? "今日专注 \(focusDurationText(today)) · 查看日 / 周 / 月" : "记录保存异常 · 点此查看"
        history.toolTip = error
        switch engine.phase {
        case .idle: primary.title = "开始"; phaseLabel.stringValue = "准备好，再开始"
        case .running: primary.title = "暂停"; phaseLabel.stringValue = engine.mode == .stopwatch ? "已累计专注" : (engine.mode == .rest ? "休息中" : (engine.mode == .demo ? "体验中" : "专注中"))
        case .paused: primary.title = "继续"; phaseLabel.stringValue = "已暂停"
        case .finished: primary.title = "重新开始"; phaseLabel.stringValue = "本轮结束"
        }
        primary.attributedTitle = NSAttributedString(string: primary.title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
        ])
    }

    @objc private func primaryClicked() { onEvent?(.primary) }
    @objc private func stopClicked() { onEvent?(.stop) }
    @objc private func resetClicked() { onEvent?(.reset) }
    @objc private func historyClicked() { onEvent?(.history) }
    @objc private func previewClicked() { onEvent?(.previewSound) }
    @objc private func soundChanged() { onEvent?(.reminderSettings) }
    @objc private func closeClicked() { onEvent?(.closePanel) }
    @objc private func quitClicked() { onEvent?(.quit) }
    override func cancelOperation(_ sender: Any?) { onEvent?(.closePanel) }
    @objc private func modeChanged() {
        if let mode = FocusMode(rawValue: modes.selectedSegment) { onEvent?(.mode(mode)) }
    }
    @objc private func applyMinutes() {
        guard let count = Int(minutes.stringValue), (1...180).contains(count) else {
            let alert = NSAlert()
            alert.messageText = "请输入1至180之间的整数分钟"
            alert.runModal()
            return
        }
        onEvent?(.configure(Double(count * 60)))
    }
    @objc private func thirtyMinutes() { onEvent?(.configure(1800)) }
}

// A real native window pinned at the user's requested top-left position.
// This is an overlay in the menu-bar area, not a system NSStatusItem.

@MainActor
private final class TopTimerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private class TopInteractiveButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

@MainActor
private final class TopTimerButton: TopInteractiveButton {
    var onHorizontalDrag: ((CGFloat) -> Void)?
    private var initialX: CGFloat = 0
    private var initialPointerX: CGFloat = 0
    private var dragged = false

    override func draw(_ dirtyRect: NSRect) {
        let symbol = NSImage(systemSymbolName: "alarm", accessibilityDescription: "完整小闹钟")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))
        symbol?.draw(in: NSRect(x: 8, y: 5, width: 18, height: 18))
        let textSize = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: 34 + max(0, (70 - textSize.width) / 2),
                                         y: (bounds.height - textSize.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialX = window.frame.minX
        initialPointerX = window.convertPoint(toScreen: event.locationInWindow).x
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        // Use this event's position rather than sampling the global pointer.
        // The window can move during the drag, so convert every event to the
        // same screen coordinate space before measuring its displacement.
        let pointerX = window.convertPoint(toScreen: event.locationInWindow).x
        let delta = pointerX - initialPointerX
        if abs(delta) > 3 {
            dragged = true
            onHorizontalDrag?(initialX + delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged, let action { _ = sendAction(action, to: target) }
    }
}

/// Fixed, readable content with a bounded viewport on smaller displays.
/// All controls remain available by scrolling; normal-sized displays are unchanged.
@MainActor
private final class FocusScrollableController: NSViewController {
    private let child: NSViewController
    private let naturalSize: NSSize
    private let scroll = NSScrollView()

    init(child: NSViewController, naturalSize: NSSize) {
        self.child = child
        self.naturalSize = naturalSize
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        scroll.frame = NSRect(origin: .zero, size: naturalSize)
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        view = scroll
        addChild(child)
        child.view.frame = NSRect(origin: .zero, size: naturalSize)
        scroll.documentView = child.view
    }

    func setViewport(_ size: NSSize) {
        _ = view
        let changed = scroll.frame.size != size
        scroll.setFrameSize(size)
        scroll.tile()
        child.view.setFrameSize(naturalSize)
        if changed {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, naturalSize.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = CountdownEngine(now: MonotonicTime.seconds)
    private var topPanel: TopTimerPanel?
    private let quickButton = TopInteractiveButton(title: "▶", target: nil, action: nil)
    private let activityButton = TopInteractiveButton(title: "", target: nil, action: nil)
    private let topButton = TopTimerButton(frame: NSRect(x: 0, y: 0, width: 112, height: 28))
    private let popover = NSPopover()
    private let controller = TimerViewController()
    private var ticker: Timer?
    private let positionKey = "TopClockOverlayHorizontalRatioV1"
    private let screenKey = "TopClockOverlayDisplayIDV1"
    private var observers: [NSObjectProtocol] = []
    private var historyStore: FocusHistoryStore?
    private var historyError: String?
    private let historyController = FocusDashboardViewController()
    private var historyWindow: NSWindow?
    private var sessionID = UUID()
    private var accountedElapsed: Double = 0
    private var historyBoutBase: Double = 0
    private var historyCursor = Date()
    private var lastSave = MonotonicTime.seconds()
    private var lastHistoryRefresh: Double = 0
    private let reminder = ReminderController()
    private let reminderSettingsController = ReminderSettingsViewController()
    private var reminderWindow: NSWindow?
    private let reminderDefaultsKey = "ReminderSettingsV1"
    private var completionSoundPlayed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApplication.shared.terminate(nil)
            return
        }
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FocusClockLocal", isDirectory: true)
            var calendar = Calendar.current
            calendar.firstWeekday = 2
            historyStore = try FocusHistoryStore(fileURL: folder.appendingPathComponent("focus-history.json"), calendar: calendar)
        } catch { historyError = error.localizedDescription }
        if let data = UserDefaults.standard.data(forKey: reminderDefaultsKey),
           let value = try? JSONDecoder().decode(ReminderSettings.self, from: data),
           let checked = try? value.validated() { reminder.settings = checked }
        createTopPanel()
        controller.onEvent = { [weak self] event in self?.handle(event) }
        popover.contentViewController = FocusScrollableController(child: controller, naturalSize: NSSize(width: 380, height: 480))
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.behavior = .applicationDefined
        popover.animates = true
        render()
        topPanel?.orderFrontRegardless()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.positionTopPanel() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.pauseForSystemSleep() } })
    }

    private func createTopPanel() {
        let panel = TopTimerPanel(contentRect: NSRect(x: 0, y: 0, width: 232, height: 28), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        panel.title = "顶部专注小闹钟"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        topButton.isBordered = false
        topButton.wantsLayer = true
        topButton.target = self
        topButton.action = #selector(togglePopover)
        topButton.onHorizontalDrag = { [weak self] x in
            self?.popover.performClose(nil)
            self?.positionTopPanel(proposedX: x)
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 28))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.18, blue: 0.20, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 9
        container.layer?.masksToBounds = true
        container.addSubview(topButton)
        quickButton.frame = NSRect(x: 112, y: 0, width: 30, height: 28)
        quickButton.isBordered = false
        quickButton.target = self
        quickButton.action = #selector(quickToggle)
        container.addSubview(quickButton)
        activityButton.frame = NSRect(x: 144, y: 0, width: 84, height: 28)
        activityButton.isBordered = false
        activityButton.toolTip = "暂停当前计时并查看专注活动，保留进度"
        activityButton.setAccessibilityLabel("暂停并查看专注活动")
        activityButton.target = self
        activityButton.action = #selector(openActivity)
        container.addSubview(activityButton)
        panel.contentView = container
        topPanel = panel
        positionTopPanel()
        // Apply the desired level LAST: isFloatingPanel resets the window level.
        panel.level = .popUpMenu
    }


    private func screenID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func targetScreen() -> NSScreen? {
        if let stored = UserDefaults.standard.object(forKey: screenKey) as? NSNumber,
           let matching = NSScreen.screens.first(where: { screenID($0) == stored.uint32Value }) {
            return matching
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func positionTopPanel(proposedX: CGFloat? = nil) {
        guard let panel = topPanel,
              let screen = proposedX == nil ? targetScreen() : (panel.screen ?? targetScreen()) else { return }
        // A notch has an explicit top-left safe area. Without a notch, use the
        // actual menu-bar height; automatic menu hiding falls back to AppKit's
        // status-bar thickness rather than assuming a fixed 28-point bar.
        let visibleMenuHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let menuHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top
            : (visibleMenuHeight >= 16 ? visibleMenuHeight : NSStatusBar.system.thickness)
        let geometry = FocusScreenGeometry(frame: screen.frame, menuBarHeight: menuHeight,
                                           topLeftSafeArea: screen.auxiliaryTopLeftArea)
        let savedRatio = UserDefaults.standard.object(forKey: positionKey) as? Double
        let placement = FocusWindowPlacement.overlay(screen: geometry,
            ratio: savedRatio ?? FocusWindowPlacement.defaultHorizontalRatio, proposedX: proposedX)
        panel.setFrame(placement.frame, display: true)
        if let content = panel.contentView {
            content.setBoundsSize(FocusWindowPlacement.naturalOverlaySize)
        }
        if proposedX != nil {
            UserDefaults.standard.set(placement.horizontalRatio, forKey: positionKey)
        }
        if let id = screenID(screen) { UserDefaults.standard.set(NSNumber(value: id), forKey: screenKey) }
        if let window = historyWindow { fitAuxiliaryWindow(window, naturalSize: NSSize(width: 900, height: 740)) }
        if let window = reminderWindow { fitAuxiliaryWindow(window, naturalSize: NSSize(width: 440, height: 330)) }
        if popover.isShown { popover.performClose(nil) }
    }

    private func fitAuxiliaryWindow(_ window: NSWindow, naturalSize: NSSize, center: Bool = false) {
        guard let screen = topPanel?.screen ?? targetScreen() else { return }
        let titleHeight = window.frameRect(forContentRect: .zero).height
        let size = FocusWindowPlacement.viewport(natural: naturalSize, visible: screen.visibleFrame,
                                                 titleBarHeight: titleHeight)
        (window.contentViewController as? FocusScrollableController)?.setViewport(size)
        window.setContentSize(size)
        var frame = window.frame
        if center {
            frame.origin = NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                   y: screen.visibleFrame.midY - frame.height / 2)
        }
        window.setFrame(FocusWindowPlacement.clampedWindow(frame, visible: screen.visibleFrame), display: true)
    }

    private func accountHistory(forceSave: Bool = false) {
        if engine.isFocusSession, let store = historyStore {
            let current = engine.elapsedSeconds
            let delta = current - accountedElapsed
            if delta > 0 {
                do {
                    try store.record(start: historyCursor, duration: current - historyBoutBase,
                                     kind: engine.mode == .stopwatch ? .countUp : .countdown, sessionID: sessionID)
                    accountedElapsed = current
                } catch { historyError = error.localizedDescription }
            }
        }
        if let store = historyStore, forceSave || MonotonicTime.seconds() - lastSave >= 5 {
            do { try store.save(); lastSave = MonotonicTime.seconds(); historyError = nil }
            catch { historyError = error.localizedDescription }
        }
    }

    private func handle(_ event: TimerViewController.Event) {
        let previousPhase = engine.phase
        accountHistory(forceSave: true)
        switch event {
        case .primary:
            switch engine.phase {
            case .idle, .finished:
                reminder.stop()
                sessionID = UUID(); accountedElapsed = 0; historyBoutBase = 0; historyCursor = Date(); completionSoundPlayed = false
                engine.start()
            case .running: engine.pause(); accountHistory(forceSave: true)
            case .paused: historyCursor = Date(); historyBoutBase = accountedElapsed; engine.resume()
            }
        case .stop: engine.stop(); accountHistory(forceSave: true)
        case .reset: reminder.stop(); engine.reset(); accountedElapsed = 0
        case .mode(let mode): reminder.stop(); engine.select(mode); accountedElapsed = 0
        case .configure(let seconds):
            reminder.stop()
            controller.view.window?.makeFirstResponder(nil)
            if engine.configureFocus(seconds: seconds) { accountedElapsed = 0 }
        case .history:
            if engine.phase == .running { engine.pause(); accountHistory(forceSave: true) }
            notifyCompletion(previousPhase: previousPhase)
            synchronizeTicker(); render(); showHistory(); return
        case .reminderSettings: showReminderSettings(); return
        case .previewSound: reminder.play(); showPlaybackError(); return
        case .closePanel: popover.performClose(nil); return
        case .quit: NSApplication.shared.terminate(nil); return
        }
        notifyCompletion(previousPhase: previousPhase)
        synchronizeTicker()
        render()
    }

    private func notifyCompletion(previousPhase: TimerPhase) {
        guard previousPhase == .running, engine.phase == .finished,
              engine.mode == .focus, engine.remaining == 0, !completionSoundPlayed else { return }
        completionSoundPlayed = true
        reminder.play()
        showPlaybackError()
    }

    private func showPlaybackError() {
        guard let error = reminder.lastPlaybackError else { return }
        let alert = NSAlert()
        alert.messageText = "提醒未能播放"
        alert.informativeText = error
        alert.runModal()
    }

    private func showReminderSettings() {
        popover.performClose(nil)
        reminderSettingsController.settings = reminder.settings
        reminderSettingsController.voiceOptions = reminder.voiceOptions
        reminderSettingsController.onSave = { [weak self] value, preview in
            guard let self else { return }
            do {
                self.reminder.settings = try value.validated()
                UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: self.reminderDefaultsKey)
                self.render()
                if preview { self.reminder.play(); self.showPlaybackError() }
            } catch {
                let alert = NSAlert()
                alert.messageText = "提醒设置未保存"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        reminderSettingsController.onStop = { [weak self] in self?.reminder.stop() }
        if reminderWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 330),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "到点提醒设置"
            window.contentViewController = FocusScrollableController(child: reminderSettingsController, naturalSize: NSSize(width: 440, height: 330))
            window.isReleasedWhenClosed = false
            fitAuxiliaryWindow(window, naturalSize: NSSize(width: 440, height: 330), center: true)
            reminderWindow = window
        }
        if let window = reminderWindow { fitAuxiliaryWindow(window, naturalSize: NSSize(width: 440, height: 330)) }
        reminderSettingsController.reloadSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
        reminderWindow?.makeKeyAndOrderFront(nil)
    }

    private func synchronizeTicker() {
        ticker?.invalidate(); ticker = nil
        guard engine.phase == .running else { return }
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    @objc private func tick() {
        let previous = engine.phase
        engine.tick()
        accountHistory(forceSave: engine.phase == .finished)
        notifyCompletion(previousPhase: previous)
        if engine.phase != .running { ticker?.invalidate(); ticker = nil }
        render()
    }

    private func pauseForSystemSleep() {
        guard engine.phase == .running else { return }
        let previousPhase = engine.phase
        accountHistory(forceSave: true)
        engine.pause()
        accountHistory(forceSave: true)
        notifyCompletion(previousPhase: previousPhase)
        synchronizeTicker()
        render()
    }

    private func render() {
        let prefix = engine.phase == .paused ? "Ⅱ " : ""
        let title = prefix + engine.display
        topButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: title.count > 8 ? 10 : (title.count > 5 ? 12 : 14), weight: .semibold)
        ])
        topButton.toolTip = "点击控制 · 拖动调整顶部水平位置"
        topButton.setAccessibilityLabel("顶部专注小闹钟，当前 \(title)，点击控制，拖动调整位置")
        topButton.needsDisplay = true
        let quickTitle = engine.phase == .running ? "Ⅱ" : "▶"
        let quickFontSize: CGFloat = 14
        quickButton.attributedTitle = NSAttributedString(string: quickTitle, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: quickFontSize, weight: .semibold)
        ])
        quickButton.setAccessibilityLabel(engine.phase == .running ? "暂停，保留本轮进度" : (engine.phase == .paused ? "继续本轮专注" : "开始专注"))
        quickButton.toolTip = engine.phase == .running ? "暂停，保留本轮进度" : "开始或继续本轮"
        if let store = historyStore { store.calendar = Calendar.current; store.calendar.firstWeekday = 2 }
        let today = historyStore?.summary(.today, now: Date()).totalSeconds ?? 0
        activityButton.attributedTitle = NSAttributedString(string: "累计 \(Int(today / 60))分", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ])
        activityButton.toolTip = "今日已专注 \(focusDurationText(today))；点击暂停并查看专注活动，保留本轮进度"
        controller.render(engine, today: today, error: historyError, reminder: reminder.settings, reminderError: reminder.lastPlaybackError)
        if historyWindow?.isVisible == true, MonotonicTime.seconds() - lastHistoryRefresh >= 1 {
            lastHistoryRefresh = MonotonicTime.seconds()
            historyController.store = historyStore
            historyController.error = historyError
            historyController.refresh()
        }
    }

    private func showHistory() {
        popover.performClose(nil)
        historyController.store = historyStore
        historyController.error = historyError
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "专注记录"
            window.contentViewController = FocusScrollableController(child: historyController, naturalSize: NSSize(width: 900, height: 740))
            window.isReleasedWhenClosed = false
            fitAuxiliaryWindow(window, naturalSize: NSSize(width: 900, height: 740), center: true)
            historyWindow = window
        }
        if let window = historyWindow { fitAuxiliaryWindow(window, naturalSize: NSSize(width: 900, height: 740)) }
        historyController.refresh()
        NSApplication.shared.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quickToggle() { handle(.primary) }
    @objc private func openActivity() { handle(.history) }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        topPanel?.orderFrontRegardless(); showPopover(); return true
    }
    private func showPopover() {
        if let screen = topPanel?.screen ?? targetScreen() {
            let size = FocusWindowPlacement.viewport(natural: NSSize(width: 380, height: 480),
                                                     visible: screen.visibleFrame, titleBarHeight: 12)
            (popover.contentViewController as? FocusScrollableController)?.setViewport(size)
            popover.contentSize = size
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: topButton.bounds, of: topButton, preferredEdge: .minY)
        popover.contentViewController?.view.window?.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
        render()
    }
    func applicationWillTerminate(_ notification: Notification) {
        if engine.phase == .running { engine.pause() }
        accountHistory(forceSave: true)
        ticker?.invalidate(); ticker = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        popover.close()
        historyWindow?.close()
        topPanel?.close(); topPanel = nil
        reminderWindow?.close()
        reminder.stop()
    }
}

@main
private struct FocusApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
