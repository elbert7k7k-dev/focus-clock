import Foundation
import AVFoundation

/// Imported audio is copied into this app's own library. Source paths and
/// security-scoped bookmarks are deliberately never written to the manifest.
struct LibraryTrack: Codable, Equatable {
    var id: UUID
    var fileName: String
    var title: String
    var duration: Double
}

struct FocusPlaylist: Codable, Equatable {
    var id: UUID
    var name: String
    var tracks: [LibraryTrack]
}

enum MusicLoopMode: String, Codable {
    case playlist, single
}

enum AudioLibraryError: Error, LocalizedError, Equatable {
    case invalidRoot, unsafePath, invalidFileName, damagedManifest, unsupportedVersion
    case saveFailed, noFiles, tooManyFiles, invalidPlaylistName, playlistNotFound
    case trackNotFound, unsupportedFormat, fileNotRegular, tooLargeFile, batchTooLarge
    case invalidAudio, missingAudio, invalidPreferences, invalidTitle, importFailed

    var errorDescription: String? {
        switch self {
        case .invalidRoot: return "无法创建或读取本工具的本机音频目录。"
        case .unsafePath: return "音频目录或文件是链接，或路径不属于本工具；没有继续读写。"
        case .invalidFileName: return "音频文件引用无效，没有读取其他位置。"
        case .damagedManifest: return "歌单文件损坏或内容无效；原文件未被覆盖。"
        case .unsupportedVersion: return "这份歌单来自暂不支持的版本；原文件未被覆盖。"
        case .saveFailed: return "歌单没有保存成功，本次修改未应用；请检查本工具的数据目录。"
        case .noFiles: return "请选择或拖入至少一个本地音频文件。"
        case .tooManyFiles: return "一次最多导入100首，请分批导入。"
        case .invalidPlaylistName: return "歌单名称请填写1至80个字。"
        case .playlistNotFound: return "这份歌单已不存在，请重新选择。"
        case .trackNotFound: return "这首歌曲已不在所选歌单中。"
        case .unsupportedFormat: return "仅支持本地 MP3、M4A、WAV、AIFF、AIF 和 CAF 音频；不支持在线链接或歌单网址。"
        case .fileNotRegular: return "请拖入音频文件本身；文件夹、链接及远程文件不支持导入。"
        case .tooLargeFile: return "单个音频文件不能超过512MB，请选用较小的文件。"
        case .batchTooLarge: return "一批音频合计不能超过2GB，请分批导入。"
        case .invalidAudio: return "有音频无法解码、没有有效时长或已损坏；整批未导入。"
        case .missingAudio: return "这份本机音频已丢失，请重新导入原文件。"
        case .invalidPreferences: return "歌单或音量设置无效；原设置未改变。"
        case .invalidTitle: return "歌曲名称请填写1至200个字。"
        case .importFailed: return "音频复制失败；本次新文件已回滚，原音频未修改。"
        }
    }
}

/// A mutation lock serializes imports/writes; a separate short lock protects
/// snapshots without blocking timer/UI readers during long file copies.
/// This type has no playback,
/// networking, directory scanning outside its own root, or global preferences.
final class AudioLibraryStore: @unchecked Sendable {
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf"]
    static let maximumFileBytes: Int64 = 512 * 1024 * 1024
    static let maximumBatchBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumBatchCount = 100

    let rootURL: URL
    private let mediaDirectory: URL
    private let manifestURL: URL
    private let fm = FileManager.default
    private let lock = NSRecursiveLock()
    private let documentLock = NSRecursiveLock()
    private var document: Document
    private var cleanupWarning: String?

    var playlists: [FocusPlaylist] { locked { document.playlists } }
    var selectedPlaylistID: UUID? { locked { document.selectedPlaylistID } }
    var musicVolume: Double { locked { document.musicVolume } }
    var loopMode: MusicLoopMode { locked { document.loopMode } }
    var followsFocusTimer: Bool { locked { document.followsFocusTimer } }
    var lastCleanupWarning: String? { locked { cleanupWarning } }

