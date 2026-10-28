import Foundation

enum BundledMusicError: Error, LocalizedError, Equatable {
    case unsafeResource
    case invalidManifest
    case unsupportedVersion
    case invalidInstallationState
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeResource: return "内置音乐资源缺失、是链接或路径不安全，未继续安装。"
        case .invalidManifest: return "内置音乐清单无效，未安装示范歌单。"
        case .unsupportedVersion: return "内置音乐清单版本暂不支持，未安装示范歌单。"
        case .invalidInstallationState: return "内置音乐安装标记无效；没有重复导入或覆盖歌单。"
        case .rollbackFailed(let message): return "内置歌单安装失败，回滚未完全完成：\(message)"
        }
    }
}

/// Reads signed, application-bundled audio, then asks the existing private
/// library to copy it. It never plays audio, reads an original user music path,
/// scans a directory, or changes focus history or the user's reminder settings.
enum BundledMusicInstaller {
    static let installedPacksKey = "BundledMusicInstalledPackIDsV1"
    private static let installationLock = NSRecursiveLock()

    private struct Manifest: Decodable {
        let version: Int
        let packID: String
        let name: String
        let tracks: [Track]
        struct Track: Decodable {
            let fileName: String
            let title: String
        }
    }

    /// resourcesURL is Bundle.main.resourceURL, not the BundledMusic directory.
    /// An absent bundle/manifest is a no-op for source-only test environments;
    /// importantly, no installed marker is written for that no-op.
    static func installIfNeeded(store: AudioLibraryStore, resourcesURL: URL?,
                                defaults: UserDefaults = .standard) throws {
        installationLock.lock()
        defer { installationLock.unlock() }
        guard let resourcesURL else { return }
        try requireLocalURL(resourcesURL)
        let resources = resourcesURL.standardizedFileURL
        let directory = resources.appendingPathComponent("BundledMusic", isDirectory: true)
        let manifestURL = directory.appendingPathComponent("playlist.plist", isDirectory: false)
        guard exists(resources) else { return }
        try requireDirectory(resources)
        guard exists(directory) else { return }
        try requireDirectory(directory)
        guard exists(manifestURL) else { return }
        try requireRegularFile(manifestURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              size > 0, size <= 65_536 else { throw BundledMusicError.invalidManifest }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= 65_536 else { throw BundledMusicError.invalidManifest }
        let manifest: Manifest
        do { manifest = try PropertyListDecoder().decode(Manifest.self, from: data) }
        catch { throw BundledMusicError.invalidManifest }
        try validate(manifest)

        let installed = try installedPackIDs(defaults)
        // A user's deletion of this once-installed playlist is intentional.
        // Missing audio or a deleted playlist never triggers automatic reimport.
        guard !installed.contains(manifest.packID) else { return }

        let sources = try manifest.tracks.map { track -> URL in
            let url = directory.appendingPathComponent(track.fileName, isDirectory: false)
            try requireRegularFile(url)
            return url
        }
        let previous = Preferences(selected: store.selectedPlaylistID,
            volume: store.musicVolume, loop: store.loopMode,
            followsTimer: store.followsFocusTimer, wasEmpty: store.playlists.isEmpty)
        let playlistID = try store.createPlaylist(name: manifest.name)
        do {
            let copied = try store.importTracks(sources, into: playlistID)
            guard copied.count == manifest.tracks.count else { throw BundledMusicError.invalidManifest }
            for (copy, item) in zip(copied, manifest.tracks) {
                try store.renameTrack(id: copy.id, in: playlistID,
                                      title: item.title.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try restorePreferences(previous, store: store,
                                   selected: previous.wasEmpty ? playlistID : previous.selected)
            // Mark only after every import, title and preference write succeeds.
            // The marker lives in this app's own domain (or an isolated test
            // suite), never in NSGlobalDomain or an unrelated application.
            defaults.set(installed + [manifest.packID], forKey: installedPacksKey)
        } catch {
            let original = error
            var rollbackErrors: [String] = []
            do { try store.removePlaylist(id: playlistID) }
            catch { rollbackErrors.append(error.localizedDescription) }
            do { try restorePreferences(previous, store: store, selected: previous.selected) }
            catch { rollbackErrors.append(error.localizedDescription) }
            if !rollbackErrors.isEmpty {
                throw BundledMusicError.rollbackFailed(([original.localizedDescription] + rollbackErrors).joined(separator: "；"))
            }
            throw original
        }
    }

    private struct Preferences {
        let selected: UUID?
        let volume: Double
        let loop: MusicLoopMode
        let followsTimer: Bool
        let wasEmpty: Bool
    }

    private static func restorePreferences(_ previous: Preferences, store: AudioLibraryStore,
                                           selected: UUID?) throws {
        try store.savePreferences(selected: selected, volume: previous.volume,
                                  loop: previous.loop, followsTimer: previous.followsTimer)
    }

    private static func installedPackIDs(_ defaults: UserDefaults) throws -> [String] {
        guard let raw = defaults.object(forKey: installedPacksKey) else { return [] }
        guard let values = raw as? [String], Set(values).count == values.count,
              values.allSatisfy(validPackID) else { throw BundledMusicError.invalidInstallationState }
        return values
    }

    private static func validate(_ manifest: Manifest) throws {
        guard manifest.version == 1 else { throw BundledMusicError.unsupportedVersion }
        guard validPackID(manifest.packID), validText(manifest.name, limit: 80),
              (1...20).contains(manifest.tracks.count),
              Set(manifest.tracks.map(\.fileName)).count == manifest.tracks.count else {
            throw BundledMusicError.invalidManifest
        }
        for track in manifest.tracks {
            let name = track.fileName
            guard name == (name as NSString).lastPathComponent,
                  !name.isEmpty, !name.contains("/"), !name.contains("\\"),
                  !name.contains(":"), !name.contains("\0"),
                  AudioLibraryStore.supportedExtensions.contains((name as NSString).pathExtension.lowercased()),
                  validText(track.title, limit: 200) else { throw BundledMusicError.invalidManifest }
        }
    }

    private static func validText(_ text: String, limit: Int) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...limit).contains(clean.count) && !text.contains("\0")
    }

    private static func validPackID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }

    private static func requireLocalURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil else { throw BundledMusicError.unsafeResource }
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Check exactly the referenced path components, without listing any of
    /// their parents or following symlinks into unrelated locations.
    private static func requireType(_ url: URL, _ finalType: FileAttributeType) throws {
        try requireLocalURL(url)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let components = url.standardizedFileURL.pathComponents.dropFirst()
        for (offset, part) in components.enumerated() {
            current.appendPathComponent(part)
            let type: FileAttributeType
            do {
                guard let value = try FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType else {
                    throw BundledMusicError.unsafeResource
                }
                type = value
            } catch { throw BundledMusicError.unsafeResource }
            guard type == (offset == components.count - 1 ? finalType : .typeDirectory) else {
                throw BundledMusicError.unsafeResource
            }
        }
    }

    private static func requireDirectory(_ url: URL) throws { try requireType(url, .typeDirectory) }
    private static func requireRegularFile(_ url: URL) throws { try requireType(url, .typeRegular) }
}
