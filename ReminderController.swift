import AppKit

// Settings and sequence planning remain independent of audio hardware and UI.
enum ReminderMode: String, Codable, CaseIterable {
    case sound, speech, silent

    var title: String {
        switch self {
        case .sound: return "提示音"
        case .speech: return "语音"
        case .silent: return "静音"
        }
    }
}

enum ReminderError: Error, LocalizedError, Equatable {
    case invalidRepeatCount
    case emptySpeechText
    case speechTextTooLong
    case voiceUnavailable
    case soundUnavailable
    case soundPlaybackFailed
    case speechUnavailable
    case speechPlaybackFailed

    var errorDescription: String? {
        switch self {
        case .invalidRepeatCount: return "提示音次数请设为1至10声。"
        case .emptySpeechText: return "请填写要播报的语音内容。"
        case .speechTextTooLong: return "语音内容最多120个字，请缩短后再试。"
        case .voiceUnavailable: return "所选系统语音当前不可用，请重新选择本机已安装的声音。"
        case .soundUnavailable: return "本机没有可用的系统提示音。请选用语音或静音；不会自动下载声音。"
        case .soundPlaybackFailed: return "系统未能开始播放提示音，请检查声音输出后重试。"
        case .speechUnavailable: return "本机没有可用的系统语音；没有自动下载。"
        case .speechPlaybackFailed: return "系统未能开始语音播报，请换一个已安装声音后重试。"
        }
    }
}

struct ReminderSettings: Codable, Equatable {
    var mode: ReminderMode = .sound
    var repeatCount: Int = 1
    var speechText: String = "这轮专注结束了，起来活动一下。"
    var voiceID: String? = nil

    /// Reject invalid input without silently changing the user's wording.
    func validated() throws -> ReminderSettings {
        guard (1...10).contains(repeatCount) else { throw ReminderError.invalidRepeatCount }
        guard speechText.count <= 120 else { throw ReminderError.speechTextTooLong }
        if mode == .speech && speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ReminderError.emptySpeechText
        }
        return self
    }
}

/// Pure selection rules shared by playback and tests. Resources are resolved
/// on this Mac; a saved voice identifier is never assumed to exist elsewhere.
enum ReminderResourceSelection {
    // Keep the original light chime when installed, then try other built-in
    // sounds. Each candidate is probed through AppKit; no files are downloaded.
    static let preferredSoundNames = [
        "Glass", "Tink", "Pop", "Ping", "Purr", "Blow", "Bottle", "Frog",
        "Funk", "Hero", "Morse", "Sosumi", "Submarine", "Basso"
    ]

    static func firstAvailableSound<Sound>(load: (String) -> Sound?) -> Sound? {
        for name in preferredSoundNames {
            if let sound = load(name) { return sound }
        }
        return nil
    }

    /// Automatic selection follows the installed list (Chinese voices first).
    /// An explicit, now-missing choice is reported instead of silently changed.
    static func voiceCandidates(requested: String?, installedIDs: [String]) throws -> [String] {
        var seen = Set<String>()
        let installed = installedIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !installed.isEmpty else { throw ReminderError.speechUnavailable }
        if let requested {
            guard installed.contains(requested) else { throw ReminderError.voiceUnavailable }
            return [requested]
        }
        return installed
    }
}

/// One cue is consumed for each attempted chime. The controller uses the same
/// plan that the pure tests exercise, so retries cannot accidentally add chimes.
struct ReminderChimePlan {
    private(set) var remaining: Int
    private(set) var emitted: Int = 0

    init(repeatCount: Int) throws {
        guard (1...10).contains(repeatCount) else { throw ReminderError.invalidRepeatCount }
        remaining = repeatCount
    }

    mutating func takeNext() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        emitted += 1
        return true
    }

    mutating func cancel() { remaining = 0 }
}

