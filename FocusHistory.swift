import Foundation

enum FocusHistoryKind: String, Codable {
    case countdown
    case countUp

    var title: String { self == .countdown ? "倒计时" : "正计时" }
}

enum FocusHistoryRange: Int, CaseIterable {
    case today, week, month

    var title: String {
        switch self {
        case .today: return "今天"
        case .week: return "本周"
        case .month: return "本月"
        }
    }
}

/// One uninterrupted, actually focused interval. Pauses are separate entries.
/// The caller maps monotonic elapsed seconds onto a wall-date anchor.
struct FocusHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let startedAt: Date
    let endedAt: Date
    let seconds: Double
    let kind: FocusHistoryKind

    init(id: UUID = UUID(), sessionID: UUID, startedAt: Date, endedAt: Date,
         seconds: Double, kind: FocusHistoryKind) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.seconds = seconds
        self.kind = kind
    }
}

struct FocusDailyTotal {
    let dayStart: Date
    let seconds: Double
}

struct FocusHistorySummary {
    let interval: DateInterval
    let totalSeconds: Double
    /// Newest first, clipped to the selected calendar interval.
    let entries: [FocusHistoryEntry]
    /// Calendar days in ascending order, including days with no recorded focus.
    let dailyTotals: [FocusDailyTotal]
}

enum FocusHistoryError: Error, LocalizedError {
    case invalidInterval
    case unreadableFile
    case damagedFile
    case unsupportedVersion
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidInterval: return "专注记录时间无效，本段未写入。"
        case .unreadableFile: return "无法读取专注记录；原文件未被覆盖。"
        case .damagedFile: return "专注记录格式损坏；原文件未被覆盖，请先保留原文件。"
        case .unsupportedVersion: return "专注记录版本暂不支持；原文件未被覆盖。"
        case .saveFailed: return "专注记录未能保存到本机，内存中的本次记录仍保留。"
        }
    }
}

/// Main-thread callers serialize access. This model itself has no clocks,
/// timers, UI, networking, directory scanning, or application-global settings.
/// `record` changes memory only; call `save` on checkpoints and lifecycle events.
final class FocusHistoryStore {
    private struct Document: Codable {
        let version: Int
        let entries: [FocusHistoryEntry]
    }

    let fileURL: URL?
    var calendar: Calendar
    private(set) var allEntries: [FocusHistoryEntry] = []
    private(set) var isDirty = false

