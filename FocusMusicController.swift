import AppKit
import AVFoundation

// A callback retains its exact player until processed on the main queue;
// stale delegates cannot affect a replacement player or reuse an object ID.
private final class MusicCallbackReference: @unchecked Sendable {
    let player: AVAudioPlayer
    init(_ player: AVAudioPlayer) { self.player = player }
}

/// A single local player: loading the library never starts audio. The timer
/// and history do not depend on this controller or on music playback time.
@MainActor
final class FocusMusicController: NSObject, AVAudioPlayerDelegate {
    var resolveURL: ((String) throws -> URL)?
    var onChange: (() -> Void)?
    private(set) var playlistID: UUID?
    private(set) var tracks: [LibraryTrack] = []
    private(set) var currentIndex: Int?
    private(set) var lastError: String?
    private var player: AVAudioPlayer?
    var volume: Double = 0.35 { didSet { applyVolume() } }
    var isDucked = false { didSet { applyVolume() } }
    var loopMode: MusicLoopMode = .playlist {
        didSet { player?.numberOfLoops = loopMode == .single ? -1 : 0 }
    }
    var isPlaying: Bool { player?.isPlaying == true }
    var currentTrack: LibraryTrack? {
        guard let index = currentIndex, tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }
    var elapsed: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    func loadPlaylist(_ playlist: FocusPlaylist?) {
        let previousTrack = currentTrack?.id
        if playlistID != playlist?.id { stop(); currentIndex = nil }
        playlistID = playlist?.id
        tracks = playlist?.tracks ?? []
        if let previousTrack, let index = tracks.firstIndex(where: { $0.id == previousTrack }) {
            currentIndex = index
        } else if player != nil {
            stop(); currentIndex = nil
        }
        onChange?()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }
    func play() {
        lastError = nil
        if let player {
            guard player.play() else { fail("音乐未能播放，请检查音频文件和声音输出。"); return }
            onChange?()
        } else if !tracks.isEmpty {
            playTrack(at: currentIndex ?? 0)
        } else {
            fail("请先载入本机音乐。")
        }
    }
    func playTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        stop()
        currentIndex = index
        do {
            guard let resolveURL else { throw MusicError.unavailable }
            let next = try AVAudioPlayer(contentsOf: resolveURL(tracks[index].fileName))
            guard next.duration.isFinite, next.duration > 0, next.prepareToPlay() else {
                throw MusicError.unavailable
            }
            next.delegate = self
            next.numberOfLoops = loopMode == .single ? -1 : 0
            player = next
            applyVolume()
            guard next.play() else { throw MusicError.unavailable }
            lastError = nil
            onChange?()
        } catch { fail("无法播放“\(tracks[index].title)”：\(error.localizedDescription)") }
    }
    func pause() { player?.pause(); onChange?() }
    func stop() {
        player?.delegate = nil; player?.stop(); player = nil
        onChange?()
    }
    func next() {
        guard !tracks.isEmpty else { return }
        playTrack(at: ((currentIndex ?? -1) + 1) % tracks.count)
    }
    func previous() {
        guard !tracks.isEmpty else { return }
        playTrack(at: ((currentIndex ?? 1) - 1 + tracks.count) % tracks.count)
    }
    private func applyVolume() {
        let safe = volume.isFinite ? min(1, max(0, volume)) : 0.35
        player?.volume = Float(safe * (isDucked ? 0.12 : 1))
    }
    private func fail(_ message: String) {
        stop(); lastError = message; onChange?()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let reference = MusicCallbackReference(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === reference.player else { return }
            guard flag else { self.fail("音乐播放中断，请重新选择曲目。"); return }
            // AVAudioPlayer handles single-track looping; the delegate advances
            // only after a full successful track, wrapping at the playlist end.
            self.next()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let reference = MusicCallbackReference(player)
        let message = error?.localizedDescription ?? "文件不可用"
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === reference.player else { return }
            self.fail("音乐解码失败：\(message)")
        }
    }
    private enum MusicError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? { "本机音频不可用或无法解码。" }
    }
}
