import Foundation

struct FocusMetrics: Equatable {
    let totalSeconds: Double
    let bestDaySeconds: Double
    let longestSessionSeconds: Double
    let currentStreak: Int
    let longestStreak: Int
    let sessionCount: Int
}

struct FocusActivityDay: Equatable, Identifiable {
    var id: Date { date }
    let date: Date
    let seconds: Double
    /// Fixed real-duration bands: zero / <15 / <30 / <60 / >=60 minutes.
    let level: Int
}

struct FocusAnalyticsSnapshot: Equatable {
    let metrics: FocusMetrics
    let dailyActivity: [FocusActivityDay]
    let heatmapStart: Date
    /// The next local midnight; future dates are omitted from dailyActivity.
    let heatmapEnd: Date
}

enum FocusAnalytics {
    /// Pure aggregation. Positive focus entries only; future portions are
    /// clipped to now. Calendar arithmetic, rather than 86400-second offsets,
    /// defines days and streaks across midnight, year changes and DST.
    static func make(entries: [FocusHistoryEntry], calendar: Calendar,
                     now: Date) -> FocusAnalyticsSnapshot {
        var calendar = calendar
        calendar.firstWeekday = 2
        let safeNow = now.timeIntervalSinceReferenceDate.isFinite ? now : Date(timeIntervalSince1970: 0)
        let today = calendar.startOfDay(for: safeNow)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let graphStart = calendar.date(byAdding: .weekOfYear, value: -52, to: weekStart) ?? weekStart
        let graphEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        var daily: [Date: Double] = [:]
        var sessions: [UUID: Double] = [:]
        var total: Double = 0
        var seen = Set<UUID>()

        for entry in entries where seen.insert(entry.id).inserted {
            let span = entry.endedAt.timeIntervalSince(entry.startedAt)
            guard entry.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.endedAt.timeIntervalSinceReferenceDate.isFinite,
                  span.isFinite, span > 0, entry.seconds.isFinite, entry.seconds > 0 else { continue }
            let start = entry.startedAt
            let end = min(entry.endedAt, safeNow)
            guard end > start else { continue }
            let focused = entry.seconds * end.timeIntervalSince(start) / span
            guard focused.isFinite, focused > 0 else { continue }
            total += focused
            sessions[entry.sessionID, default: 0] += focused
            var cursor = start
            while cursor < end {
                guard let day = calendar.dateInterval(of: .day, for: cursor), day.end > cursor else { break }
                let stop = min(end, day.end)
                daily[day.start, default: 0] += entry.seconds * stop.timeIntervalSince(cursor) / span
                cursor = stop
            }
        }

        let activeDays = daily.filter { $0.value > 0 }.map(\.key).sorted()
        let activeSet = Set(activeDays)
        var longest = 0, run = 0
        var previous: Date?
        for day in activeDays {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else { run = 1 }
            longest = max(longest, run)
            previous = day
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        var current = 0
        var cursor: Date? = activeSet.contains(today) ? today : yesterday
        while let day = cursor, activeSet.contains(day) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }

        var graph: [FocusActivityDay] = []
        var day = graphStart
        while day < graphEnd && graph.count < 371 {
            let seconds = daily[day] ?? 0
            graph.append(FocusActivityDay(date: day, seconds: seconds, level: level(for: seconds)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return FocusAnalyticsSnapshot(metrics: FocusMetrics(
            totalSeconds: total,
            bestDaySeconds: daily.values.max() ?? 0,
            longestSessionSeconds: sessions.values.max() ?? 0,
            currentStreak: current, longestStreak: longest, sessionCount: sessions.count),
            dailyActivity: graph, heatmapStart: graphStart, heatmapEnd: graphEnd)
    }

    static func level(for seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        if seconds < 15 * 60 { return 1 }
        if seconds < 30 * 60 { return 2 }
        if seconds < 60 * 60 { return 3 }
        return 4
    }
}
