import Foundation

private final class ManualClock {
    var time: Double = 100
    func advance(_ seconds: Double) { time += seconds }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class Checks {
    private(set) var assertions = 0
    private(set) var cases = 0

    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw TestFailure(description: message) }
    }

    func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try expect(abs(actual - expected) < 0.000_001, message)
    }

    func run(_ title: String, _ body: () throws -> Void) throws {
        try body()
        cases += 1
        print("PASS \(title)")
    }
}

@main
struct TimerCoreTestRunner {
    static func main() throws {
        let check = Checks()

        func fixture(_ mode: FocusMode = .demo) -> (ManualClock, CountdownEngine) {
            let clock = ManualClock()
            let engine = CountdownEngine(now: { clock.time })
            engine.select(mode)
            return (clock, engine)
        }

        try check.run("default 25-minute idle state") {
            let engine = CountdownEngine(now: { 100 })
            try check.expect(engine.mode == .focus, "Default mode must be focus")
            try check.expect(engine.phase == .idle, "Default state must be idle")
            try check.near(engine.remaining, 1500, "Default duration must be 1500")
            try check.expect(engine.deadline == nil, "Idle round has no deadline")
            try check.expect(engine.display == "25:00", "Default display must be 25:00")
            try check.near(engine.progress, 1, "Default progress must be full")
        }

        try check.run("all countdown presets and stable mode order") {
            let (_, engine) = fixture()
            let cases: [(FocusMode, String, String, Double)] = [
                (.focus, "专注", "25:00", 1500),
                (.rest, "休息", "05:00", 300),
                (.demo, "体验", "00:10", 10)
            ]
            for (mode, title, display, seconds) in cases {
                engine.select(mode)
                try check.expect(engine.mode.title == title, "Mode title mismatch")
                try check.expect(engine.display == display, "Preset display mismatch")
                try check.near(engine.remaining, seconds, "Preset duration mismatch")
                try check.expect(engine.phase == .idle, "Selecting a preset must not start")
            }
            try check.expect(FocusMode.allCases == [.focus, .rest, .demo, .stopwatch],
                             "Keep countdown modes stable and append stopwatch")
        }

        try check.run("start sets one fixed deadline") {
            let (_, engine) = fixture()
            engine.start()
            try check.expect(engine.phase == .running, "Start must run")
            try check.expect(engine.deadline == 110, "Deadline must be now + duration")
            try check.expect(engine.display == "00:10", "Start must retain initial display")
        }

        try check.run("fractional elapsed time and ceil display") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(2.25)
            engine.tick()
            try check.near(engine.remaining, 7.75, "Elapsed time must come from deadline")
            try check.expect(engine.display == "00:08", "Fractional seconds must round upward")
            try check.near(engine.progress, 0.775, "Ring must use actual remaining ratio")
        }

        try check.run("irregular refresh does not accumulate tick error") {
            let (clock, engine) = fixture()
            engine.start()
            for advance in [0.001, 0.009, 2.56, 0.13, 1.3] {
                clock.advance(advance)
                engine.tick()
            }
            try check.near(engine.remaining, 6, "Irregular refresh must preserve real elapsed time")
            try check.expect(engine.deadline == 110, "Tick must not move deadline")
        }

