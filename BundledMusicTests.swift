import Foundation

private struct BundledTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class BundledChecks {
    private(set) var assertions = 0
    private(set) var cases = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try condition() else { throw BundledTestFailure(description: message) }
    }
    func rejects(_ operation: () throws -> Void, _ message: String) throws {
        assertions += 1
        do { try operation() }
        catch { return }
        throw BundledTestFailure(description: "应拒绝：" + message)
    }
    func run(_ title: String, _ body: () throws -> Void) throws {
        try body(); cases += 1; print("PASS \(title)")
    }
}

/// Only isolated .build fixtures and a fresh test preference suite are touched.
/// Import uses decoding/probing but no audio player is ever asked to play.
@main
private struct BundledMusicTestRunner {
    private static let fm = FileManager.default
    private static func tinyWAV() -> Data {
        let frames: UInt32 = 400
        var data = Data()
        func tag(_ value: String) { data.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func long(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        tag("RIFF"); long(36 + frames * 2); tag("WAVEfmt "); long(16)
        word(1); word(1); long(8_000); long(16_000); word(2); word(16)
        tag("data"); long(frames * 2); data.append(Data(repeating: 0, count: Int(frames * 2)))
        return data
    }
    private static func writePlist(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }

    static func main() throws {
        let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build", isDirectory: true)
        if let value = try? fm.attributesOfItem(atPath: build.path)[.type] as? FileAttributeType,
           value != .typeDirectory { throw BundledTestFailure(description: ".build不是普通目录") }
        let root = build.appendingPathComponent("bundled-music-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "io.github.focusclock.tests.bundled." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw BundledTestFailure(description: "无法创建测试偏好域") }
        defer { defaults.removePersistentDomain(forName: suite); defaults.synchronize() }
        let check = BundledChecks()
        var serial = 0
        func nextRoot(_ prefix: String) -> URL {
            serial += 1
            return root.appendingPathComponent("\(prefix)-\(serial)", isDirectory: true)
        }
        func resetMarker() { defaults.removeObject(forKey: BundledMusicInstaller.installedPacksKey) }
        func store() throws -> AudioLibraryStore { try AudioLibraryStore(rootURL: nextRoot("library")) }
        func fixture(_ overrides: [String: Any] = [:]) throws -> (resources: URL, directory: URL, manifest: URL) {
            let resources = nextRoot("Resources")
            let dir = resources.appendingPathComponent("BundledMusic", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try tinyWAV().write(to: dir.appendingPathComponent("first.wav"))
            try tinyWAV().write(to: dir.appendingPathComponent("second.wav"))
            var manifest: [String: Any] = [
                "version": 1, "packID": "focus-clock-starter-v1", "name": "内置专注音乐",
                "tracks": [["fileName": "first.wav", "title": "第一首"],
                           ["fileName": "second.wav", "title": "第二首"]]
            ]
            overrides.forEach { manifest[$0.key] = $0.value }
            let url = dir.appendingPathComponent("playlist.plist")
            try writePlist(manifest, to: url)
            return (resources, dir, url)
        }
        func install(_ store: AudioLibraryStore, _ resources: URL?) throws {
            try BundledMusicInstaller.installIfNeeded(store: store, resourcesURL: resources, defaults: defaults)
        }
        func media(_ store: AudioLibraryStore) throws -> [String] {
            try fm.contentsOfDirectory(atPath: store.rootURL.appendingPathComponent("Audio").path).sorted()
        }

        try check.run("absent resources and absent manifest are unmarked no-ops") {
            resetMarker(); let library = try store()
            try install(library, nil)
            try install(library, nextRoot("absent"))
            let pack = try fixture(); try fm.removeItem(at: pack.manifest)
            try install(library, pack.resources)
            try check.expect(library.playlists.isEmpty, "没有资源时不能制造空歌单")
            try check.expect(defaults.object(forKey: BundledMusicInstaller.installedPacksKey) == nil, "无资源不能标已安装")
            try check.expect(try media(library).isEmpty, "无资源不能复制音频")
        }
        try check.run("first installation copies complete tracks and keeps empty-library defaults") {
            resetMarker(); let library = try store(); let pack = try fixture()
            let source = try Data(contentsOf: pack.directory.appendingPathComponent("first.wav"))
            try install(library, pack.resources)
            try check.expect(library.playlists.count == 1, "只创建一个内置歌单")
            let list = library.playlists[0]
            try check.expect(list.name == "内置专注音乐" && list.tracks.map(\.title) == ["第一首", "第二首"], "清单顺序与标题应保留")
            try check.expect(library.selectedPlaylistID == list.id, "空库应选择刚安装歌单")
            try check.expect(library.musicVolume == 0.35 && library.loopMode == .playlist && !library.followsFocusTimer, "安装不改变默认播放偏好")
            try check.expect(try Data(contentsOf: library.audioURL(fileName: list.tracks[0].fileName)) == source, "私有副本应完整")
            try check.expect(try Data(contentsOf: pack.directory.appendingPathComponent("first.wav")) == source, "bundle音频应未修改")
            try check.expect(defaults.stringArray(forKey: BundledMusicInstaller.installedPacksKey) == ["focus-clock-starter-v1"], "完成后才登记包标记")
        }
        try check.run("reopening and repeat calls neither duplicate files nor rewrite playlists") {
            resetMarker(); let library = try store(); let pack = try fixture()
            try install(library, pack.resources)
            let bytes = try Data(contentsOf: library.rootURL.appendingPathComponent("audio-library.json"))
            let files = try media(library)
            let reopened = try AudioLibraryStore(rootURL: library.rootURL)
            try install(reopened, pack.resources); try install(reopened, pack.resources)
            try check.expect(reopened.playlists.count == 1, "重开不能重复歌单")
            try check.expect(try media(reopened) == files, "重开不能重复音频副本")
            try check.expect(try Data(contentsOf: library.rootURL.appendingPathComponent("audio-library.json")) == bytes, "重开不重写既有清单")
        }
        try check.run("user deletion of an installed playlist is respected") {
            resetMarker(); let library = try store(); let pack = try fixture()
            try install(library, pack.resources)
            try library.removePlaylist(id: library.playlists[0].id)
            try install(library, pack.resources)
            try check.expect(library.playlists.isEmpty && (try media(library)).isEmpty, "不擅自恢复已删除歌单")
            try check.expect(defaults.stringArray(forKey: BundledMusicInstaller.installedPacksKey) == ["focus-clock-starter-v1"], "用户删除不清除安装标记")
        }
        try check.run("existing user music selection preferences and focus history survive installation") {
            resetMarker(); let library = try store(); let pack = try fixture()
            let history = library.rootURL.appendingPathComponent("focus-history.json")
            let sentinel = Data("本人的真实专注记录；安装器不得读取或修改".utf8); try sentinel.write(to: history)
            let id = try library.createPlaylist(name: "本人歌单")
            let original = try library.importTracks([pack.directory.appendingPathComponent("first.wav")], into: id)
            try library.savePreferences(selected: id, volume: 0.73, loop: .single, followsTimer: true)
            try install(library, pack.resources)
            try check.expect(library.playlists.count == 2 && library.playlists[0].tracks == original, "原有歌单与曲目不变")
            try check.expect(library.selectedPlaylistID == id, "保留本人当前选择")
            try check.expect(library.musicVolume == 0.73 && library.loopMode == .single && library.followsFocusTimer, "保留本人所有播放偏好")
            try check.expect(try Data(contentsOf: history) == sentinel, "专注记录逐字节保持")
        }
        try check.run("existing intentional nil selection remains nil") {
            resetMarker(); let library = try store(); let pack = try fixture()
            _ = try library.createPlaylist(name: "尚未选择的本人歌单")
            try library.savePreferences(selected: nil, volume: 0.45, loop: .playlist, followsTimer: false)
            try install(library, pack.resources)
            try check.expect(library.selectedPlaylistID == nil && library.playlists.count == 2, "非空库的空选择也保留")
        }
        try check.run("unknown versions and malformed plist never mutate the private library") {
            resetMarker(); let library = try store(); let pack = try fixture(["version": 2])
            try check.rejects({ try install(library, pack.resources) }, "未知版本")
            try Data("损坏plist".utf8).write(to: pack.manifest)
            try check.rejects({ try install(library, pack.resources) }, "损坏清单")
            try check.expect(library.playlists.isEmpty && (try media(library)).isEmpty, "坏清单不创建副本")
            try check.expect(defaults.object(forKey: BundledMusicInstaller.installedPacksKey) == nil, "坏清单不写标记")
        }
        try check.run("manifest validates pack IDs titles names and one-to-twenty track bound") {
            resetMarker(); let library = try store()
            let invalid: [[String: Any]] = [
                ["packID": "../escape"], ["packID": ""], ["name": "  "],
                ["name": String(repeating: "长", count: 81)], ["tracks": []],
                ["tracks": (0..<21).map { ["fileName": "\($0).wav", "title": "曲目"] }],
                ["tracks": [["fileName": "first.wav", "title": ""]]],
                ["tracks": [["fileName": "first.wav", "title": String(repeating: "长", count: 201)]]],
                ["tracks": [["fileName": "first.wav", "title": "\0"]]],
                ["tracks": [["fileName": "first.wav", "title": "一"], ["fileName": "first.wav", "title": "二"]]]
            ]
            for item in invalid { let pack = try fixture(item); try check.rejects({ try install(library, pack.resources) }, "清单边界") }
            try check.expect(library.playlists.isEmpty, "边界错误不留下列表")
        }
        try check.run("nine-track production shape and the twenty-track upper bound retain exact order") {
            for count in [9, 20] {
                resetMarker(); let library = try store()
                let entries = (1...count).map { ["fileName": "track-\($0).wav", "title": "第\($0)首"] }
                let pack = try fixture(["tracks": entries])
                for entry in entries { try tinyWAV().write(to: pack.directory.appendingPathComponent(entry["fileName"]!)) }
                try install(library, pack.resources)
                try check.expect(library.playlists[0].tracks.count == count, "完整安装全部曲目")
                try check.expect(library.playlists[0].tracks.map(\.title) == entries.map { $0["title"]! }, "不按文件名字典序改变manifest顺序")
                try check.expect(try media(library).count == count, "只复制被引用曲目")
            }
        }
        try check.run("filenames cannot escape the resource directory or refer to streams") {
            resetMarker(); let library = try store()
            for name in ["../outside.wav", "nested/first.wav", "/tmp/outside.wav", "https://example.invalid/a.mp3", "file.wav\0", "a\\b.wav", "first.txt"] {
                let pack = try fixture(["tracks": [["fileName": name, "title": "测试"]]])
                try check.rejects({ try install(library, pack.resources) }, "资源越界或非音频")
            }
            try check.expect(library.playlists.isEmpty && (try media(library)).isEmpty, "越界引用不读取或复制其他文件")
        }
        try check.run("missing audio and audio directories fail before creating any playlist") {
            resetMarker(); let library = try store(); let pack = try fixture()
            try fm.removeItem(at: pack.directory.appendingPathComponent("first.wav"))
            try check.rejects({ try install(library, pack.resources) }, "缺音频")
            try fm.createDirectory(at: pack.directory.appendingPathComponent("first.wav"), withIntermediateDirectories: false)
            try check.rejects({ try install(library, pack.resources) }, "音频实际为目录")
            try check.expect(library.playlists.isEmpty, "缺资源在建列表前拒绝")
        }
        try check.run("symbolic links at audio manifest directory and resource ancestor are rejected") {
            resetMarker(); let library = try store()
            let outside = nextRoot("outside"); try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            let target = outside.appendingPathComponent("real.wav"); try tinyWAV().write(to: target)
            let a = try fixture(); let audio = a.directory.appendingPathComponent("first.wav")
            try fm.removeItem(at: audio); try fm.createSymbolicLink(at: audio, withDestinationURL: target)
            try check.rejects({ try install(library, a.resources) }, "音频链接")
            let b = try fixture(); let otherManifest = outside.appendingPathComponent("manifest.plist")
            try fm.moveItem(at: b.manifest, to: otherManifest); try fm.createSymbolicLink(at: b.manifest, withDestinationURL: otherManifest)
            try check.rejects({ try install(library, b.resources) }, "清单链接")
            let c = try fixture(); let linked = nextRoot("linked-resources")
            try fm.createSymbolicLink(at: linked, withDestinationURL: c.resources)
            try check.rejects({ try install(library, linked) }, "Resources父链接")
            let d = try fixture(); try fm.removeItem(at: d.directory)
            try fm.createSymbolicLink(at: d.directory, withDestinationURL: c.directory)
            try check.rejects({ try install(library, d.resources) }, "BundledMusic目录链接")
            try check.expect(library.playlists.isEmpty && (try media(library)).isEmpty, "不跟随任何链接复制")
        }
        try check.run("bad audio rolls back only the newly created playlist and restores previous settings") {
            resetMarker(); let library = try store(); let pack = try fixture()
            let originalID = try library.createPlaylist(name: "本人旧歌单")
            let originalTracks = try library.importTracks([pack.directory.appendingPathComponent("first.wav")], into: originalID)
            try library.savePreferences(selected: originalID, volume: 0.62, loop: .single, followsTimer: true)
            let originalFiles = try media(library)
            try Data("损坏的第二首".utf8).write(to: pack.directory.appendingPathComponent("second.wav"))
            try check.rejects({ try install(library, pack.resources) }, "坏音频")
            try check.expect(library.playlists.count == 1 && library.playlists[0].id == originalID, "只回滚自己新建的歌单")
            try check.expect(library.playlists[0].tracks == originalTracks && (try media(library)) == originalFiles, "原曲及副本保留")
            try check.expect(library.selectedPlaylistID == originalID && library.musicVolume == 0.62 && library.loopMode == .single && library.followsFocusTimer, "失败后原选择偏好恢复")
            try check.expect(defaults.object(forKey: BundledMusicInstaller.installedPacksKey) == nil, "失败不标已安装")
            try tinyWAV().write(to: pack.directory.appendingPathComponent("second.wav"))
            try install(library, pack.resources)
            try check.expect(library.playlists.count == 2 && (try media(library)).count == 3, "修复后重试只增加完整一份歌单")
        }
        try check.run("invalid installation markers do not trigger duplicate imports") {
            let library = try store(); let pack = try fixture()
            for invalid in ["not-array", ["../bad"], ["focus-clock-starter-v1", "focus-clock-starter-v1"]] as [Any] {
                defaults.set(invalid, forKey: BundledMusicInstaller.installedPacksKey)
                try check.rejects({ try install(library, pack.resources) }, "损坏安装标记")
            }
            try check.expect(library.playlists.isEmpty, "无效标记不覆盖既有状态")
            resetMarker()
        }
        try check.run("a separately versioned pack adds once while retaining the earlier selection") {
            resetMarker(); let library = try store(); let a = try fixture()
            try install(library, a.resources); let selected = library.selectedPlaylistID
            let b = try fixture(["packID": "focus-clock-starter-v2", "name": "新版内置音乐"])
            try install(library, b.resources); try install(library, b.resources)
            try check.expect(library.playlists.count == 2 && library.playlists[1].name == "新版内置音乐", "新包只增加一次")
            try check.expect(library.selectedPlaylistID == selected, "新包不抢旧选择")
            try check.expect(defaults.stringArray(forKey: BundledMusicInstaller.installedPacksKey) == ["focus-clock-starter-v1", "focus-clock-starter-v2"], "分别登记版本")
        }
        try check.run("nonlocal resource URLs are rejected without directory access") {
            resetMarker(); let library = try store()
            for url in [URL(string: "https://example.invalid/Resources")!, URL(string: "file://remote.invalid/Resources")!, URL(string: "file:///tmp/Resources?query=1")!] {
                try check.rejects({ try install(library, url) }, "非本机资源")
            }
            try check.expect(library.playlists.isEmpty, "不从网络获取内置歌曲")
        }
        print("BundledMusic: \(check.cases) cases, \(check.assertions) assertions passed; isolated fixtures only, no audio played.")
    }
}
