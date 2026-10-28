import AppKit

private enum DashboardStyle {
    static let ink = NSColor(srgbRed: 0.12, green: 0.20, blue: 0.31, alpha: 1)
    static let muted = NSColor(srgbRed: 0.43, green: 0.47, blue: 0.53, alpha: 1)
    static let background = NSColor(srgbRed: 0.985, green: 0.980, blue: 0.965, alpha: 1)
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.90, green: 0.92, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.76, green: 0.87, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.43, green: 0.69, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.18, green: 0.49, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.30, blue: 0.61, alpha: 1)
    ]

    static func duration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.isFinite ? seconds.rounded() : 0))
        let hours = whole / 3600, minutes = whole % 3600 / 60, rest = whole % 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(rest)秒" }
        return "\(rest)秒"
    }

    static func label(_ text: String, frame: NSRect, size: CGFloat = 12,
                      weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color ?? ink
        return label
    }
}

@MainActor
private final class FocusMetricCard: NSView {
    private let value: NSTextField
    init(title: String, frame: NSRect) {
        value = DashboardStyle.label("0", frame: NSRect(x: 16, y: 12, width: frame.width - 32, height: 28),
                                     size: 22, weight: .semibold)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 11
        layer?.borderColor = NSColor(srgbRed: 0.90, green: 0.92, blue: 0.93, alpha: 1).cgColor
        layer?.borderWidth = 1
        addSubview(DashboardStyle.label(title, frame: NSRect(x: 16, y: 45, width: frame.width - 32, height: 17),
                                        size: 11, color: DashboardStyle.muted))
        addSubview(value)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func setValue(_ text: String) { if value.stringValue != text { value.stringValue = text } }
}

@MainActor
private final class FocusDayHoverCard: NSView {
    private let dateLabel = DashboardStyle.label("", frame: NSRect(x: 12, y: 38, width: 212, height: 16),
                                                  size: 11, color: NSColor.white.withAlphaComponent(0.85))
    private let durationLabel = DashboardStyle.label("", frame: NSRect(x: 12, y: 11, width: 212, height: 22),
                                                      size: 15, weight: .semibold, color: .white)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 236, height: 62))
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.16, blue: 0.24, alpha: 0.97).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        dateLabel.setAccessibilityIdentifier("focus.hover.date")
        durationLabel.setAccessibilityIdentifier("focus.hover.duration")
        addSubview(dateLabel)
        addSubview(durationLabel)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    // The card is presentation only. Let the original cell keep all mouse
    // tracking, so the card cannot cause enter/exit flicker or steal a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(day: FocusActivityDay, calendar: Calendar) {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "zh_CN")
        format.dateFormat = "yyyy年M月d日 EEEE"
        dateLabel.stringValue = format.string(from: day.date)
        let whole = max(0, Int(day.seconds.isFinite ? day.seconds.rounded() : 0))
        let hours = whole / 3600, minutes = whole % 3600 / 60, seconds = whole % 60
        let duration: String
        if hours > 0 { duration = "\(hours)小时\(minutes)分\(seconds)秒" }
        else if minutes > 0 { duration = "\(minutes)分\(seconds)秒" }
        else { duration = "\(seconds)秒" }
        durationLabel.stringValue = "专注 \(duration)"
    }
}

@MainActor
private final class FocusHeatmapView: NSView {
    private var days: [FocusActivityDay] = []
    private var calendar = Calendar.current
    private var graphStart = Date(timeIntervalSince1970: 0)
    private var previousBounds = NSRect.zero
    private var hoverTrackingArea: NSTrackingArea?
    private let hoverCard = FocusDayHoverCard()
    private var hoveredIndex: Int?
    private var lastHoverPoint: NSPoint?
    private weak var observedWindow: NSWindow?

