import Foundation

private struct HistoryTestFailure: Error, CustomStringConvertible { let description: String }

private final class HistoryChecks {
    private(set) var assertions = 0
    private(set) var cases = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if !(try condition()) { throw HistoryTestFailure(description: message) }
    }
    func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try expect(abs(actual - expected) < 0.000_01, "\(message): got \(actual), expected \(expected)")
    }
    func run(_ title: String, _ body: () throws -> Void) throws {
        try body(); cases += 1; print("PASS \(title)")
    }
    func rejects(_ message: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try expect(rejected, message)
    }
}

@main
private struct FocusHistoryTestRunner {
    static func main() throws {
        let checks = HistoryChecks()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        utc.firstWeekday = 2
        utc.minimumDaysInFirstWeek = 4
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
                  _ minute: Int = 0, _ second: Int = 0, calendar: Calendar? = nil) -> Date {
            let selected = calendar ?? utc
            return selected.date(from: DateComponents(year: year, month: month, day: day,
                                                      hour: hour, minute: minute, second: second))!
        }
        func store(_ calendar: Calendar? = nil) throws -> FocusHistoryStore {
            try FocusHistoryStore(calendar: calendar ?? utc)
        }
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".build/history-test-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        try checks.run("new store is empty and clean") {
            let history = try store()
            try checks.expect(history.allEntries.isEmpty, "New history must be empty")
            try checks.expect(!history.isDirty, "New history must be clean")
            let summary = history.summary(.today, now: date(2026, 10, 27, 12))
            try checks.near(summary.totalSeconds, 0, "Empty total")
            try checks.expect(summary.entries.isEmpty, "Empty summary entries")
            try checks.expect(summary.dailyTotals.count == 1, "Today has one calendar day")
        }
        try checks.run("one focused segment is reported exactly") {
            let history = try store()
            let start = date(2026, 10, 27, 9)
            try history.record(start: start, duration: 1500, kind: .countdown, sessionID: UUID())
            let summary = history.summary(.today, now: start)
            try checks.near(summary.totalSeconds, 1500, "Focused duration")
            try checks.expect(summary.entries.count == 1, "One segment")
            try checks.expect(summary.entries[0].kind == .countdown, "Correct kind")
            try checks.expect(history.isDirty, "Recording marks memory dirty")
        }
        try checks.run("continuous checkpoints merge without multiplying time") {
            let history = try store()
            let start = date(2026, 10, 27, 9)
            let session = UUID()
            for offset in 0..<100 {
                try history.record(start: start.addingTimeInterval(Double(offset)), duration: 1,
                                   kind: .countUp, sessionID: session)
            }
            try checks.expect(history.allEntries.count == 1, "Continuous segments should merge")
            try checks.near(history.allEntries[0].seconds, 100, "Merged time")
        }
        try checks.run("duplicate segment is idempotent and retains identifier") {
            let history = try store()
            let session = UUID(), start = date(2026, 10, 27, 9)
            try history.record(start: start, duration: 30, kind: .countUp, sessionID: session)
            let id = history.allEntries[0].id
            try history.save()
            try history.record(start: start, duration: 30, kind: .countUp, sessionID: session)
            try checks.expect(history.allEntries.count == 1, "Duplicate must not append")
            try checks.expect(history.allEntries[0].id == id, "Duplicate must keep identifier")
            try checks.near(history.allEntries[0].seconds, 30, "Duplicate total")
            try checks.expect(!history.isDirty, "Duplicate should not require writing")
        }
        try checks.run("overlap and transitive adjacency count a union") {
            let history = try store()
            let session = UUID(), start = date(2026, 10, 27, 9)
            for (offset, duration) in [(0.0, 9.0), (10.0, 10.0), (9.0, 6.0)] {
                try history.record(start: start.addingTimeInterval(offset), duration: duration,
                                   kind: .countdown, sessionID: session)
            }
            try checks.expect(history.allEntries.count == 1, "Bridge merges transitive segments")
            try checks.near(history.allEntries[0].seconds, 20, "Union must not duplicate overlap")
        }
        try checks.run("pause gap is excluded even within one session") {
            let history = try store()
            let session = UUID(), start = date(2026, 10, 27, 9)
            try history.record(start: start, duration: 60, kind: .countdown, sessionID: session)
            try history.record(start: start.addingTimeInterval(3600), duration: 30,
                               kind: .countdown, sessionID: session)
            try checks.expect(history.allEntries.count == 2, "Pause must remain a separate segment")
            try checks.near(history.summary(.today, now: start).totalSeconds, 90, "Pause must not count")
        }
        try checks.run("submillisecond pause remains excluded") {
            let history = try store()
            let session = UUID(), start = date(2026, 10, 27, 9)
            try history.record(start: start, duration: 1, kind: .countUp, sessionID: session)
            try history.record(start: start.addingTimeInterval(1.0005), duration: 1,
                               kind: .countUp, sessionID: session)
            try checks.expect(history.allEntries.count == 2, "Small real pause must not be merged")
            try checks.near(history.summary(.today, now: start).totalSeconds, 2, "Small pause excluded")
        }
        try checks.run("different session and kind are separate records") {
            let history = try store()
            let session = UUID(), start = date(2026, 10, 27, 9)
            try history.record(start: start, duration: 60, kind: .countdown, sessionID: session)
            try history.record(start: start.addingTimeInterval(60), duration: 30,
                               kind: .countUp, sessionID: session)
            try history.record(start: start.addingTimeInterval(90), duration: 10,
                               kind: .countUp, sessionID: UUID())
            try checks.expect(history.allEntries.count == 3, "Different identity/kind should not collapse")
            try checks.near(history.summary(.today, now: start).totalSeconds, 100, "Mixed focus total")
        }
        try checks.run("zero duration does not create a record") {
            let history = try store()
            try history.record(start: date(2026, 10, 27), duration: 0, kind: .countUp, sessionID: UUID())
            try checks.expect(history.allEntries.isEmpty, "Zero must not append")
            try checks.expect(!history.isDirty, "Zero must not dirty memory")
        }
        try checks.run("invalid input is rejected without changing data") {
            let history = try store()
            for duration in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
                try checks.rejects("Invalid duration must throw") {
                    try history.record(start: date(2026, 10, 27), duration: duration,
                                       kind: .countdown, sessionID: UUID())
                }
            }
            try checks.rejects("Invalid start date must throw") {
                try history.record(start: Date(timeIntervalSinceReferenceDate: .infinity), duration: 30,
                                   kind: .countdown, sessionID: UUID())
            }
            try checks.expect(history.allEntries.isEmpty, "Invalid values changed data")
        }
        try checks.run("midnight splits totals without duplicating the segment") {
            let history = try store()
            try history.record(start: date(2026, 10, 27, 23, 59, 30), duration: 90,
                               kind: .countdown, sessionID: UUID())
            let first = history.summary(.today, now: date(2026, 10, 27, 12))
            let second = history.summary(.today, now: date(2026, 10, 28, 12))
            try checks.near(first.totalSeconds, 30, "Before midnight")
            try checks.near(second.totalSeconds, 60, "After midnight")
            try checks.expect(history.allEntries.count == 1, "Stored segment need not duplicate for each day")
            try checks.expect(first.entries[0].endedAt == date(2026, 10, 28), "First clipped end")
            try checks.expect(second.entries[0].startedAt == date(2026, 10, 28), "Second clipped start")
        }
        try checks.run("day boundaries are half-open") {
            let history = try store()
            try history.record(start: date(2026, 10, 27, 23, 59), duration: 60,
                               kind: .countUp, sessionID: UUID())
            try checks.near(history.summary(.today, now: date(2026, 10, 27)).totalSeconds, 60, "Prior day")
            try checks.near(history.summary(.today, now: date(2026, 10, 28)).totalSeconds, 0, "No zero-length carry")
            try checks.expect(history.summary(.today, now: date(2026, 10, 28)).entries.isEmpty, "No empty carry row")
        }
        try checks.run("month and year boundaries use calendar ranges") {
            let history = try store()
            try history.record(start: date(2026, 12, 31, 23, 59), duration: 180,
                               kind: .countUp, sessionID: UUID())
            try checks.near(history.summary(.month, now: date(2026, 12, 15)).totalSeconds, 60, "December split")
            try checks.near(history.summary(.month, now: date(2027, 1, 15)).totalSeconds, 120, "January split")
            try checks.expect(history.summary(.month, now: date(2026, 12, 15)).dailyTotals.count == 31, "December days")
        }
        try checks.run("February uses 28 or 29 days rather than thirty") {
            let history = try store()
            try checks.expect(history.summary(.month, now: date(2026, 2, 12)).dailyTotals.count == 28, "Common February")
            try checks.expect(history.summary(.month, now: date(2028, 2, 12)).dailyTotals.count == 29, "Leap February")
            try checks.expect(history.summary(.month, now: date(2026, 4, 12)).dailyTotals.count == 30, "April days")
        }
        try checks.run("week starts on the supplied calendar first weekday") {
            let history = try store()
            let summary = history.summary(.week, now: date(2026, 10, 28, 12))
            try checks.expect(summary.interval.start == date(2026, 10, 26), "Monday start")
            try checks.expect(summary.interval.end == date(2026, 11, 2), "Following Monday end")
            try checks.expect(summary.dailyTotals.count == 7, "Seven calendar days")
            var sunday = utc; sunday.firstWeekday = 1
            let sundayStore = try store(sunday)
            try checks.expect(sundayStore.summary(.week, now: date(2026, 10, 28)).interval.start == date(2026, 10, 25), "Sunday calendar honored")
        }
        try checks.run("focus crossing week boundary is assigned proportionally") {
            let history = try store()
            try history.record(start: date(2026, 10, 25, 23, 59), duration: 120,
                               kind: .countdown, sessionID: UUID())
            try checks.near(history.summary(.week, now: date(2026, 10, 25)).totalSeconds, 60, "Prior week part")
            try checks.near(history.summary(.week, now: date(2026, 10, 26)).totalSeconds, 60, "Following week part")
        }
        try checks.run("spring DST day is 23 hours") {
            var pacific = utc; pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let history = try store(pacific)
            let beginning = date(2026, 3, 8, calendar: pacific)
            try history.record(start: beginning, duration: 23 * 3600, kind: .countUp, sessionID: UUID())
            let summary = history.summary(.today, now: date(2026, 3, 8, 12, calendar: pacific))
            try checks.near(summary.interval.duration, 23 * 3600, "Spring day length")
            try checks.near(summary.totalSeconds, 23 * 3600, "Spring elapsed duration")
            try checks.near(history.summary(.today, now: date(2026, 3, 9, calendar: pacific)).totalSeconds, 0, "No fixed-24-hour leakage")
        }
        try checks.run("fall DST day is 25 hours") {
            var pacific = utc; pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let history = try store(pacific)
            let beginning = date(2026, 11, 1, calendar: pacific)
            try history.record(start: beginning, duration: 25 * 3600, kind: .countUp, sessionID: UUID())
            let summary = history.summary(.today, now: date(2026, 11, 1, 12, calendar: pacific))
            try checks.near(summary.interval.duration, 25 * 3600, "Fall day length")
            try checks.near(summary.totalSeconds, 25 * 3600, "Fall elapsed duration")
            try checks.expect(summary.dailyTotals.count == 1, "Repeated hour stays one calendar day")
        }
        try checks.run("daily totals sum to the selected monthly total") {
            let history = try store()
            try history.record(start: date(2026, 10, 3, 23, 30), duration: 7200,
                               kind: .countUp, sessionID: UUID())
            try history.record(start: date(2026, 10, 20, 8), duration: 1500,
                               kind: .countdown, sessionID: UUID())
            let summary = history.summary(.month, now: date(2026, 10, 27))
            try checks.near(summary.dailyTotals.reduce(0) { $0 + $1.seconds }, summary.totalSeconds, "Daily sum conservation")
            try checks.expect(summary.dailyTotals.count == 31, "Zero days included")
            try checks.near(summary.totalSeconds, 8700, "Monthly total")
        }
        try checks.run("history details are clipped and newest first") {
            let history = try store()
            let early = date(2026, 10, 27, 8), late = date(2026, 10, 27, 10)
            try history.record(start: late, duration: 60, kind: .countUp, sessionID: UUID())
            try history.record(start: early, duration: 60, kind: .countdown, sessionID: UUID())
            let details = history.entries(in: DateInterval(start: early.addingTimeInterval(30), end: late.addingTimeInterval(30)))
            try checks.expect(details.count == 2, "Two visible records")
            try checks.expect(details[0].startedAt == late, "Newest detail first")
            try checks.near(details[0].seconds, 30, "Late clipping")
            try checks.near(details[1].seconds, 30, "Early clipping")
        }
        try checks.run("fractional active seconds survive persistence") {
            let url = fixtureRoot.appendingPathComponent("fractional/history.json")
            let history = try FocusHistoryStore(fileURL: url, calendar: utc)
            try history.record(start: date(2026, 10, 27, 9).addingTimeInterval(0.125), duration: 1.375,
                               kind: .countUp, sessionID: UUID())
            try history.save()
            try checks.expect(!history.isDirty, "Saved store is clean")
            let reopened = try FocusHistoryStore(fileURL: url, calendar: utc)
            try checks.near(reopened.summary(.today, now: date(2026, 10, 27)).totalSeconds, 1.375, "Fractional persisted total")
            try checks.expect(reopened.allEntries == history.allEntries, "Round trip retains all fields")
        }
        try checks.run("multiple checkpoints reopen as one current document") {
            let url = fixtureRoot.appendingPathComponent("checkpoints/history.json")
            let history = try FocusHistoryStore(fileURL: url, calendar: utc)
            let start = date(2026, 10, 27), session = UUID()
            try history.record(start: start, duration: 5, kind: .countUp, sessionID: session)
            try history.save()
            try history.record(start: start.addingTimeInterval(5), duration: 5, kind: .countUp, sessionID: session)
            try history.save()
            let reopened = try FocusHistoryStore(fileURL: url, calendar: utc)
            try checks.expect(reopened.allEntries.count == 1, "Checkpoint rewrites a complete document")
            try checks.near(reopened.allEntries[0].seconds, 10, "Checkpoint total")
        }
        try checks.run("clean save does not create an empty data file") {
            let url = fixtureRoot.appendingPathComponent("clean/history.json")
            let history = try FocusHistoryStore(fileURL: url, calendar: utc)
            try history.save()
            try checks.expect(!FileManager.default.fileExists(atPath: url.path), "Clean store should not touch disk")
        }
        try checks.run("malformed JSON remains byte-for-byte unchanged") {
            let url = fixtureRoot.appendingPathComponent("corrupt.json")
            let original = Data("{incomplete original record".utf8)
            try original.write(to: url)
            try checks.rejects("Malformed file must report an error") {
                _ = try FocusHistoryStore(fileURL: url, calendar: utc)
            }
            try checks.expect(try Data(contentsOf: url) == original, "Corrupt original was overwritten")
        }
        try checks.run("unsupported schema version is preserved") {
            let url = fixtureRoot.appendingPathComponent("future.json")
            let original = Data("{\"version\":99,\"entries\":[]}".utf8)
            try original.write(to: url)
            try checks.rejects("Unsupported version must throw") {
                _ = try FocusHistoryStore(fileURL: url, calendar: utc)
            }
            try checks.expect(try Data(contentsOf: url) == original, "Future file must be preserved")
        }
        try checks.run("decoded inconsistent seconds are rejected without replacement") {
            let url = fixtureRoot.appendingPathComponent("inconsistent.json")
            let content: [String: Any] = ["version": 1, "entries": [[
                "id": UUID().uuidString, "sessionID": UUID().uuidString,
                "startedAt": 1000.0, "endedAt": 1060.0, "seconds": 600.0, "kind": "countUp"
            ]]]
            let original = try JSONSerialization.data(withJSONObject: content)
            try original.write(to: url)
            try checks.rejects("Inconsistent seconds must be rejected") {
                _ = try FocusHistoryStore(fileURL: url, calendar: utc)
            }
            try checks.expect(try Data(contentsOf: url) == original, "Inconsistent file must be preserved")
        }
        try checks.run("failed save keeps unsaved memory and dirty flag") {
            let blockingFile = fixtureRoot.appendingPathComponent("not-a-directory")
            try Data("blocking test fixture".utf8).write(to: blockingFile)
            let history = try FocusHistoryStore(fileURL: blockingFile.appendingPathComponent("history.json"), calendar: utc)
            try history.record(start: date(2026, 10, 27), duration: 12, kind: .countUp, sessionID: UUID())
            try checks.rejects("Unwritable parent must report save failure") { try history.save() }
            try checks.expect(history.isDirty, "Save failure cleared dirty flag")
            try checks.near(history.allEntries[0].seconds, 12, "Save failure lost memory")
        }
        try checks.run("calendar timezone controls day assignment") {
            var shanghai = utc; shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let history = try store(shanghai)
            let start = date(2026, 10, 27, 20) // Oct 28 04:00 in Shanghai.
            try history.record(start: start, duration: 600, kind: .countdown, sessionID: UUID())
            try checks.near(history.summary(.today, now: date(2026, 10, 28, 12, calendar: shanghai)).totalSeconds, 600, "Local day total")
            try checks.near(history.summary(.today, now: date(2026, 10, 27, 12, calendar: shanghai)).totalSeconds, 0, "Not UTC day")
        }
        try checks.run("range and kind titles are meaningful") {
            try checks.expect(FocusHistoryRange.allCases.map(\.title) == ["今天", "本周", "本月"], "Range labels")
            try checks.expect(FocusHistoryKind.countdown.title == "倒计时", "Countdown label")
            try checks.expect(FocusHistoryKind.countUp.title == "正计时", "Count-up label")
        }
        print("Focus history tests passed: \(checks.cases) cases, \(checks.assertions) assertions.")
    }
}
