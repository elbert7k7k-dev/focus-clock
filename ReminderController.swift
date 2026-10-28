import AppKit
import AVFoundation

// This data model stays independent of audio hardware and UI.
enum ReminderMode: String, Codable, CaseIterable {
    case sound, custom, speech, silent

    var title: String {
        switch self {
        case .sound: return "闹钟"
        case .custom: return "自定义音乐"
        case .speech: return "语音"
        case .silent: return "静音"
        }
    }
}

enum ReminderError: Error, LocalizedError, Equatable {
    case invalidRepeatCount
    case invalidVolume
    case emptySpeechText
    case speechTextTooLong
    case voiceUnavailable
    case soundUnavailable
    case soundPlaybackFailed
    case speechUnavailable
    case speechPlaybackFailed
    case customAudioMissing
    case invalidCustomFileName
    case customAudioUnavailable
    case customAudioPlaybackFailed

    var errorDescription: String? {
        switch self {
        case .invalidRepeatCount: return "闹钟次数请设为1至10声。"
        case .invalidVolume: return "应用内音量请设为0至100%。"
        case .emptySpeechText: return "请填写要播报的语音内容。"
        case .speechTextTooLong: return "语音内容最多120个字，请缩短后再试。"
        case .voiceUnavailable: return "所选系统语音当前不可用，请重新选择本机已安装的声音。"
        case .soundUnavailable: return "无法准备内置闹钟音，请重新启动工具后重试。"
        case .soundPlaybackFailed: return "系统未能播放闹钟音，请检查声音输出后重试。"
        case .speechUnavailable: return "本机没有可用的系统语音；没有自动下载。"
        case .speechPlaybackFailed: return "系统未能开始语音播报，请换一个已安装声音后重试。"
        case .customAudioMissing: return "请先选择或拖入一首到点提醒音乐。"
        case .invalidCustomFileName: return "保存的提醒音乐标识无效，请重新添加音乐。"
        case .customAudioUnavailable: return "提醒音乐已丢失或不可读取，请重新添加本地音频。"
        case .customAudioPlaybackFailed: return "提醒音乐无法解码或播放，请换一首本地音频后重试。"
        }
    }
}

struct ReminderSettings: Codable, Equatable {
    var mode: ReminderMode = .sound
    var repeatCount: Int = 1
    var speechText: String = "这轮专注结束了，起来活动一下。"
    var voiceID: String? = nil
    var volume: Double = 0.85
    // Only an application-owned file identifier is persisted, never the source path.
    var customAudioFileName: String? = nil
    var customAudioTitle: String? = nil

    enum CodingKeys: String, CodingKey {
        case mode, repeatCount, speechText, voiceID, volume, customAudioFileName, customAudioTitle
    }

    init(mode: ReminderMode = .sound, repeatCount: Int = 1,
         speechText: String = "这轮专注结束了，起来活动一下。", voiceID: String? = nil,
         volume: Double = 0.85, customAudioFileName: String? = nil,
         customAudioTitle: String? = nil) {
        self.mode = mode
        self.repeatCount = repeatCount
        self.speechText = speechText
        self.voiceID = voiceID
        self.volume = volume
        self.customAudioFileName = customAudioFileName
        self.customAudioTitle = customAudioTitle
    }

    /// Decode existing 1.0 preferences without erasing their mode, count or wording.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(ReminderMode.self, forKey: .mode) ?? .sound
        repeatCount = try values.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        speechText = try values.decodeIfPresent(String.self, forKey: .speechText)
            ?? "这轮专注结束了，起来活动一下。"
        voiceID = try values.decodeIfPresent(String.self, forKey: .voiceID)
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 0.85
        customAudioFileName = try values.decodeIfPresent(String.self, forKey: .customAudioFileName)
        customAudioTitle = try values.decodeIfPresent(String.self, forKey: .customAudioTitle)
    }

    /// Reject invalid input without silently changing user choices.
    func validated() throws -> ReminderSettings {
        guard (1...10).contains(repeatCount) else { throw ReminderError.invalidRepeatCount }
        guard volume.isFinite, (0...1).contains(volume) else { throw ReminderError.invalidVolume }
        guard speechText.count <= 120 else { throw ReminderError.speechTextTooLong }
        if mode == .speech && speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ReminderError.emptySpeechText
        }
        if let file = customAudioFileName {
            guard !file.isEmpty, file != ".", file != "..", !file.contains("/"),
                  !file.contains("\\"), !file.contains("\0") else {
                throw ReminderError.invalidCustomFileName
            }
        }
        if mode == .custom && customAudioFileName == nil { throw ReminderError.customAudioMissing }
        return self
    }
}

/// Installed speech resource selection is shared with the pure tests.
enum ReminderResourceSelection {
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

/// Each completion consumes exactly one cue. There is no wall-clock repeat timer
/// which could cut a cue short or emit another after cancellation.
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

/// One clear bell strike with a short natural tail and silent gap. The 16-bit
/// PCM waveform is bounded below full scale, requires no downloaded sound and
/// is generated in memory rather than written into a user's folder.
enum ReminderBell {
    static let sampleRate = 44_100
    static let duration = 0.9
    static let samples: [Int16] = (0..<Int(Double(sampleRate) * duration)).map { index in
        let time = Double(index) / Double(sampleRate)
        guard time < 0.70 else { return 0 }
        let attack = min(1, time / 0.008)
        let release = min(1, (0.70 - time) / 0.030)
        let envelope = attack * release * exp(-2.8 * time)
        let tone = 0.66 * sin(2 * Double.pi * 1480 * time)
            + 0.27 * sin(2 * Double.pi * 1960 * time)
            + 0.07 * sin(2 * Double.pi * 2960 * time)
        return Int16((0.94 * envelope * tone * Double(Int16.max)).rounded())
    }