    func update(_ snapshot: FocusAnalyticsSnapshot, calendar: Calendar) {
        let geometryChanged = graphStart != snapshot.heatmapStart || days.map(\.date) != snapshot.dailyActivity.map(\.date)
        let colorsChanged = days.map(\.level) != snapshot.dailyActivity.map(\.level)
        graphStart = snapshot.heatmapStart
        days = snapshot.dailyActivity
        self.calendar = calendar
        if geometryChanged || colorsChanged { needsDisplay = true }
        // An already shown card follows live data even when the color band has
        // not changed. Its value always comes from the real daily snapshot.
        if let point = lastHoverPoint { updateHover(at: point) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hoverCard.removeFromSuperview()
        hideHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let oldWindow = observedWindow {
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didResignKeyNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: oldWindow)
            }
        }
        observedWindow = window
        if let window {
            window.acceptsMouseMovedEvents = true
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowStoppedHovering),
                                                       name: name, object: window)
            }
        }
        hideHover()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        // Use our immediate in-window card, not the delayed system tooltip.
        removeAllToolTips()
    }

    override func layout() {
        super.layout()
        if bounds != previousBounds {
            previousBounds = bounds
            needsDisplay = true
            if let point = lastHoverPoint { updateHover(at: point) }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hideHover() }
    override func mouseDown(with event: NSEvent) {
        // A click also reveals the same detail, but hovering never requires it.
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    @objc private func windowStoppedHovering(_ notification: Notification) { hideHover() }

    private var step: CGFloat { min(15, max(10, (bounds.width - 46) / 53)) }
    private var cell: CGFloat { step - 3 }
    private func rect(at index: Int) -> NSRect {
        NSRect(x: 34 + CGFloat(index / 7) * step,
               y: bounds.height - 39 - CGFloat(index % 7) * step,
               width: cell, height: cell)
    }

    private func updateHover(at point: NSPoint) {
        guard bounds.contains(point),
              let index = days.indices.first(where: { rect(at: $0).contains(point) }),
              let host = superview, window?.isVisible == true else {
            hideHover()
            return
        }
        lastHoverPoint = point
        if hoveredIndex != index { hoveredIndex = index; needsDisplay = true }
        hoverCard.update(day: days[index], calendar: calendar)
        if hoverCard.superview !== host {
            hoverCard.removeFromSuperview()
            host.addSubview(hoverCard, positioned: .above, relativeTo: nil)
        } else if hoverCard.isHidden {
            host.addSubview(hoverCard, positioned: .above, relativeTo: nil)
        }
        let cellRect = convert(rect(at: index), to: host)
        let margin: CGFloat = 8
        let size = hoverCard.frame.size
        let viewport = host.visibleRect
        guard !viewport.isEmpty else { hideHover(); return }
        let maxX = max(viewport.minX + margin, viewport.maxX - size.width - margin)
        let x = min(maxX, max(viewport.minX + margin, cellRect.midX - size.width / 2))
        let aboveY = cellRect.maxY + 8
        let y: CGFloat
        if aboveY + size.height <= viewport.maxY - margin {
            y = aboveY
        } else {
            y = max(viewport.minY + margin, cellRect.minY - size.height - 8)
        }
        hoverCard.setFrameOrigin(NSPoint(x: x, y: y))
        hoverCard.isHidden = false
    }

    private func hideHover() {
        if hoveredIndex != nil { needsDisplay = true }
        hoveredIndex = nil
        lastHoverPoint = nil
        hoverCard.isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: DashboardStyle.muted
        ]
        var previousMonth: Int?
        var lastMonthLabelX: CGFloat = -.greatestFiniteMagnitude
        for (index, day) in days.enumerated() {
            let rect = rect(at: index)
            DashboardStyle.colors[min(4, max(0, day.level))].setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
            if hoveredIndex == index {
                NSColor(srgbRed: 0.18, green: 0.43, blue: 0.70, alpha: 1).setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
                outline.lineWidth = 1.5
                outline.stroke()
            }
            if index % 7 == 0 {
                let month = calendar.component(.month, from: day.date)
                if month != previousMonth {
                    let isFirstResidualWeek = index == 0 && calendar.component(.day, from: day.date) > 7
                    if !isFirstResidualWeek && rect.minX - lastMonthLabelX >= 30 {
                        NSAttributedString(string: "\(month)月", attributes: attributes)
                            .draw(at: NSPoint(x: rect.minX, y: bounds.height - 18))
                        lastMonthLabelX = rect.minX
                    }
                    previousMonth = month
                }
            }
        }
        for (row, text) in [(0, "一"), (2, "三"), (4, "五"), (6, "日")] {
            let rect = self.rect(at: row)
            NSAttributedString(string: text, attributes: attributes)
                .draw(at: NSPoint(x: 12, y: rect.midY - 6))
        }
        NSAttributedString(string: "每格一天 · 灰色无记录，蓝色越深时长越多", attributes: attributes)
            .draw(at: NSPoint(x: 34, y: 5))
        let legendX = bounds.width - 152
        NSAttributedString(string: "少", attributes: attributes).draw(at: NSPoint(x: legendX - 20, y: 5))
        for level in 0...4 {
            DashboardStyle.colors[level].setFill()
            NSBezierPath(roundedRect: NSRect(x: legendX + CGFloat(level) * 16, y: 5, width: 12, height: 12),
                         xRadius: 2.5, yRadius: 2.5).fill()
        }
        NSAttributedString(string: "多", attributes: attributes).draw(at: NSPoint(x: legendX + 87, y: 5))
    }
}