    init(fileURL: URL? = nil, calendar: Calendar = .current) throws {
        self.fileURL = fileURL
        self.calendar = calendar
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw FocusHistoryError.unreadableFile }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let document: Document
        do { document = try decoder.decode(Document.self, from: data) }
        catch { throw FocusHistoryError.damagedFile }
        guard document.version == 1 else { throw FocusHistoryError.unsupportedVersion }
        guard Self.validEntries(document.entries) else { throw FocusHistoryError.damagedFile }
        allEntries = Self.sorted(document.entries)
    }

    /// Call only for focused running time, never for pauses, rests or demos.
    /// Replaying the same interval for the same session is idempotent. Genuine
    /// overlap/adjacency merges; even a small positive pause remains a gap.
    func record(start: Date, duration: Double, kind: FocusHistoryKind, sessionID: UUID) throws {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              duration.isFinite, duration >= 0 else { throw FocusHistoryError.invalidInterval }
        guard duration > 0 else { return }
        let end = start.addingTimeInterval(duration)
        guard end.timeIntervalSinceReferenceDate.isFinite, end > start else {
            throw FocusHistoryError.invalidInterval
        }
        let addition = FocusHistoryEntry(sessionID: sessionID, startedAt: start, endedAt: end,
                                         seconds: end.timeIntervalSince(start), kind: kind)
        var matching = allEntries.filter { $0.sessionID == sessionID && $0.kind == kind }
        matching.append(addition)
        matching = Self.sorted(matching)
        var merged: [FocusHistoryEntry] = []
        for entry in matching {
            if let previous = merged.last, entry.startedAt <= previous.endedAt {
                let mergedEnd = max(previous.endedAt, entry.endedAt)
                merged[merged.count - 1] = FocusHistoryEntry(
                    id: previous.id, sessionID: sessionID, startedAt: previous.startedAt,
                    endedAt: mergedEnd, seconds: mergedEnd.timeIntervalSince(previous.startedAt), kind: kind)
            } else {
                merged.append(entry)
            }
        }
        let other = allEntries.filter { !($0.sessionID == sessionID && $0.kind == kind) }
        let updated = Self.sorted(other + merged)
        // The identifier of an exact duplicate should also stay stable.
        if Self.sameIntervals(updated, allEntries) { return }
        allEntries = updated
        isDirty = true
    }

    /// Writes only the supplied file and its own containing directory. Atomic
    /// replacement protects the preceding complete document from partial writes.
    func save() throws {
        guard isDirty else { return }
        guard let fileURL else { isDirty = false; return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(version: 1, entries: allEntries))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            isDirty = false
        } catch { throw FocusHistoryError.saveFailed }
    }

    func interval(for range: FocusHistoryRange, now: Date) -> DateInterval {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            return DateInterval(start: Date(timeIntervalSince1970: 0), duration: 0)
        }
        let component: Calendar.Component
        switch range {
        case .today: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        return calendar.dateInterval(of: component, for: now) ?? DateInterval(start: now, duration: 0)
    }

    func entries(in interval: DateInterval) -> [FocusHistoryEntry] {
        guard interval.start.timeIntervalSinceReferenceDate.isFinite,
              interval.end.timeIntervalSinceReferenceDate.isFinite, interval.duration > 0 else { return [] }
        return allEntries.compactMap { entry in
            let start = max(entry.startedAt, interval.start)
            let end = min(entry.endedAt, interval.end)
            guard end > start else { return nil }
            return FocusHistoryEntry(id: entry.id, sessionID: entry.sessionID,
                                      startedAt: start, endedAt: end,
                                      seconds: end.timeIntervalSince(start), kind: entry.kind)
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func total(in interval: DateInterval) -> Double {
        entries(in: interval).reduce(0) { $0 + $1.seconds }
    }

    func summary(_ range: FocusHistoryRange, now: Date) -> FocusHistorySummary {
        let selected = interval(for: range, now: now)
        let visibleEntries = entries(in: selected)
        var days: [FocusDailyTotal] = []
        var day = calendar.startOfDay(for: selected.start)
        // A selected calendar month has <=31 days; the bound only prevents a
        // malformed/non-progressing calendar calculation from looping forever.
        while day < selected.end && days.count < 367 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            let daily = DateInterval(start: max(day, selected.start), end: min(next, selected.end))
            days.append(FocusDailyTotal(dayStart: day, seconds: total(in: daily)))
            day = next
        }
        return FocusHistorySummary(interval: selected,
                                   totalSeconds: visibleEntries.reduce(0) { $0 + $1.seconds },
                                   entries: visibleEntries, dailyTotals: days)
    }

    private static func sorted(_ entries: [FocusHistoryEntry]) -> [FocusHistoryEntry] {
        entries.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.endedAt != $1.endedAt { return $0.endedAt < $1.endedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func sameIntervals(_ lhs: [FocusHistoryEntry], _ rhs: [FocusHistoryEntry]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            a.sessionID == b.sessionID && a.kind == b.kind && a.startedAt == b.startedAt && a.endedAt == b.endedAt
        }
    }

    private static func validEntries(_ entries: [FocusHistoryEntry]) -> Bool {
        guard Set(entries.map(\.id)).count == entries.count else { return false }
        for entry in entries {
            let span = entry.endedAt.timeIntervalSince(entry.startedAt)
            guard entry.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.endedAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.seconds.isFinite, entry.seconds > 0, span > 0,
                  abs(entry.seconds - span) < max(0.000_01, span * 0.000_000_001) else { return false }
        }
        let groups = Dictionary(grouping: entries) { "\($0.sessionID.uuidString):\($0.kind.rawValue)" }
        for values in groups.values {
            let ordered = sorted(values)
            for index in ordered.indices.dropFirst() {
                if ordered[index].startedAt < ordered[index - 1].endedAt { return false }
            }
        }
        return true
    }
}