@MainActor
final class ReminderController: NSObject, NSSpeechSynthesizerDelegate {
    var settings = ReminderSettings()
    let voiceOptions: [(id: String, name: String)]
    private(set) var lastPlaybackError: String?
    private var repeatTimer: Timer?
    private var plan: ReminderChimePlan?
    private var chime: NSSound?
    private var speech: NSSpeechSynthesizer?

    var isPlaying: Bool {
        repeatTimer != nil || chime?.isPlaying == true || speech?.isSpeaking == true
    }

    override init() {
        let voices = NSSpeechSynthesizer.availableVoices.map { voice in
            let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
            let name = attributes[.name] as? String ?? voice.rawValue
            let locale = attributes[.localeIdentifier] as? String ?? ""
            let language = Locale(identifier: "zh_CN").localizedString(forIdentifier: locale) ?? locale
            return (id: voice.rawValue,
                    name: language.isEmpty ? name : "\(name)（\(language)）",
                    isChinese: locale.lowercased().hasPrefix("zh"))
        }.sorted {
            if $0.isChinese != $1.isChinese { return $0.isChinese }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        voiceOptions = voices.map { (id: $0.id, name: $0.name) }
        super.init()
    }

    /// Playback only uses the already available system sound and installed
    /// speech voices. No permission, downloads, network, or file export occurs.
    func play() {
        stop()
        lastPlaybackError = nil
        do {
            let selected = try settings.validated()
            switch selected.mode {
            case .silent: return
            case .sound:
                guard let sound = ReminderResourceSelection.firstAvailableSound(load: {
                    NSSound(named: NSSound.Name($0))
                }) else { throw ReminderError.soundUnavailable }
                chime = sound
                plan = try ReminderChimePlan(repeatCount: selected.repeatCount)
                playNextChime()
                if plan?.remaining ?? 0 > 0, lastPlaybackError == nil {
                    let timer = Timer(timeInterval: 1.0, target: self,
                                      selector: #selector(playNextChime), userInfo: nil, repeats: true)
                    timer.tolerance = 0.03
                    RunLoop.main.add(timer, forMode: .common)
                    repeatTimer = timer
                }
            case .speech:
                let candidates = try ReminderResourceSelection.voiceCandidates(
                    requested: selected.voiceID, installedIDs: voiceOptions.map(\.id))
                // Automatic mode can try the next installed voice when a system
                // voice cannot be initialized. Explicit choices remain explicit.
                let synthesizer = candidates.lazy.compactMap { identifier in
                    NSSpeechSynthesizer(voice: NSSpeechSynthesizer.VoiceName(rawValue: identifier))
                }.first
                guard let synthesizer else { throw ReminderError.speechUnavailable }
                synthesizer.delegate = self
                synthesizer.usesFeedbackWindow = false
                speech = synthesizer
                guard synthesizer.startSpeaking(selected.speechText) else {
                    throw ReminderError.speechPlaybackFailed
                }
            }
        } catch {
            stop()
            lastPlaybackError = error.localizedDescription
        }
    }

    /// Cancels queued repeats as well as any currently playing sound or speech.
    /// It does not change or erase settings and does not touch the focus timer.
    func stop() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        plan?.cancel()
        chime?.stop()
        let previousSpeech = speech
        speech = nil
        previousSpeech?.delegate = nil
        previousSpeech?.stopSpeaking()
    }

    @objc private func playNextChime() {
        guard plan?.takeNext() == true else {
            repeatTimer?.invalidate()
            repeatTimer = nil
            return
        }
        chime?.stop()
        guard chime?.play() == true else {
            stop()
            lastPlaybackError = ReminderError.soundPlaybackFailed.localizedDescription
            return
        }
        if plan?.remaining == 0 {
            repeatTimer?.invalidate()
            repeatTimer = nil
        }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didEncounterErrorAt characterIndex: Int,
                           of string: String, message: String) {
        guard speech === sender else { return }
        stop()
        lastPlaybackError = "系统语音播报中断：\(message)"
    }
}