    private func locked<T>(_ body: () -> T) -> T {
        documentLock.lock()
        defer { documentLock.unlock() }
        return body()
    }

    private struct Document: Codable {
        var version = 1
        var playlists: [FocusPlaylist] = []
        var selectedPlaylistID: UUID? = nil
        var musicVolume: Double = 0.35
        var loopMode: MusicLoopMode = .playlist
        var followsFocusTimer = false
        var reminderAssets: [String] = []

        init() {}
        private enum CodingKeys: String, CodingKey {
            case version, playlists, selectedPlaylistID, musicVolume, loopMode, followsFocusTimer, reminderAssets
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            playlists = try values.decode([FocusPlaylist].self, forKey: .playlists)
            selectedPlaylistID = try values.decodeIfPresent(UUID.self, forKey: .selectedPlaylistID)
            musicVolume = try values.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.35
            loopMode = try values.decodeIfPresent(MusicLoopMode.self, forKey: .loopMode) ?? .playlist
            followsFocusTimer = try values.decodeIfPresent(Bool.self, forKey: .followsFocusTimer) ?? false
            reminderAssets = try values.decodeIfPresent([String].self, forKey: .reminderAssets) ?? []
        }
    }

    init(rootURL: URL) throws {
        guard Self.isLocalURL(rootURL) else { throw AudioLibraryError.invalidRoot }
        self.rootURL = rootURL.standardizedFileURL
        mediaDirectory = self.rootURL.appendingPathComponent("Audio", isDirectory: true)
        manifestURL = self.rootURL.appendingPathComponent("audio-library.json", isDirectory: false)
        document = Document()
        try ensureDirectory(self.rootURL)
        try ensureDirectory(mediaDirectory)
        if pathExists(manifestURL) {
            try ensureRegularFile(manifestURL)
            let attributes = try fm.attributesOfItem(atPath: manifestURL.path)
            guard (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max <= 8 * 1024 * 1024 else {
                throw AudioLibraryError.damagedManifest
            }
            let data: Data
            do { data = try Data(contentsOf: manifestURL, options: []) }
            catch { throw AudioLibraryError.damagedManifest }
            do { document = try JSONDecoder().decode(Document.self, from: data) }
            catch { throw AudioLibraryError.damagedManifest }
            guard document.version == 1 else { throw AudioLibraryError.unsupportedVersion }
            try validate(document)
        }
    }

    @discardableResult
    func createPlaylist(name: String) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count) else { throw AudioLibraryError.invalidPlaylistName }
        let id = UUID()
        var changed = document
        changed.playlists.append(FocusPlaylist(id: id, name: name, tracks: []))
        changed.selectedPlaylistID = id
        try apply(changed)
        return id
    }

    @discardableResult
    func importTracks(_ urls: [URL], into playlistID: UUID) throws -> [LibraryTrack] {
        lock.lock()
        defer { lock.unlock() }
        guard let index = document.playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw AudioLibraryError.playlistNotFound
        }
        return try importBatch(urls) { tracks, changed in
            changed.playlists[index].tracks.append(contentsOf: tracks)
        }
    }

    func renameTrack(id: UUID, in playlistID: UUID, title: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(title.count) else { throw AudioLibraryError.invalidTitle }
        guard let playlist = document.playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw AudioLibraryError.playlistNotFound
        }
        guard let track = document.playlists[playlist].tracks.firstIndex(where: { $0.id == id }) else {
            throw AudioLibraryError.trackNotFound
        }
        var changed = document
        changed.playlists[playlist].tracks[track].title = title
        try apply(changed)
    }

    func removeTrack(id: UUID, from playlistID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let playlist = document.playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw AudioLibraryError.playlistNotFound
        }
        guard let track = document.playlists[playlist].tracks.firstIndex(where: { $0.id == id }) else {
            throw AudioLibraryError.trackNotFound
        }
        var changed = document
        let removed = changed.playlists[playlist].tracks.remove(at: track)
        try apply(changed)
        cleanUnreferenced([removed.fileName])
    }

    func removePlaylist(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = document.playlists.firstIndex(where: { $0.id == id }) else {
            throw AudioLibraryError.playlistNotFound
        }
        var changed = document
        let removed = changed.playlists.remove(at: index)
        if changed.selectedPlaylistID == id { changed.selectedPlaylistID = changed.playlists.first?.id }
        try apply(changed)
        cleanUnreferenced(removed.tracks.map(\.fileName))
    }

    func savePreferences(selected: UUID?, volume: Double, loop: MusicLoopMode, followsTimer: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard volume.isFinite, (0...1).contains(volume),
              selected == nil || document.playlists.contains(where: { $0.id == selected }) else {
            throw AudioLibraryError.invalidPreferences
        }
        var changed = document
        changed.selectedPlaylistID = selected
        changed.musicVolume = volume
        changed.loopMode = loop
        changed.followsFocusTimer = followsTimer
        try apply(changed)
    }

    func importReminder(_ url: URL) throws -> (fileName: String, title: String) {
        lock.lock()
        defer { lock.unlock() }
        let tracks = try importBatch([url]) { tracks, changed in
            changed.reminderAssets.append(contentsOf: tracks.map(\.fileName))
        }
        let track = tracks[0]
        return (track.fileName, track.title)
    }

    /// Only UUID-named, regular files inside Audio/ can be returned. A missing
    /// asset never falls back to the user's original path or another directory.
    func audioURL(fileName: String) throws -> URL {
        guard Self.validFileName(fileName) else { throw AudioLibraryError.invalidFileName }
        try verifyStructure()
        let url = mediaDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard pathExists(url) else { throw AudioLibraryError.missingAudio }
        try ensureRegularFile(url)
        return url
    }

    private static func isLocalURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.query == nil && url.fragment == nil
    }

    private static func validFileName(_ name: String) -> Bool {
        guard name == (name as NSString).lastPathComponent, !name.contains("\\"), !name.contains("\0") else {
            return false
        }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return supportedExtensions.contains(ext) && UUID(uuidString: stem) != nil && stem.count == 36
    }

    private func pathExists(_ url: URL) -> Bool {
        // attributesOfItem observes the final symlink itself, including a
        // dangling link, rather than treating that path as absent.
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private func ensureDirectory(_ url: URL) throws {
        if pathExists(url) {
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else { throw AudioLibraryError.unsafePath }
        } else {
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            catch { throw AudioLibraryError.invalidRoot }
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else { throw AudioLibraryError.unsafePath }
        }
    }

    private func ensureRegularFile(_ url: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: url.path) }
        catch { throw AudioLibraryError.missingAudio }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AudioLibraryError.unsafePath
        }
    }

    private func verifyDirectories() throws {
        for directory in [rootURL, mediaDirectory] {
            guard pathExists(directory),
                  try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw AudioLibraryError.unsafePath
            }
        }
    }

    private func verifyStructure() throws {
        try verifyDirectories()
        if pathExists(manifestURL) { try ensureRegularFile(manifestURL) }
    }

    private func validate(_ value: Document) throws {
        guard value.version == 1 else { throw AudioLibraryError.unsupportedVersion }
        guard value.musicVolume.isFinite, (0...1).contains(value.musicVolume),
              Set(value.playlists.map(\.id)).count == value.playlists.count,
              value.selectedPlaylistID == nil || value.playlists.contains(where: { $0.id == value.selectedPlaylistID }) else {
            throw AudioLibraryError.damagedManifest
        }
        var sharedTracks: [UUID: LibraryTrack] = [:]
        for playlist in value.playlists {
            guard (1...80).contains(playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).count),
                  Set(playlist.tracks.map(\.id)).count == playlist.tracks.count else {
                throw AudioLibraryError.damagedManifest
            }
            for track in playlist.tracks {
                guard Self.validFileName(track.fileName),
                      UUID(uuidString: (track.fileName as NSString).deletingPathExtension) == track.id,
                      track.duration.isFinite, track.duration > 0,
                      (1...200).contains(track.title.trimmingCharacters(in: .whitespacesAndNewlines).count) else {
                    throw AudioLibraryError.damagedManifest
                }
                if let existing = sharedTracks[track.id] {
                    guard existing.fileName == track.fileName, existing.duration == track.duration else {
                        throw AudioLibraryError.damagedManifest
                    }
                } else { sharedTracks[track.id] = track }
            }
        }
        guard Set(value.reminderAssets).count == value.reminderAssets.count,
              value.reminderAssets.allSatisfy(Self.validFileName) else { throw AudioLibraryError.damagedManifest }
        let references = Set(value.playlists.flatMap { $0.tracks.map(\.fileName) } + value.reminderAssets)
        for name in references {
            let url = mediaDirectory.appendingPathComponent(name)
            if pathExists(url) { try ensureRegularFile(url) }
        }
    }

    private func apply(_ changed: Document) throws {
        try verifyStructure()
        try validate(changed)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(changed)
            guard data.count <= 8 * 1024 * 1024 else { throw AudioLibraryError.saveFailed }
            try data.write(to: manifestURL, options: .atomic)
        } catch { throw AudioLibraryError.saveFailed }
        locked { document = changed }
    }

    /// Inspect only the selected path and its ancestors, never their contents.
    /// macOS's canonical /var, /tmp and /etc aliases are allowed; user-created
    /// links in a selected source path are rejected rather than followed.
    private func verifySourcePath(_ url: URL) throws {
        var component = url.standardizedFileURL
        let systemAliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]
        while component.path != "/" {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try fm.attributesOfItem(atPath: component.path) }
            catch { throw AudioLibraryError.fileNotRegular }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                guard let expected = systemAliases[component.path],
                      component.resolvingSymlinksInPath().path == expected else {
                    throw AudioLibraryError.fileNotRegular
                }
            }
            component = component.deletingLastPathComponent()
        }
    }

    private struct ImportSource {
        var url: URL
        var ext: String
        var size: Int64
        var title: String
    }

    /// Decoding happens on private copies. The manifest and in-memory state
    /// only change after every file has passed, so bad files cannot half-import.
    private func importBatch(_ urls: [URL], update: ([LibraryTrack], inout Document) -> Void) throws -> [LibraryTrack] {
        guard !urls.isEmpty else { throw AudioLibraryError.noFiles }
        guard urls.count <= Self.maximumBatchCount else { throw AudioLibraryError.tooManyFiles }
        try verifyStructure()
        var sources: [ImportSource] = []
        var batchBytes: Int64 = 0
        for url in urls {
            guard Self.isLocalURL(url) else { throw AudioLibraryError.fileNotRegular }
            try verifySourcePath(url)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try fm.attributesOfItem(atPath: url.path) }
            catch { throw AudioLibraryError.fileNotRegular }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw AudioLibraryError.fileNotRegular
            }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { throw AudioLibraryError.unsupportedFormat }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw AudioLibraryError.invalidAudio }
            guard size <= Self.maximumFileBytes else { throw AudioLibraryError.tooLargeFile }
            batchBytes += size
            guard batchBytes <= Self.maximumBatchBytes else { throw AudioLibraryError.batchTooLarge }
            let proposed = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = proposed.isEmpty ? "未命名音频" : String(proposed.prefix(200))
            sources.append(ImportSource(url: url, ext: ext, size: size, title: title))
        }
        let stage = mediaDirectory.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var staged: [URL] = []
        var committed: [URL] = []
        var tracks: [LibraryTrack] = []
        defer { removeEmptyStage(stage, files: staged) }
        do {
            for source in sources {
                try verifyStructure()
                // Recheck after preflight, then copy without modifying source.
                try verifySourcePath(source.url)
                let attributes = try fm.attributesOfItem(atPath: source.url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.int64Value == source.size else {
                    throw AudioLibraryError.fileNotRegular
                }
                let id = UUID()
                let name = id.uuidString + "." + source.ext
                let copy = stage.appendingPathComponent(name)
                staged.append(copy)
                try fm.copyItem(at: source.url, to: copy)
                try ensureRegularFile(copy)
                let attributesAfterCopy = try fm.attributesOfItem(atPath: copy.path)
                guard (attributesAfterCopy[.size] as? NSNumber)?.int64Value == source.size else {
                    throw AudioLibraryError.importFailed
                }
                let player: AVAudioPlayer
                do { player = try AVAudioPlayer(contentsOf: copy) }
                catch { throw AudioLibraryError.invalidAudio }
                guard player.duration.isFinite, player.duration > 0, player.numberOfChannels > 0 else {
                    throw AudioLibraryError.invalidAudio
                }
                tracks.append(LibraryTrack(id: id, fileName: name, title: source.title, duration: player.duration))
            }
            for (index, track) in tracks.enumerated() {
                try verifyStructure()
                let destination = mediaDirectory.appendingPathComponent(track.fileName)
                guard !pathExists(destination) else { throw AudioLibraryError.importFailed }
                try fm.moveItem(at: staged[index], to: destination)
                committed.append(destination)
            }
            var changed = document
            update(tracks, &changed)
            try apply(changed)
            return tracks
        } catch {
            for url in committed { removeOwnedNewFile(url) }
            if let known = error as? AudioLibraryError { throw known }
            throw AudioLibraryError.importFailed
        }
    }

    private func removeOwnedNewFile(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == mediaDirectory,
              Self.validFileName(url.lastPathComponent),
              (try? verifyDirectories()) != nil,
              (try? ensureRegularFile(url)) != nil else { return }
        try? fm.removeItem(at: url)
    }

    private func removeEmptyStage(_ stage: URL, files: [URL]) {
        guard stage.deletingLastPathComponent().standardizedFileURL == mediaDirectory,
              stage.lastPathComponent.hasPrefix(".import-"),
              UUID(uuidString: String(stage.lastPathComponent.dropFirst(8))) != nil,
              (try? verifyDirectories()) != nil,
              (try? fm.attributesOfItem(atPath: stage.path)[.type] as? FileAttributeType) == .typeDirectory else { return }
        for file in files where file.deletingLastPathComponent() == stage {
            guard Self.validFileName(file.lastPathComponent), (try? ensureRegularFile(file)) != nil else { continue }
            try? fm.removeItem(at: file)
        }
        if let contents = try? fm.contentsOfDirectory(atPath: stage.path), contents.isEmpty {
            try? fm.removeItem(at: stage)
        }
    }

    /// Only candidates just removed from this manifest are considered. Files
    /// still referenced by another playlist or a reminder remain untouched.
    private func cleanUnreferenced(_ candidates: [String]) {
        locked { cleanupWarning = nil }
        let retained = Set(document.playlists.flatMap { $0.tracks.map(\.fileName) } + document.reminderAssets)
        for name in Set(candidates) where !retained.contains(name) {
            do {
                guard Self.validFileName(name) else { throw AudioLibraryError.invalidFileName }
                try verifyStructure()
                let url = mediaDirectory.appendingPathComponent(name)
                guard pathExists(url) else { continue }
                try ensureRegularFile(url)
                try fm.removeItem(at: url)
            } catch {
                // Metadata removal has already committed. Report a leftover,
                // rather than pretending that the playlist edit was undone.
                locked { cleanupWarning = "歌单已更新，但有本工具的旧音频未能清理；未删除其他位置。" }
            }
        }
    }
}