@MainActor
final class FocusDashboardViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var store: FocusHistoryStore?
    var error: String?

    private struct Row: Equatable {
        let id: UUID
        let date: String
        let time: String
        let mode: String
        let duration: String
    }
    private let ranges = NSSegmentedControl(labels: ["今天", "本周", "本月"], trackingMode: .selectOne,
                                             target: nil, action: nil)
    private let heatmap = FocusHeatmapView(frame: NSRect(x: 28, y: 294, width: 844, height: 160))
    private let totalLabel = DashboardStyle.label("", frame: NSRect(x: 320, y: 253, width: 552, height: 23), size: 14, weight: .medium)
    private let errorLabel = DashboardStyle.label("", frame: NSRect(x: 28, y: 220, width: 844, height: 20), size: 11, color: .systemRed)
    private let emptyLabel = DashboardStyle.label("还没有专注记录，开始一轮专注后会显示在这里。",
                                                   frame: NSRect(x: 60, y: 107, width: 780, height: 24),
                                                   size: 12, color: DashboardStyle.muted)
    private let table = NSTableView()
    private let scroll = NSScrollView(frame: NSRect(x: 28, y: 28, width: 844, height: 185))
    private var cards: [FocusMetricCard] = []
    private var rows: [Row] = []
    private var lastEntries: [FocusHistoryEntry]?
    private var lastCalendar: Calendar?
    private var lastDay: Date?
    private var lastRange: FocusHistoryRange?
    private var lastError: String?
    private var lastUpdateUptime: TimeInterval = 0

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 740))
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = DashboardStyle.background.cgColor
        view.addSubview(DashboardStyle.label("我的专注记录", frame: NSRect(x: 28, y: 687, width: 844, height: 31), size: 24, weight: .semibold))
        view.addSubview(DashboardStyle.label("真实计时，留下一天一点的专注积累 · 仅保存在这台 Mac", frame: NSRect(x: 28, y: 662, width: 844, height: 20), size: 12, color: DashboardStyle.muted))
        let titles = ["累计专注", "单日最高专注", "最长单次专注", "当前连续天数", "最长连续天数", "累计专注次数"]
        for index in 0..<6 {
            let card = FocusMetricCard(title: titles[index], frame: NSRect(x: 28 + CGFloat(index % 3) * 286,
                                                                          y: index < 3 ? 577 : 495,
                                                                          width: 272, height: 70))
            cards.append(card)
            view.addSubview(card)
        }
        view.addSubview(DashboardStyle.label("专注活动", frame: NSRect(x: 28, y: 461, width: 400, height: 23), size: 16, weight: .semibold))
        let hint = DashboardStyle.label("过去 53 周 · 周一开始 · 悬停看每日时长", frame: NSRect(x: 440, y: 465, width: 432, height: 18), size: 11, color: DashboardStyle.muted)
        hint.alignment = .right
        view.addSubview(hint)
        view.addSubview(heatmap)
        ranges.frame = NSRect(x: 28, y: 247, width: 264, height: 30)
        ranges.segmentStyle = .rounded
        ranges.selectedSegment = 0
        ranges.target = self
        ranges.action = #selector(rangeChanged)
        ranges.setAccessibilityLabel("专注记录时间范围")
        view.addSubview(ranges)
        totalLabel.alignment = .right
        view.addSubview(totalLabel)
        view.addSubview(errorLabel)
        configureTable()
        emptyLabel.alignment = .center
        view.addSubview(emptyLabel)
        refresh()
    }

    private func configureTable() {
        for (id, title, width) in [("date", "日期", CGFloat(130)), ("time", "起止时间", 260),
                                   ("mode", "模式", 130), ("duration", "专注时长", 260)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = width
            let cell = NSTextFieldCell(textCell: "")
            cell.font = .systemFont(ofSize: 12)
            cell.textColor = DashboardStyle.ink
            column.dataCell = cell
            table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView()
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        view.addSubview(scroll)
    }

    /// Root may call once each second. A stable data/calendar/range snapshot
    /// performs no view rebuild, draw, table reload, or scrolling operation.
    func refresh() {
        guard isViewLoaded else { return }
        let now = Date()
        var calendar = store?.calendar ?? Calendar.current
        calendar.firstWeekday = 2
        let selected = FocusHistoryRange(rawValue: ranges.selectedSegment) ?? .today
        let entries = store?.allEntries ?? []
        let day = calendar.startOfDay(for: now)
        let rangeChanged = lastRange != selected
        let changed = lastEntries != entries || lastCalendar != calendar || lastDay != day
        let errorChanged = lastError != error
        guard changed || rangeChanged || errorChanged else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if changed && !rangeChanged && !errorChanged && uptime - lastUpdateUptime < 0.8 { return }
        if changed || rangeChanged {
            let snapshot = FocusAnalytics.make(entries: entries, calendar: calendar, now: now)
            let metrics = snapshot.metrics
            let values = [DashboardStyle.duration(metrics.totalSeconds), DashboardStyle.duration(metrics.bestDaySeconds),
                          DashboardStyle.duration(metrics.longestSessionSeconds), "\(metrics.currentStreak) 天",
                          "\(metrics.longestStreak) 天", "\(metrics.sessionCount) 次"]
            for (card, value) in zip(cards, values) { card.setValue(value) }
            heatmap.update(snapshot, calendar: calendar)
            updateRows(selected: selected, calendar: calendar, now: now)
        }
        errorLabel.stringValue = error ?? ""
        lastEntries = entries
        lastCalendar = calendar
        lastDay = day
        lastRange = selected
        lastError = error
        lastUpdateUptime = uptime
    }

    private func updateRows(selected: FocusHistoryRange, calendar: Calendar, now: Date) {
        let component: Calendar.Component = selected == .today ? .day : (selected == .week ? .weekOfYear : .month)
        let interval = calendar.dateInterval(of: component, for: now) ?? DateInterval(start: now, duration: 0)
        let visibleInterval = DateInterval(start: interval.start, end: min(now, interval.end))
        let entries = store?.entries(in: visibleInterval) ?? []
        let dateFormat = DateFormatter()
        dateFormat.calendar = calendar; dateFormat.timeZone = calendar.timeZone
        dateFormat.locale = Locale(identifier: "zh_CN"); dateFormat.dateFormat = "M月d日 EEE"
        let timeFormat = DateFormatter()
        timeFormat.calendar = calendar; timeFormat.timeZone = calendar.timeZone
        timeFormat.locale = Locale(identifier: "zh_CN"); timeFormat.dateFormat = "HH:mm:ss"
        let updated = entries.map { entry in
            Row(id: entry.id, date: dateFormat.string(from: entry.startedAt),
                time: "\(timeFormat.string(from: entry.startedAt)) — \(timeFormat.string(from: entry.endedAt))",
                mode: entry.kind.title, duration: DashboardStyle.duration(entry.seconds))
        }
        let sum = entries.reduce(0) { $0 + $1.seconds }
        totalLabel.stringValue = "\(selected.title)专注  \(DashboardStyle.duration(sum))"
        emptyLabel.isHidden = !updated.isEmpty
        guard updated != rows else { return }
        let oldOrigin = scroll.contentView.bounds.origin
        if rows.map(\.id) == updated.map(\.id) {
            let changed = IndexSet(updated.indices.filter { updated[$0] != rows[$0] })
            rows = updated
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        } else {
            rows = updated
            table.reloadData()
            let maxY = max(0, table.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: oldOrigin.x, y: min(oldOrigin.y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func rangeChanged() { refresh() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard rows.indices.contains(row) else { return nil }
        switch tableColumn?.identifier.rawValue {
        case "date": return rows[row].date
        case "time": return rows[row].time
        case "mode": return rows[row].mode
        case "duration": return rows[row].duration
        default: return nil
        }
    }
}
