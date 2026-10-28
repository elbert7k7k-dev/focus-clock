import Foundation

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
    func rejects(_ action: () throws -> Void, _ message: String) throws {
        assertions += 1
        do { try action() } catch { return }
        throw TestFailure(description: message)
    }
    func run(_ title: String, _ body: () throws -> Void) throws {
        try body()
        cases += 1
        print("PASS \(title)")
    }
}

@main
private struct ReminderTestRunner {
    static func main() throws {
        let check = Checks()
        try check.run("default is one chime with valid speech wording") {
            let value = try ReminderSettings().validated()
            try check.expect(value.mode == .sound && value.repeatCount == 1, "Default must be one chime")
            try check.expect(value.speechText == "这轮专注结束了，起来活动一下。", "Default must use generic wording")
            try check.expect(value.voiceID == nil, "Default uses an available voice without a fixed machine ID")
        }
        try check.run("all allowed chime counts produce exactly that many cues") {
            for count in 1...10 {
                var value = ReminderSettings()
                value.repeatCount = count
                _ = try value.validated()
                var plan = try ReminderChimePlan(repeatCount: count)
                for _ in 0..<count { try check.expect(plan.takeNext(), "Missing cue") }
                try check.expect(!plan.takeNext(), "Unexpected extra cue")
                try check.expect(!plan.takeNext(), "Exhausted plan must stay exhausted")
                try check.expect(plan.remaining == 0 && plan.emitted == count, "Cue accounting mismatch")
            }
        }
        try check.run("invalid chime counts fail without clamping") {
            for count in [Int.min, -1, 0, 11, Int.max] {
                var value = ReminderSettings()
                value.repeatCount = count
                try check.rejects({ _ = try value.validated() }, "Invalid settings count accepted")
                try check.rejects({ _ = try ReminderChimePlan(repeatCount: count) }, "Invalid plan count accepted")
            }
        }
        try check.run("cancellation prevents every remaining cue") {
            var plan = try ReminderChimePlan(repeatCount: 4)
            try check.expect(plan.takeNext(), "First cue missing")
            plan.cancel()
            try check.expect(!plan.takeNext() && plan.remaining == 0, "Cancellation left a queued cue")
            try check.expect(plan.emitted == 1, "Cancellation must not pretend to emit queued cues")
            plan.cancel()
            try check.expect(!plan.takeNext(), "Cancellation is idempotent")
        }
        try check.run("new plan starts independently after replacement") {
            var old = try ReminderChimePlan(repeatCount: 10)
            _ = old.takeNext()
            old.cancel()
            var replacement = try ReminderChimePlan(repeatCount: 2)
            try check.expect(replacement.takeNext() && replacement.takeNext(), "Replacement missing cues")
            try check.expect(!replacement.takeNext(), "Replacement inherited an old queued cue")
            try check.expect(!old.takeNext(), "Old plan revived")
        }
        try check.run("speech mode rejects blank and whitespace-only content") {
            for content in ["", " ", "\n\t　"] {
                var value = ReminderSettings()
                value.mode = .speech
                value.speechText = content
                try check.rejects({ _ = try value.validated() }, "Empty speech accepted")
            }
        }
        try check.run("one to 120 characters are preserved verbatim") {
            for content in ["休", "  起来活动一下。  ", String(repeating: "注", count: 120), "⏰专注结束"] {
                var value = ReminderSettings()
                value.mode = .speech
                value.speechText = content
                let validated = try value.validated()
                try check.expect(validated.speechText == content, "Speech wording was changed")
            }
        }
        try check.run("overlong text is rejected without truncation") {
            var value = ReminderSettings()
            value.mode = .speech
            value.speechText = String(repeating: "注", count: 121)
            try check.rejects({ _ = try value.validated() }, "Overlong wording accepted")
            try check.expect(value.speechText.count == 121, "Validation silently truncated text")
        }
        try check.run("sound and silent modes do not require speech content") {
            for mode in [ReminderMode.sound, .silent] {
                var value = ReminderSettings()
                value.mode = mode
                value.speechText = ""
                let validated = try value.validated()
                try check.expect(validated.mode == mode && validated.speechText.isEmpty, "Unused speech blocked mode")
            }
        }
        try check.run("JSON round trip retains selected mode count text and voice") {
            var value = ReminderSettings()
            value.mode = .speech
            value.repeatCount = 7
            value.speechText = "专注完成，请休息一会儿。"
            value.voiceID = "installed-voice-id-for-test"
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ReminderSettings.self, from: encoded)
            try check.expect(decoded == value, "Settings round trip lost fields")
            _ = try decoded.validated()
        }
        try check.run("unsupported JSON mode is rejected") {
            let data = Data(#"{"mode":"unknown","repeatCount":1,"speechText":"完成"}"#.utf8)
            try check.rejects({ _ = try JSONDecoder().decode(ReminderSettings.self, from: data) }, "Unknown mode accepted")
        }
        try check.run("original chime is used only when actually available") {
            var probes: [String] = []
            let sound: String? = ReminderResourceSelection.firstAvailableSound { name in
                probes.append(name)
                return name == "Glass" ? "loaded-original" : nil
            }
            try check.expect(sound == "loaded-original", "Installed original chime was not selected")
            try check.expect(probes == ["Glass"], "Successful selection should stop probing")
        }
        try check.run("missing original chime falls back to an installed system sound") {
            var probes: [String] = []
            let sound: String? = ReminderResourceSelection.firstAvailableSound { name in
                probes.append(name)
                return name == "Tink" ? "loaded-fallback" : nil
            }
            try check.expect(sound == "loaded-fallback", "Missing original chime blocked fallback")
            try check.expect(probes == ["Glass", "Tink"], "Fallback preference order was not followed")
        }
        try check.run("no installed sound returns no fabricated or downloaded resource") {
            var probes: [String] = []
            let sound: String? = ReminderResourceSelection.firstAvailableSound { name in
                probes.append(name)
                return nil
            }
            try check.expect(sound == nil, "Missing resources produced a fabricated sound")
            try check.expect(probes == ReminderResourceSelection.preferredSoundNames, "Candidates were not checked exactly once")
            try check.expect(Set(probes).count == probes.count, "Sound candidates contain duplicates")
        }
        try check.run("automatic voice uses installed priority and preserves fallback candidates") {
            let ids = try ReminderResourceSelection.voiceCandidates(
                requested: nil, installedIDs: ["installed-Chinese", "installed-English"])
            try check.expect(ids == ["installed-Chinese", "installed-English"], "Installed preference order changed")
        }
        try check.run("explicit installed voice remains the only choice") {
            let ids = try ReminderResourceSelection.voiceCandidates(
                requested: "installed-English", installedIDs: ["installed-Chinese", "installed-English"])
            try check.expect(ids == ["installed-English"], "An explicit voice was silently changed")
        }
        try check.run("saved voice absent from this Mac produces a clear selection error") {
            do {
                _ = try ReminderResourceSelection.voiceCandidates(
                    requested: "other-Mac-voice", installedIDs: ["installed-Chinese"])
                throw TestFailure(description: "Absent voice was accepted")
            } catch let error as ReminderError {
                try check.expect(error == .voiceUnavailable, "Wrong missing-voice error")
            }
        }
        try check.run("no installed voices produces a clear availability error") {
            for requested in [nil, "old-voice"] as [String?] {
                do {
                    _ = try ReminderResourceSelection.voiceCandidates(requested: requested, installedIDs: [])
                    throw TestFailure(description: "Empty voice list was accepted")
                } catch let error as ReminderError {
                    try check.expect(error == .speechUnavailable, "Wrong empty-voice error")
                }
            }
        }
        try check.run("empty or duplicate voice IDs cannot become fallback candidates") {
            let ids = try ReminderResourceSelection.voiceCandidates(
                requested: nil, installedIDs: ["", "installed-A", "installed-A", "installed-B"])
            try check.expect(ids == ["installed-A", "installed-B"], "Invalid or duplicate voice IDs survived")
            do {
                _ = try ReminderResourceSelection.voiceCandidates(requested: nil, installedIDs: ["", ""])
                throw TestFailure(description: "Only-empty voice list was accepted")
            } catch let error as ReminderError {
                try check.expect(error == .speechUnavailable, "Wrong error for empty IDs")
            }
        }
        print("RESULT \(check.cases) cases, \(check.assertions) assertions passed; no audio controller instantiated or playback performed")
    }
}
