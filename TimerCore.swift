import Foundation

enum FocusMode: Int, CaseIterable {
    case focus
    case rest
    case demo
    case stopwatch

    var seconds: Double {
        switch self {
        case .focus: return 25 * 60
        case .rest: return 5 * 60
        case .demo: return 10
        case .stopwatch: return 0
        }
    }

    var title: String {
        switch self {
        case .focus: return "专注"
        case .rest: return "休息"
        case .demo: return "体验"
        case .stopwatch: return "正计时"
        }
    }
}

enum TimerPhase: Equatable {
    case idle
    case running
    case paused
    case finished
}

/// UI callers use this engine on the main thread. `now` must supply finite,
/// monotonically increasing seconds, for example from a ContinuousClock.
/// No file access, networking, preferences, or timers live in this type.
final class CountdownEngine {
    private(set) var mode: FocusMode = .focus
    private(set) var phase: TimerPhase = .idle
    private(set) var remaining: Double = FocusMode.focus.seconds
    private(set) var deadline: Double?
    private(set) var focusDurationSeconds: Double = FocusMode.focus.seconds

    private let now: () -> Double
    private var stopwatchAccumulated: Double = 0
    private var stopwatchSegmentStart: Double?

    init(now: @escaping () -> Double) {
        self.now = now
    }

    /// Starts an idle round or restarts a finished round. Repeated calls while
    /// running or paused do not create a new deadline or reset the round.
    func start() {
        guard phase == .idle || phase == .finished else { return }
        remaining = durationSeconds
        stopwatchAccumulated = 0
        if mode == .stopwatch {
            stopwatchSegmentStart = now()
            deadline = nil
        } else {
            stopwatchSegmentStart = nil
            deadline = now() + remaining
        }
        phase = .running
    }

    func pause() {
        guard phase == .running else { return }
        if mode == .stopwatch {
            stopwatchAccumulated = elapsedSeconds
            stopwatchSegmentStart = nil
            phase = .paused
            return
        }
        tick()
        guard phase == .running else { return }
        deadline = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        if mode == .stopwatch {
            stopwatchSegmentStart = now()
            phase = .running
            return
        }
        guard remaining > 0 else {
            finish()
            return
        }
        deadline = now() + remaining
        phase = .running
    }

    /// Ends the current round without crediting unspent countdown time.
    /// The caller samples elapsedSeconds before any reset or mode change.
    func stop() {
        guard phase == .running || phase == .paused else { return }
        if mode == .stopwatch {
            stopwatchAccumulated = elapsedSeconds
            stopwatchSegmentStart = nil
        } else if phase == .running {
            tick()
        }
        deadline = nil
        phase = .finished
    }

    func reset() {
        deadline = nil
        stopwatchAccumulated = 0
        stopwatchSegmentStart = nil
        remaining = durationSeconds
        phase = .idle
    }

    func select(_ mode: FocusMode) {
        self.mode = mode
        reset()
    }

    /// Accepts 1–180 minutes, expressed in seconds. Invalid values have no
    /// effect on mode, active time, deadline, state, or the configured duration.
    @discardableResult
    func configureFocus(seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 60, seconds <= 10_800 else { return false }
        focusDurationSeconds = seconds
        select(.focus)
        return true
    }

    var durationSeconds: Double {
        mode == .focus ? focusDurationSeconds : mode.seconds
    }

    /// This counts only the active portions of the round, sampled directly
    /// from the injected monotonic clock even between interface refreshes.
    /// Completed countdowns are capped at the selected duration.
    var elapsedSeconds: Double {
        if mode == .stopwatch {
            guard phase == .running, let start = stopwatchSegmentStart else {
                return stopwatchAccumulated
            }
            return stopwatchAccumulated + max(0, now() - start)
        }
        let secondsLeft: Double
        if phase == .running, let deadline = deadline {
            secondsLeft = min(durationSeconds, max(0, deadline - now()))
        } else {
            secondsLeft = remaining
        }
        return min(durationSeconds, max(0, durationSeconds - secondsLeft))
    }

    /// Only focused countdown and stopwatch sessions contribute to history.
    var isFocusSession: Bool {
        mode == .focus || mode == .stopwatch
    }

    /// Refresh cadence does not determine elapsed time: each refresh compares
    /// the current monotonic instant to the one fixed deadline.
    func tick() {
        guard phase == .running, mode != .stopwatch, let deadline = deadline else { return }
        let secondsLeft = deadline - now()
        if secondsLeft <= 0 {
            finish()
        } else {
            remaining = min(durationSeconds, secondsLeft)
        }
    }

    var display: String {
        // Round upward so a newly started 10-second round does not immediately
        // appear as 00:09, and 00:00 is only shown once the round has finished.
        let wholeSeconds = mode == .stopwatch
            ? Int(floor(max(0, elapsedSeconds)))
            : Int(ceil(max(0, remaining)))
        if wholeSeconds >= 3600 {
            return String(format: "%d:%02d:%02d", wholeSeconds / 3600,
                          (wholeSeconds % 3600) / 60, wholeSeconds % 60)
        }
        return String(format: "%02d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }

    var progress: Double {
        if mode == .stopwatch { return 1 }
        return min(1, max(0, remaining / durationSeconds))
    }

    private func finish() {
        remaining = 0
        deadline = nil
        phase = .finished
    }
}