        try check.run("pause captures time even without prior tick") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(2.25)
            engine.pause()
            try check.expect(engine.phase == .paused, "Pause must freeze")
            try check.near(engine.remaining, 7.75, "Pause must refresh the exact remaining value")
            try check.expect(engine.deadline == nil, "Paused round must have no live deadline")
        }

        try check.run("pause remains frozen across long simulated wait") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(3)
            engine.pause()
            clock.advance(3000)
            engine.tick()
            try check.near(engine.remaining, 7, "Paused value changed while waiting")
            try check.expect(engine.display == "00:07", "Paused display drifted")
            try check.near(engine.progress, 0.7, "Paused ring drifted")
        }

        try check.run("resume retains fractional remaining time") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(2.25)
            engine.pause()
            clock.advance(100)
            engine.resume()
            try check.expect(engine.phase == .running, "Resume must run")
            try check.expect(engine.deadline == 210, "Resume deadline must exclude paused wait")
            clock.advance(1.5)
            engine.tick()
            try check.near(engine.remaining, 6.25, "Resume restarted the full duration")
            try check.expect(engine.display == "00:07", "Resumed display mismatch")
        }

        try check.run("exact deadline stops at zero") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(10)
            engine.tick()
            try check.expect(engine.phase == .finished, "Exact deadline must finish")
            try check.near(engine.remaining, 0, "Finished remaining must be zero")
            try check.expect(engine.display == "00:00", "Finished display must be zero")
            try check.near(engine.progress, 0, "Finished ring must be empty")
            try check.expect(engine.deadline == nil, "Finished deadline must be cleared")
        }

        try check.run("large refresh delay never produces negative time or next round") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(86_400)
            engine.tick()
            for _ in 0..<100 { engine.tick() }
            try check.expect(engine.phase == .finished, "Expired round must stay finished")
            try check.expect(engine.mode == .demo, "Expired round must not switch mode")
            try check.expect(engine.display == "00:00", "Expired display must stay zero")
            try check.near(engine.progress, 0, "Expired progress must remain zero")
        }

        try check.run("restart after finishing restores current preset") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(10)
            engine.tick()
            engine.start()
            try check.expect(engine.phase == .running, "Restart must run")
            try check.expect(engine.deadline == 120, "Restart must use a fresh full deadline")
            try check.expect(engine.display == "00:10", "Restart must restore full preset")
            try check.near(engine.progress, 1, "Restart must restore full ring")
        }

        try check.run("running reset is idle and immune to previous deadline") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(3)
            engine.reset()
            clock.advance(100)
            engine.tick()
            try check.expect(engine.phase == .idle, "Reset must stop the round")
            try check.expect(engine.deadline == nil, "Reset must clear deadline")
            try check.expect(engine.display == "00:10", "Old deadline affected reset round")
            try check.near(engine.progress, 1, "Reset must restore full ring")
        }

        try check.run("switching a running mode stops the old round") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(3)
            engine.select(.rest)
            clock.advance(100)
            engine.tick()
            try check.expect(engine.phase == .idle, "Mode switch must not auto-start")
            try check.expect(engine.mode == .rest, "Mode switch did not select rest")
            try check.expect(engine.display == "05:00", "Old round affected new mode")
            try check.expect(engine.deadline == nil, "Mode switch must clear deadline")
        }

        try check.run("switching a paused mode is a clean idle round") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(3)
            engine.pause()
            engine.select(.focus)
            engine.resume()
            try check.expect(engine.phase == .idle, "Resume must not activate freshly selected mode")
            try check.expect(engine.display == "25:00", "Paused state leaked into selected focus")
            try check.expect(engine.deadline == nil, "Selected focus must have no deadline")
        }

        try check.run("repeated start never extends an active round") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(3)
            for _ in 0..<100 { engine.start() }
            engine.tick()
            try check.expect(engine.deadline == 110, "Repeated start moved deadline")
            try check.near(engine.remaining, 7, "Repeated start reset remaining time")
            clock.advance(7)
            engine.tick()
            try check.expect(engine.phase == .finished, "Repeated start extended the round")
        }

        try check.run("repeated resume never extends an active round") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(3)
            engine.pause()
            clock.advance(3)
            engine.resume()
            clock.advance(2)
            for _ in 0..<100 { engine.resume() }
            engine.tick()
            try check.expect(engine.deadline == 113, "Repeated resume moved deadline")
            try check.near(engine.remaining, 5, "Repeated resume reset remaining time")
        }

        try check.run("start cannot accidentally restart a paused round") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(3)
            engine.pause()
            engine.start()
            try check.expect(engine.phase == .paused, "Start must not bypass paused state")
            try check.near(engine.remaining, 7, "Start reset paused value")
            try check.expect(engine.deadline == nil, "Start created paused deadline")
        }

        try check.run("pause at the deadline finishes instead of freezing zero") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(10)
            engine.pause()
            try check.expect(engine.phase == .finished, "Pause at deadline must finish")
            try check.expect(engine.display == "00:00", "Pause at deadline must show zero")
            try check.expect(engine.deadline == nil, "Pause at deadline must clear deadline")
        }

        try check.run("last fractional second is shown until real expiry") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(9.999)
            engine.tick()
            try check.expect(engine.phase == .running, "Fractional time should still be running")
            try check.expect(engine.display == "00:01", "Do not show zero before real expiry")
            try check.expect(engine.progress > 0, "Fractional progress should remain positive")
            clock.advance(0.001)
            engine.tick()
            try check.expect(engine.phase == .finished, "Final fractional time failed to expire")
        }

        try check.run("selecting the same running preset still resets and stops") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(3)
            engine.select(.demo)
            try check.expect(engine.phase == .idle, "Same preset selection must stop")
            try check.expect(engine.display == "00:10", "Same preset selection must reset")
            try check.expect(engine.deadline == nil, "Same preset selection left an old deadline")
        }

        try check.run("reset finished round retains preset without auto-start") {
            let (clock, engine) = fixture(.rest)
            engine.start()
            clock.advance(300)
            engine.tick()
            engine.reset()
            try check.expect(engine.mode == .rest, "Reset must retain selected preset")
            try check.expect(engine.phase == .idle, "Reset must remain idle")
            try check.expect(engine.display == "05:00", "Reset must restore rest duration")
        }

        try check.run("idle and repeated paused actions are harmless") {
            let (clock, engine) = fixture()
            engine.pause()
            engine.resume()
            clock.advance(500)
            engine.tick()
            try check.expect(engine.phase == .idle, "Idle actions unexpectedly started a round")
            try check.expect(engine.display == "00:10", "Idle actions changed duration")
            engine.start()
            clock.advance(2)
            engine.pause()
            clock.advance(500)
            engine.pause()
            try check.expect(engine.phase == .paused, "Repeated pause changed state")
            try check.near(engine.remaining, 8, "Repeated pause changed remaining time")
        }

        try check.run("stopwatch starts from idle zero without a deadline") {
            let (_, engine) = fixture(.stopwatch)
            try check.expect(engine.mode.title == "正计时", "Stopwatch title mismatch")
            try check.expect(engine.phase == .idle, "Stopwatch must start idle")
            try check.expect(engine.display == "00:00", "Stopwatch must start at zero")
            try check.near(engine.elapsedSeconds, 0, "Idle stopwatch must have no elapsed time")
            try check.near(engine.durationSeconds, 0, "Stopwatch must not have a countdown duration")
            try check.near(engine.progress, 1, "Stopwatch progress is a fixed visual state")
            engine.start()
            try check.expect(engine.phase == .running, "Stopwatch start must run")
            try check.expect(engine.deadline == nil, "Stopwatch must not create a deadline")
        }

        try check.run("stopwatch samples fractional elapsed time between ticks") {
            let (clock, engine) = fixture(.stopwatch)
            engine.start()
            clock.advance(0.75)
            try check.near(engine.elapsedSeconds, 0.75, "History sample must not wait for UI tick")
            try check.expect(engine.display == "00:00", "Stopwatch displays completed seconds")
            clock.advance(1.5)
            engine.tick()
            try check.near(engine.elapsedSeconds, 2.25, "Stopwatch must use actual monotonic time")
            try check.expect(engine.display == "00:02", "Stopwatch display rounded incorrectly")
        }

        try check.run("stopwatch pause excludes a long simulated wait") {
            let (clock, engine) = fixture(.stopwatch)
            engine.start()
            clock.advance(2.75)
            engine.pause()
            clock.advance(3000)
            engine.tick()
            try check.expect(engine.phase == .paused, "Stopwatch must remain paused")
            try check.near(engine.elapsedSeconds, 2.75, "Paused stopwatch accrued wait time")
            try check.expect(engine.display == "00:02", "Paused stopwatch display drifted")
            engine.resume()
            clock.advance(1.5)
            try check.near(engine.elapsedSeconds, 4.25, "Resume lost fractional seconds")
            try check.expect(engine.display == "00:04", "Resumed stopwatch display mismatch")
        }

        try check.run("stopwatch repeated starts and resumes never double-count") {
            let (clock, engine) = fixture(.stopwatch)
            engine.start()
            clock.advance(1.125)
            for _ in 0..<100 {
                engine.start()
                engine.resume()
            }
            clock.advance(1.125)
            try check.near(engine.elapsedSeconds, 2.25, "Repeated actions changed active segment")
            engine.pause()
            clock.advance(10)
            engine.pause()
            engine.start()
            try check.near(engine.elapsedSeconds, 2.25, "Repeated pause/start changed saved elapsed")
            try check.expect(engine.phase == .paused, "Start must not bypass stopwatch pause")
        }

        try check.run("stopwatch stop captures exact elapsed and freezes final state") {
            let (clock, engine) = fixture(.stopwatch)
            engine.start()
            clock.advance(10.125)
            engine.stop()
            clock.advance(100)
            engine.tick()
            engine.resume()
            try check.expect(engine.phase == .finished, "Stop must finish stopwatch")
            try check.near(engine.elapsedSeconds, 10.125, "Stop must preserve exact active time")
            try check.expect(engine.display == "00:10", "Stopped stopwatch display mismatch")
            try check.expect(engine.deadline == nil, "Stopped stopwatch must have no deadline")
        }

        try check.run("stopwatch stop while paused preserves saved fractional time") {
            let (clock, engine) = fixture(.stopwatch)
            engine.start()
            clock.advance(3.625)
            engine.pause()
            clock.advance(100)
            engine.stop()
            try check.expect(engine.phase == .finished, "Stop paused stopwatch must finish")
            try check.near(engine.elapsedSeconds, 3.625, "Stop included paused wait time")
        }

        try check.run("stopwatch restart begins a new zero elapsed round") {
            let (clock, engine) = fixture(.stopwatch)
            engine.start()
            clock.advance(3.5)
            engine.stop()
            let previousRound = engine.elapsedSeconds
            engine.start()
            try check.near(previousRound, 3.5, "Caller must be able to sample prior round")
            try check.near(engine.elapsedSeconds, 0, "Restart must clear old elapsed time")
            try check.expect(engine.display == "00:00", "Restart must display zero")
            clock.advance(1.25)
            try check.near(engine.elapsedSeconds, 1.25, "New round inherited old elapsed")
        }

        try check.run("stopwatch reset stops and clears all elapsed time") {
            let (clock, engine) = fixture(.stopwatch)
            engine.start()
            clock.advance(4.5)
            let sampledBeforeReset = engine.elapsedSeconds
            engine.reset()
            clock.advance(100)
            engine.tick()
            try check.near(sampledBeforeReset, 4.5, "Pre-reset history sample must be current")
            try check.expect(engine.phase == .idle, "Reset stopwatch must remain idle")
            try check.near(engine.elapsedSeconds, 0, "Reset stopwatch must stay at zero")
            try check.expect(engine.display == "00:00", "Reset stopwatch display mismatch")
        }

        try check.run("mode switch separates stopwatch time from new round") {
            let (clock, engine) = fixture(.stopwatch)
            engine.start()
            clock.advance(3.375)
            let sampledBeforeSwitch = engine.elapsedSeconds
            engine.select(.rest)
            clock.advance(100)
            engine.tick()
            try check.near(sampledBeforeSwitch, 3.375, "Pre-switch sample must preserve fraction")
            try check.expect(engine.phase == .idle, "Switch must stop stopwatch")
            try check.expect(engine.display == "05:00", "Rest duration must remain unchanged")
            try check.near(engine.elapsedSeconds, 0, "New mode inherited stopwatch elapsed")
        }

        try check.run("long stopwatch display keeps hours instead of wrapping") {
            let (clock, engine) = fixture(.stopwatch)
            engine.start()
            clock.advance(3599.9)
            try check.expect(engine.display == "59:59", "Sub-hour display must remain mm:ss")
            clock.advance(0.1)
            try check.expect(engine.display == "1:00:00", "Hour boundary display mismatch")
            clock.advance(61.9)
            try check.expect(engine.display == "1:01:01", "Long display must include hours")
            clock.advance(24 * 3600)
            try check.expect(engine.display == "25:01:01", "Elapsed time must not wrap at 24 hours")
            try check.near(engine.progress, 1, "Long stopwatch visual state changed")
        }

        try check.run("custom 30-minute focus configuration resets into idle focus") {
            let (clock, engine) = fixture(.rest)
            engine.start()
            clock.advance(2.25)
            let previousElapsed = engine.elapsedSeconds
            try check.expect(engine.configureFocus(seconds: 1800), "30-minute configuration must succeed")
            try check.near(previousElapsed, 2.25, "Caller must sample old active time before config")
            try check.expect(engine.mode == .focus, "Config must select focus")
            try check.expect(engine.phase == .idle, "Config must not auto-start")
            try check.near(engine.focusDurationSeconds, 1800, "Configured focus duration mismatch")
            try check.near(engine.durationSeconds, 1800, "Current duration must use focus configuration")
            try check.expect(engine.display == "30:00", "Configured display must be 30:00")
            try check.near(engine.elapsedSeconds, 0, "Config must start a clean round")
            engine.start()
            try check.expect(engine.deadline == 1902.25, "Configured deadline mismatch")
        }

        try check.run("invalid configuration leaves active countdown entirely unchanged") {
            let (clock, engine) = fixture(.focus)
            _ = engine.configureFocus(seconds: 1800)
            engine.start()
            clock.advance(10.5)
            engine.tick()
            let originalDeadline = engine.deadline
            let originalRemaining = engine.remaining
            let invalid: [Double] = [-1, 0, 59.999, 10800.001, .infinity, -.infinity, .nan]
            for value in invalid {
                try check.expect(!engine.configureFocus(seconds: value), "Invalid configuration accepted")
                try check.expect(engine.mode == .focus && engine.phase == .running,
                                 "Invalid configuration changed active mode or phase")
                try check.expect(engine.deadline == originalDeadline, "Invalid configuration changed deadline")
                try check.near(engine.focusDurationSeconds, 1800, "Invalid configuration changed stored duration")
                try check.near(engine.remaining, originalRemaining, "Invalid configuration changed remaining")
                try check.near(engine.elapsedSeconds, 10.5, "Invalid configuration changed elapsed")
            }
        }

        try check.run("focus configuration accepts only inclusive 1-to-180-minute range") {
            let (_, engine) = fixture()
            try check.expect(engine.configureFocus(seconds: 60), "One-minute lower bound must be accepted")
            try check.expect(engine.display == "01:00", "One-minute display mismatch")
            try check.expect(engine.configureFocus(seconds: 10800), "Three-hour upper bound must be accepted")
            try check.expect(engine.display == "3:00:00", "Three-hour countdown display mismatch")
            try check.near(engine.durationSeconds, 10800, "Upper-bound duration mismatch")
        }

        try check.run("configured focus persists in memory across mode changes and resets") {
            let (_, engine) = fixture()
            _ = engine.configureFocus(seconds: 1800)
            engine.select(.demo)
            try check.expect(engine.display == "00:10", "Configuration changed demo preset")
            engine.select(.rest)
            try check.expect(engine.display == "05:00", "Configuration changed rest preset")
            engine.select(.focus)
            engine.reset()
            try check.expect(engine.display == "30:00", "Focus selection lost custom duration")
            try check.near(engine.focusDurationSeconds, 1800, "Reset changed configured duration")
        }

        try check.run("countdown elapsed sample is current even without an interface tick") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(2.625)
            try check.near(engine.elapsedSeconds, 2.625, "History sample must not lag UI refresh")
            engine.pause()
            clock.advance(100)
            try check.near(engine.elapsedSeconds, 2.625, "Paused countdown history accrued wait time")
            engine.resume()
            clock.advance(1.125)
            try check.near(engine.elapsedSeconds, 3.75, "Countdown resume history lost fractional time")
        }

        try check.run("overdue countdown history caps at the planned duration") {
            let (clock, engine) = fixture(.focus)
            _ = engine.configureFocus(seconds: 1800)
            engine.start()
            clock.advance(2000)
            try check.near(engine.elapsedSeconds, 1800, "Overdue history credited extra time before tick")
            engine.tick()
            try check.expect(engine.phase == .finished, "Overdue configured countdown must finish")
            try check.near(engine.elapsedSeconds, 1800, "Finished history exceeded planned duration")
            try check.expect(engine.remaining == 0, "Natural completion must reach zero for sound gate")
        }

        try check.run("early countdown stop preserves only actual active time") {
            let (clock, engine) = fixture()
            engine.start()
            clock.advance(2.375)
            engine.stop()
            clock.advance(100)
            try check.expect(engine.phase == .finished, "Early stop must finish current round")
            try check.near(engine.elapsedSeconds, 2.375, "Early stop credited unspent time")
            try check.near(engine.remaining, 7.625, "Early stop must retain unspent remainder")
            try check.expect(engine.deadline == nil, "Early stop left active deadline")
            engine.start()
            try check.near(engine.elapsedSeconds, 0, "Restart must begin a clean countdown round")
        }

        try check.run("only focus and stopwatch sessions contribute to focus history") {
            let (_, engine) = fixture()
            for mode in FocusMode.allCases {
                engine.select(mode)
                try check.expect(engine.isFocusSession == (mode == .focus || mode == .stopwatch),
                                 "Focus-history classification mismatch")
            }
        }

        print("TimerCore: \(check.cases) cases, \(check.assertions) assertions passed.")
    }
}