    static let wavData: Data = {
        let bytes = UInt32(samples.count * 2)
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); u32(36 + bytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(bytes)
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return data
    }()
}

/// Retains a delegate's player until its queued main-thread callback is checked.
/// No player properties are read off the main actor. Retaining the reference
/// also prevents an old callback from matching a newly allocated player's address.
private struct ReminderAudioCallbackReference: @unchecked Sendable {
    let player: AVAudioPlayer
}

@MainActor
final class ReminderController: NSObject, NSSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var settings = ReminderSettings()
    /// Resolved by the application from its own audio library before playback.
    var customAudioURL: URL?
    var onPlaybackStateChanged: ((Bool) -> Void)?
    let voiceOptions: [(id: String, name: String)]
    private(set) var lastPlaybackError: String?
    private(set) var isPlaying = false
    private var plan: ReminderChimePlan?
    private var audio: AVAudioPlayer?
    private var speech: NSSpeechSynthesizer?

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

    func play() {
        stop()
        lastPlaybackError = nil
        do {
            let selected = try settings.validated()
            switch selected.mode {
            case .silent: return
            case .sound:
                let player: AVAudioPlayer
                do { player = try AVAudioPlayer(data: ReminderBell.wavData) }
                catch { throw ReminderError.soundUnavailable }
                audio = player
                player.delegate = self
                player.volume = Float(selected.volume)
                player.numberOfLoops = 0
                plan = try ReminderChimePlan(repeatCount: selected.repeatCount)
                try playNextChime()
            case .custom:
                guard let url = customAudioURL, url.isFileURL,
                      url.lastPathComponent == selected.customAudioFileName,
                      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      attrs[.type] as? FileAttributeType == .typeRegular else {
                    throw ReminderError.customAudioUnavailable
                }
                let player: AVAudioPlayer
                do { player = try AVAudioPlayer(contentsOf: url) }
                catch { throw ReminderError.customAudioPlaybackFailed }
                guard player.duration.isFinite, player.duration > 0 else {
                    throw ReminderError.customAudioPlaybackFailed
                }
                audio = player
                player.delegate = self
                player.volume = Float(selected.volume)
                player.numberOfLoops = 0
                guard player.prepareToPlay(), player.play() else {
                    throw ReminderError.customAudioPlaybackFailed
                }
                setPlaying(true)
            case .speech:
                let candidates = try ReminderResourceSelection.voiceCandidates(
                    requested: selected.voiceID, installedIDs: voiceOptions.map(\.id))
                let synthesizer = candidates.lazy.compactMap { identifier in
                    NSSpeechSynthesizer(voice: NSSpeechSynthesizer.VoiceName(rawValue: identifier))
                }.first
                guard let synthesizer else { throw ReminderError.speechUnavailable }
                synthesizer.delegate = self
                synthesizer.usesFeedbackWindow = false
                synthesizer.volume = Float(selected.volume)
                speech = synthesizer
                guard synthesizer.startSpeaking(selected.speechText) else {
                    throw ReminderError.speechPlaybackFailed
                }
                setPlaying(true)
            }
        } catch { fail(error.localizedDescription) }
    }

    /// Cancels the player/delegate before notifying the app, so a later callback
    /// from an old cue cannot restart playback or unduck the wrong session.
    func stop() {
        plan?.cancel()
        plan = nil
        let oldAudio = audio
        audio = nil
        oldAudio?.delegate = nil
        oldAudio?.stop()
        let oldSpeech = speech
        speech = nil
        oldSpeech?.delegate = nil
        oldSpeech?.stopSpeaking()
        setPlaying(false)
    }

    private func setPlaying(_ value: Bool) {
        guard isPlaying != value else { return }
        isPlaying = value
        onPlaybackStateChanged?(value)
    }

    private func fail(_ message: String) {
        stop()
        lastPlaybackError = message
    }

    private func playNextChime() throws {
        guard plan?.takeNext() == true else { stop(); return }
        guard let player = audio else { throw ReminderError.soundUnavailable }
        player.currentTime = 0
        guard player.prepareToPlay(), player.play() else { throw ReminderError.soundPlaybackFailed }
        setPlaying(true)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let reference = ReminderAudioCallbackReference(player: player)
        DispatchQueue.main.async { [weak self] in self?.finishAudio(reference.player, successfully: flag) }
    }

    private func finishAudio(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard audio === player else { return }
        guard flag else {
            fail(settings.mode == .custom ? ReminderError.customAudioPlaybackFailed.localizedDescription
                 : ReminderError.soundPlaybackFailed.localizedDescription)
            return
        }
        if plan?.remaining ?? 0 > 0 {
            do { try playNextChime() } catch { fail(error.localizedDescription) }
        } else { stop() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let reference = ReminderAudioCallbackReference(player: player)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.audio === reference.player else { return }
            self.fail(self.settings.mode == .custom ? ReminderError.customAudioPlaybackFailed.localizedDescription
                      : ReminderError.soundPlaybackFailed.localizedDescription)
        }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        guard speech === sender else { return }
        if finishedSpeaking { stop() }
        else { fail("系统语音播报中断，请检查输出后重试。") }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didEncounterErrorAt characterIndex: Int,
                           of string: String, message: String) {
        guard speech === sender else { return }
        fail("系统语音播报中断：\(message)")
    }
}
