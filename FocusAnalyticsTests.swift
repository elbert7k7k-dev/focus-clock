import Foundation

private struct AnalyticsFailure: Error, CustomStringConvertible { let description: String }
private final class AnalyticsChecks {
    private(set) var cases = 0
    private(set) var assertions = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw AnalyticsFailure(description: message) }
    }
    func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try expect(abs(actual - expected) < 0.000_01, "\(message): \(actual) != \(expected)")
    }
    func run(_ title: String, _ body: () throws -> Void) throws {
        try body(); cases += 1; print("PASS \(title)")
    }
}

@main
private struct FocusAnalyticsTestRunner {
    static func main() throws {
        let checks = AnalyticsChecks()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        utc.firstWeekday = 2
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
                  _ minute: Int = 0, _ second: Int = 0, calendar: Calendar? = nil) -> Date {
            (calendar ?? utc).date(from: DateComponents(year: year, month: month, day: day,
                                                       hour: hour, minute: minute, second: second))!
        }
        func entry(_ start: Date, _ duration: Double, session: UUID = UUID(),
                   kind: FocusHistoryKind = .countdown, id: UUID = UUID()) -> FocusHistoryEntry {
            FocusHistoryEntry(id: id, sessionID: session, startedAt: start,
                              endedAt: start.addingTimeInterval(duration), seconds: duration, kind: kind)
        }
        let now = date(2026, 10, 28, 12)
        func snapshot(_ entries: [FocusHistoryEntry], now: Date? = nil,
                      calendar: Calendar? = nil) -> FocusAnalyticsSnapshot {
            FocusAnalytics.make(entries: entries, calendar: calendar ?? utc,
                                now: now ?? date(2026, 10, 28, 12))
        }

        try checks.run("empty history produces six zero metrics") {
            let value = snapshot([])
            try checks.near(value.metrics.totalSeconds, 0, "Empty total")
            try checks.near(value.metrics.bestDaySeconds, 0, "Empty best day")
            try checks.near(value.metrics.longestSessionSeconds, 0, "Empty longest session")
            try checks.expect(value.metrics.currentStreak == 0, "Empty current streak")
            try checks.expect(value.metrics.longestStreak == 0, "Empty longest streak")
            try checks.expect(value.metrics.sessionCount == 0, "Empty session count")
            try checks.expect(value.dailyActivity.allSatisfy { $0.seconds == 0 && $0.level == 0 }, "Empty cells are gray")
        }
        try checks.run("paused segments count as one focus session without the pause") {
            let id = UUID()
            let value = snapshot([entry(date(2026, 10, 28, 8), 60, session: id),
                                  entry(date(2026, 10, 28, 9), 120, session: id)])
            try checks.expect(value.metrics.sessionCount == 1, "Session IDs must be unique")
            try checks.near(value.metrics.totalSeconds, 180, "Pause hour excluded")
            try checks.near(value.metrics.longestSessionSeconds, 180, "Single session uses active segments")
        }
        try checks.run("different sessions are counted separately") {
            let value = snapshot([entry(date(2026, 10, 28, 8), 60), entry(date(2026, 10, 28, 9), 300)])
            try checks.expect(value.metrics.sessionCount == 2, "Two unique sessions")
            try checks.near(value.metrics.longestSessionSeconds, 300, "Longest active session")
            try checks.near(value.metrics.totalSeconds, 360, "All sessions total")
        }
        try checks.run("session identity remains unique across record kinds") {
            let id = UUID()
            let value = snapshot([entry(date(2026, 10, 28, 8), 60, session: id),
                                  entry(date(2026, 10, 28, 9), 90, session: id, kind: .countUp)])
            try checks.expect(value.metrics.sessionCount == 1, "Kinds must not duplicate session ID count")
            try checks.near(value.metrics.longestSessionSeconds, 150, "Same identity active total")
        }
        try checks.run("replayed identical record identifier is not double counted") {
            let record = entry(date(2026, 10, 28, 8), 75)
            let value = snapshot([record, record])
            try checks.near(value.metrics.totalSeconds, 75, "Duplicate identifier total")
            try checks.expect(value.metrics.sessionCount == 1, "Duplicate session count")
        }
        try checks.run("midnight divides daily heatmap seconds accurately") {
            let value = snapshot([entry(date(2026, 10, 27, 23, 59, 30), 90)])
            let first = value.dailyActivity.first { $0.date == date(2026, 10, 27) }!
            let second = value.dailyActivity.first { $0.date == date(2026, 10, 28) }!
            try checks.near(first.seconds, 30, "Before midnight")
            try checks.near(second.seconds, 60, "After midnight")
            try checks.near(value.metrics.bestDaySeconds, 60, "Best actual calendar day")
            try checks.near(value.metrics.totalSeconds, 90, "Split preserves total")
            try checks.expect(value.metrics.currentStreak == 2, "Both days active")
        }
        try checks.run("streak crosses month and year boundaries") {
            let days = [date(2026, 12, 30, 8), date(2026, 12, 31, 8), date(2027, 1, 1, 8), date(2027, 1, 2, 8)]
            let value = snapshot(days.map { entry($0, 60) }, now: date(2027, 1, 2, 12))
            try checks.expect(value.metrics.currentStreak == 4, "Year boundary current streak")
            try checks.expect(value.metrics.longestStreak == 4, "Year boundary longest streak")
            try checks.expect(value.metrics.sessionCount == 4, "Daily unique sessions")
        }
        try checks.run("yesterday may continue current streak before today's first focus") {
            let days = [date(2026, 10, 25, 8), date(2026, 10, 26, 8), date(2026, 10, 27, 8)]
            let value = snapshot(days.map { entry($0, 60) })
            try checks.expect(value.metrics.currentStreak == 3, "Yesterday anchor remains active")
            try checks.expect(value.metrics.longestStreak == 3, "Three active days")
            try checks.near(value.dailyActivity.last!.seconds, 0, "Today has no fabricated focus")
        }
        try checks.run("a missed yesterday resets current streak but retains historical maximum") {
            let days = [date(2026, 10, 23, 8), date(2026, 10, 24, 8), date(2026, 10, 25, 8)]
            let value = snapshot(days.map { entry($0, 60) })
            try checks.expect(value.metrics.currentStreak == 0, "Missing yesterday breaks streak")
            try checks.expect(value.metrics.longestStreak == 3, "Historical streak retained")
        }
        try checks.run("today starts a new streak after a gap") {
            let value = snapshot([entry(date(2026, 10, 20, 8), 60), entry(date(2026, 10, 21, 8), 60),
                                  entry(date(2026, 10, 28, 8), 60)])
            try checks.expect(value.metrics.currentStreak == 1, "Today's new streak")
            try checks.expect(value.metrics.longestStreak == 2, "Previous longer streak")
        }
        try checks.run("future records do not affect totals count or streak") {
            let value = snapshot([entry(date(2026, 10, 29, 8), 1800), entry(date(2027, 1, 1), 3600)])
            try checks.near(value.metrics.totalSeconds, 0, "Future total excluded")
            try checks.expect(value.metrics.sessionCount == 0, "Future count excluded")
            try checks.expect(value.metrics.currentStreak == 0 && value.metrics.longestStreak == 0, "Future streak excluded")
            try checks.expect(value.dailyActivity.allSatisfy { $0.date <= utc.startOfDay(for: now) }, "Future cells omitted")
        }
        try checks.run("partially future segment clips to current time") {
            let value = snapshot([entry(now.addingTimeInterval(-40), 100)])
            try checks.near(value.metrics.totalSeconds, 40, "Only elapsed portion counts")
            try checks.near(value.metrics.longestSessionSeconds, 40, "Only elapsed session portion")
            try checks.expect(value.metrics.sessionCount == 1, "Partly elapsed session counts once")
        }
        try checks.run("spring daylight saving boundary keeps consecutive days") {
            var pacific = utc; pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let records = [entry(date(2026, 3, 7, 8, calendar: pacific), 60),
                           entry(date(2026, 3, 8, calendar: pacific), 23 * 3600),
                           entry(date(2026, 3, 9, 8, calendar: pacific), 60)]
            let value = snapshot(records, now: date(2026, 3, 9, 12, calendar: pacific), calendar: pacific)
            try checks.expect(value.metrics.currentStreak == 3, "Spring DST streak")
            try checks.expect(value.metrics.longestStreak == 3, "Spring DST historical streak")
            try checks.near(value.metrics.bestDaySeconds, 23 * 3600, "Spring day has 23 actual hours")
        }
        try checks.run("fall daylight saving boundary keeps repeated-hour day whole") {
            var pacific = utc; pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let records = [entry(date(2026, 10, 31, 8, calendar: pacific), 1),
                           entry(date(2026, 11, 1, calendar: pacific), 25 * 3600),
                           entry(date(2026, 11, 2, 8, calendar: pacific), 1)]
            let value = snapshot(records, now: date(2026, 11, 2, 12, calendar: pacific), calendar: pacific)
            try checks.expect(value.metrics.currentStreak == 3, "Fall DST streak")
            try checks.near(value.metrics.bestDaySeconds, 25 * 3600, "Fall day has 25 actual hours")
            try checks.near(value.metrics.totalSeconds, 25 * 3600 + 2, "Repeated hour counts once by real elapsed time")
        }
        try checks.run("calendar timezone determines activity date") {
            var shanghai = utc; shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let value = snapshot([entry(date(2026, 10, 27, 20), 600)],
                                 now: date(2026, 10, 28, 12, calendar: shanghai), calendar: shanghai)
            let localDay = date(2026, 10, 28, calendar: shanghai)
            try checks.near(value.dailyActivity.first { $0.date == localDay }!.seconds, 600, "Shanghai date assignment")
            try checks.expect(value.metrics.currentStreak == 1, "Local today active")
        }
        try checks.run("heatmap uses fixed real duration color bands") {
            for (seconds, level) in [(0.0, 0), (0.1, 1), (899.0, 1), (900.0, 2),
                                     (1799.0, 2), (1800.0, 3), (3599.0, 3), (3600.0, 4)] {
                try checks.expect(FocusAnalytics.level(for: seconds) == level, "Band for \(seconds)")
            }
            try checks.expect(FocusAnalytics.level(for: .nan) == 0, "NaN is not activity")
            try checks.expect(FocusAnalytics.level(for: -.infinity) == 0, "Invalid infinity is not activity")
        }
        try checks.run("heatmap is Monday aligned and includes 53 partial-or-full weeks") {
            var sunday = utc; sunday.firstWeekday = 1
            let value = snapshot([], calendar: sunday)
            try checks.expect(sunday.component(.weekday, from: value.heatmapStart) == 2, "Graph starts Monday regardless of locale week default")
            try checks.expect(value.dailyActivity.count == 367, "52 complete weeks plus Monday-Wednesday")
            try checks.expect(value.dailyActivity.last?.date == date(2026, 10, 28), "Last cell is today")
            try checks.expect(value.heatmapEnd == date(2026, 10, 29), "End is next local midnight")
            try checks.expect(utc.dateComponents([.day], from: value.heatmapStart, to: date(2026, 10, 26)).day == 364, "52 full preceding weeks")
        }
        try checks.run("all-history metrics include data older than visible heatmap") {
            let value = snapshot([entry(date(2023, 1, 1, 8), 300)])
            try checks.near(value.metrics.totalSeconds, 300, "Old data retained in total")
            try checks.near(value.metrics.bestDaySeconds, 300, "Old best day retained")
            try checks.near(value.metrics.longestSessionSeconds, 300, "Old longest session retained")
            try checks.expect(value.metrics.sessionCount == 1 && value.metrics.longestStreak == 1, "Old count and streak retained")
            try checks.expect(value.dailyActivity.allSatisfy { $0.seconds == 0 }, "Old data does not move into current cells")
        }
        try checks.run("fractional active seconds do not round away in analytics") {
            let id = UUID()
            let value = snapshot([entry(date(2026, 10, 28, 8), 0.125, session: id),
                                  entry(date(2026, 10, 28, 9), 0.375, session: id)])
            try checks.near(value.metrics.totalSeconds, 0.5, "Fractional total")
            try checks.near(value.metrics.longestSessionSeconds, 0.5, "Fractional single session")
            try checks.expect(value.metrics.currentStreak == 1, "Real positive fraction is activity")
        }
        try checks.run("invalid zero negative and non-finite entries are ignored") {
            let start = date(2026, 10, 28, 8)
            let records = [entry(start, 0), entry(start, -30), entry(start, .infinity),
                           FocusHistoryEntry(sessionID: UUID(), startedAt: start, endedAt: start.addingTimeInterval(30),
                                             seconds: .nan, kind: .countUp)]
            let value = snapshot(records)
            try checks.near(value.metrics.totalSeconds, 0, "Invalid total excluded")
            try checks.expect(value.metrics.sessionCount == 0 && value.metrics.currentStreak == 0, "Invalid activity excluded")
        }
        try checks.run("best day sums multiple distinct focused sessions") {
            let value = snapshot([entry(date(2026, 10, 27, 8), 300), entry(date(2026, 10, 27, 9), 600),
                                  entry(date(2026, 10, 28, 8), 700)])
            try checks.near(value.metrics.bestDaySeconds, 900, "Best day uses all focused sessions")
            try checks.near(value.metrics.longestSessionSeconds, 700, "Longest session differs from day total")
            try checks.near(value.metrics.totalSeconds, 1600, "Combined total")
        }
        try checks.run("future activity cannot fabricate today's streak") {
            let value = snapshot([entry(date(2026, 10, 26, 8), 30), entry(date(2026, 10, 27, 8), 30),
                                  entry(date(2026, 10, 28, 20), 600), entry(date(2026, 10, 29, 8), 600)])
            try checks.expect(value.metrics.currentStreak == 2, "Only yesterday and previous day count")
            try checks.expect(value.metrics.longestStreak == 2, "Future days omitted from longest streak")
            try checks.near(value.dailyActivity.last!.seconds, 0, "Today's future focus omitted")
        }
        print("Focus analytics tests passed: \(checks.cases) cases, \(checks.assertions) assertions.")
    }
}
