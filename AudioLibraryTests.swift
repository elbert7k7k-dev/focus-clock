import Foundation
import AVFoundation

@main
struct AudioLibraryTests {
    private static var assertions = 0
    private static var cases = 0
    private static let fm = FileManager.default
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw Failure(description: message) }
    }

    private static func rejects(_ expected: AudioLibraryError, _ message: String,
                                _ operation: () throws -> Void) throws {
        assertions += 1
        do {
            try operation()
            throw Failure(description: "应拒绝：" + message)
        } catch let actual as AudioLibraryError {
            if actual != expected {
                throw Failure(description: "错误不符：\(message)，\(actual) != \(expected)")
            }
        }
    }

    private static func test(_ title: String, _ body: () throws -> Void) throws {
        try body()
        cases += 1
        print("✓ \(title)")
    }

    private static func writeWAV(_ url: URL, frameCount: Int = 1103) throws {
        let sampleRate: UInt32 = 22050
        let bytes = UInt32(frameCount * 2)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); u32(36 + bytes); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        text("data"); u32(bytes)
        data.append(Data(repeating: 0, count: Int(bytes)))
        try data.write(to: url)
    }

    private static func json(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure(description: "测试清单不是对象")
        }
        return value
    }

    private static func saveJSON(_ value: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private static func mediaNames(_ root: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Audio").path).sorted()
    }

    static func main() {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build")
        let sandbox = base.appendingPathComponent("audio-library-tests-" + UUID().uuidString)
        do {
            if let type = try? fm.attributesOfItem(atPath: base.path)[.type] as? FileAttributeType,
               type != .typeDirectory {
                throw Failure(description: ".build不是本机普通目录，测试未运行")
            }
            try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: sandbox) }
            let fixtures = sandbox.appendingPathComponent("fixtures")
            try fm.createDirectory(at: fixtures, withIntermediateDirectories: false)
            let source = fixtures.appendingPathComponent("第一首 歌.WAV")
            let second = fixtures.appendingPathComponent("第二首.wav")
            let bad = fixtures.appendingPathComponent("损坏.wav")
            let zero = fixtures.appendingPathComponent("零时长.wav")
            try writeWAV(source)
            try writeWAV(second, frameCount: 2205)
            try writeWAV(zero, frameCount: 0)
            try Data("这不是音频".utf8).write(to: bad)
            let originalBytes = try Data(contentsOf: source)
            let originalAttributes = try fm.attributesOfItem(atPath: source.path)
            func root(_ name: String) -> URL { sandbox.appendingPathComponent(name) }

            try test("空白库与原有专注数据隔离") {
                let url = root("empty")
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let history = url.appendingPathComponent("focus-history.json")
                let oldHistory = Data("真实记录占位，不应读取或修改".utf8)
                try oldHistory.write(to: history)
                let store = try AudioLibraryStore(rootURL: url)
                try expect(store.playlists.isEmpty, "新库没有模拟歌单")
                try expect(store.selectedPlaylistID == nil, "空库无选择")
                try expect(store.musicVolume == 0.35, "默认音量35%")
                try expect(store.loopMode == .playlist && !store.followsFocusTimer, "默认列表循环、独立控制")
                try expect(try Data(contentsOf: history) == oldHistory, "原专注记录不变")
                try expect(!fm.fileExists(atPath: url.appendingPathComponent("audio-library.json").path), "初始化不写假清单")
            }

            try test("导入复制、解码时长、原文件不变、无原路径记录") {
                let url = root("import")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: " 第一份歌单 ")
                let tracks = try store.importTracks([source, second], into: id)
                try expect(tracks.count == 2, "整批两曲")
                try expect(tracks[0].title == "第一首 歌", "默认取显示名")
                try expect(tracks[0].fileName.hasSuffix(".wav"), "大写扩展名标准化")
                try expect(abs(tracks[0].duration - 0.0500226757) < 0.001, "实际可解码时长")
                let copied = try store.audioURL(fileName: tracks[0].fileName)
                try expect(copied.deletingLastPathComponent().path == url.appendingPathComponent("Audio").path, "副本只在Audio")
                try expect(try Data(contentsOf: copied) == originalBytes, "副本逐字节一致")
                try expect(try Data(contentsOf: source) == originalBytes, "源音频不改")
                let newAttributes = try fm.attributesOfItem(atPath: source.path)
                try expect(originalAttributes[.modificationDate] as? Date == newAttributes[.modificationDate] as? Date, "源mtime不变")
                let manifest = try String(contentsOf: url.appendingPathComponent("audio-library.json"), encoding: .utf8)
                try expect(!manifest.contains(fixtures.path), "不保存源绝对路径")
                try expect(!manifest.contains("file://"), "不保存源URL")
                try expect(try mediaNames(url).count == 2, "无暂存残留")
            }

            try test("多歌单、名称修改及设置重开持久化") {
                let url = root("persist")
                let store = try AudioLibraryStore(rootURL: url)
                let a = try store.createPlaylist(name: "A")
                let b = try store.createPlaylist(name: "B")
                try expect(store.selectedPlaylistID == b, "新建歌单立即选中")
                let track = try store.importTracks([source], into: b)[0]
                try store.renameTrack(id: track.id, in: b, title: "雨夜里的第一首")
                try store.savePreferences(selected: b, volume: 0.72, loop: .single, followsTimer: true)
                let reopened = try AudioLibraryStore(rootURL: url)
                try expect(reopened.playlists.map(\.id) == [a, b], "两歌单保存")
                try expect(reopened.playlists[1].tracks[0].title == "雨夜里的第一首", "曲名可覆写")
                try expect(reopened.selectedPlaylistID == b, "所选歌单保存")
                try expect(reopened.musicVolume == 0.72 && reopened.loopMode == .single && reopened.followsFocusTimer, "音乐偏好保存")
                try reopened.removePlaylist(id: b)
                try expect(reopened.selectedPlaylistID == a, "删除当前歌单退回仍在的歌单")
                try expect(try mediaNames(url).isEmpty, "删最后引用清理副本")
                try expect(try Data(contentsOf: source) == originalBytes, "删除不伤源文件")
            }

            try test("缺少后续字段的旧版清单迁移默认值") {
                let url = root("legacy")
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let manifest = url.appendingPathComponent("audio-library.json")
                let legacy: [String: Any] = ["version": 1, "playlists": []]
                try saveJSON(legacy, manifest)
                let original = try Data(contentsOf: manifest)
                let store = try AudioLibraryStore(rootURL: url)
                try expect(store.musicVolume == 0.35 && store.loopMode == .playlist && !store.followsFocusTimer, "缺字段按默认加载")
                try expect(try Data(contentsOf: manifest) == original, "读取迁移不覆盖原清单")
                _ = try store.createPlaylist(name: "迁移后")
                let value = try json(manifest)
                try expect(value["musicVolume"] as? Double == 0.35, "真正保存写入当前字段")
                try expect(value["reminderAssets"] as? [String] == [], "提醒字段默认空")
            }

            try test("损坏和不支持版本不覆盖原清单") {
                let url = root("damaged")
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let manifest = url.appendingPathComponent("audio-library.json")
                let damaged = Data("{不是json".utf8)
                try damaged.write(to: manifest)
                try rejects(.damagedManifest, "坏JSON") { _ = try AudioLibraryStore(rootURL: url) }
                try expect(try Data(contentsOf: manifest) == damaged, "坏JSON原样保留")
                try saveJSON(["version": 999, "playlists": []], manifest)
                let future = try Data(contentsOf: manifest)
                try rejects(.unsupportedVersion, "未来版本") { _ = try AudioLibraryStore(rootURL: url) }
                try expect(try Data(contentsOf: manifest) == future, "未来版本原样保留")
            }

            try test("一曲损坏时整批回滚清单与复制文件") {
                let url = root("rollback")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "不会半导入")
                let manifest = url.appendingPathComponent("audio-library.json")
                let old = try Data(contentsOf: manifest)
                try rejects(.invalidAudio, "先好后坏") { _ = try store.importTracks([source, bad], into: id) }
                try expect(store.playlists[0].tracks.isEmpty, "内存不半导入")
                try expect(try Data(contentsOf: manifest) == old, "清单不半导入")
                try expect(try mediaNames(url).isEmpty, "坏音频和已复制音频均清走")
                try expect(try Data(contentsOf: source) == originalBytes, "失败不动源文件")
            }

            try test("保存失败回滚已复制音频，不吞掉旧清单") {
                let url = root("save-failure")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "保存失败")
                let manifest = url.appendingPathComponent("audio-library.json")
                let before = try Data(contentsOf: manifest)
                // Audio/ remains writable, so staging/decoding/moves can finish;
                // only the final atomic manifest write is made impossible.
                try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
                defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
                try rejects(.saveFailed, "最终原子保存失败") { _ = try store.importTracks([source], into: id) }
                try expect(store.playlists[0].tracks.isEmpty, "失败不更改内存")
                try expect(try mediaNames(url).isEmpty, "失败清掉已复制音频和暂存")
                try expect(try Data(contentsOf: manifest) == before, "旧清单未被覆盖")
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                let reopened = try AudioLibraryStore(rootURL: url)
                try expect(reopened.playlists[0].tracks.isEmpty, "旧清单仍可使用")
            }

            try test("远程URL、目录、链接、非音频及空文件均拒绝") {
                let url = root("inputs")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "输入边界")
                let alias = fixtures.appendingPathComponent("symlink.wav")
                try fm.createSymbolicLink(at: alias, withDestinationURL: source)
                let dangling = fixtures.appendingPathComponent("dangling.wav")
                try fm.createSymbolicLink(at: dangling, withDestinationURL: fixtures.appendingPathComponent("不存在.wav"))
                let linkedParent = sandbox.appendingPathComponent("linked-source-parent")
                try fm.createSymbolicLink(at: linkedParent, withDestinationURL: fixtures)
                let unsupported = fixtures.appendingPathComponent("audio.txt")
                try originalBytes.write(to: unsupported)
                let empty = fixtures.appendingPathComponent("empty.wav")
                try Data().write(to: empty)
                try rejects(.fileNotRegular, "HTTPS") { _ = try store.importTracks([URL(string: "https://example.com/song.mp3")!], into: id) }
                try rejects(.fileNotRegular, "远程fileURL") { _ = try store.importTracks([URL(string: "file://example.com/audio.wav")!], into: id) }
                try rejects(.fileNotRegular, "目录") { _ = try store.importTracks([fixtures], into: id) }
                try rejects(.fileNotRegular, "符号链接") { _ = try store.importTracks([alias], into: id) }
                try rejects(.fileNotRegular, "悬空链接") { _ = try store.importTracks([dangling], into: id) }
                try rejects(.fileNotRegular, "源父目录链接") { _ = try store.importTracks([linkedParent.appendingPathComponent(source.lastPathComponent)], into: id) }
                try rejects(.unsupportedFormat, "假扩展名") { _ = try store.importTracks([unsupported], into: id) }
                try rejects(.invalidAudio, "空文件") { _ = try store.importTracks([empty], into: id) }
                try rejects(.invalidAudio, "零时长") { _ = try store.importTracks([zero], into: id) }
                try expect(try mediaNames(url).isEmpty, "无垃圾暂存")
            }

            try test("数量、单文件与批次大小边界预检，无大文件实际复制") {
                let url = root("limits")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "限额")
                try rejects(.noFiles, "空批次") { _ = try store.importTracks([], into: id) }
                try rejects(.tooManyFiles, "101首") { _ = try store.importTracks(Array(repeating: source, count: 101), into: id) }
                let sparse = fixtures.appendingPathComponent("sparse.wav")
                fm.createFile(atPath: sparse.path, contents: Data())
                let file = try FileHandle(forWritingTo: sparse)
                try file.truncate(atOffset: UInt64(AudioLibraryStore.maximumFileBytes + 1))
                try file.close()
                defer { try? fm.removeItem(at: sparse) }
                try rejects(.tooLargeFile, "超过512MiB") { _ = try store.importTracks([sparse], into: id) }
                let file2 = try FileHandle(forWritingTo: sparse)
                try file2.truncate(atOffset: UInt64(AudioLibraryStore.maximumFileBytes))
                try file2.close()
                try rejects(.batchTooLarge, "五份512MiB预检超过2GiB") {
                    _ = try store.importTracks(Array(repeating: sparse, count: 5), into: id)
                }
                try expect(try mediaNames(url).isEmpty, "大文件未开始复制")
                try expect(store.playlists[0].tracks.isEmpty, "无清单变化")
            }

            try test("无效设置和名称均保留原值") {
                let url = root("settings")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "参数")
                let track = try store.importTracks([source], into: id)[0]
                let before = try Data(contentsOf: url.appendingPathComponent("audio-library.json"))
                for value in [-0.1, 1.01, Double.nan, Double.infinity] {
                    try rejects(.invalidPreferences, "音量范围") { try store.savePreferences(selected: id, volume: value, loop: .playlist, followsTimer: false) }
                }
                try rejects(.invalidPreferences, "不存在歌单") { try store.savePreferences(selected: UUID(), volume: 0.3, loop: .playlist, followsTimer: false) }
                try rejects(.invalidPlaylistName, "空白歌单") { _ = try store.createPlaylist(name: "  \n ") }
                try rejects(.invalidPlaylistName, "81字歌单") { _ = try store.createPlaylist(name: String(repeating: "歌", count: 81)) }
                try rejects(.invalidTitle, "空曲名") { try store.renameTrack(id: track.id, in: id, title: "  ") }
                try rejects(.invalidTitle, "201字曲名") { try store.renameTrack(id: track.id, in: id, title: String(repeating: "歌", count: 201)) }
                try expect(try Data(contentsOf: url.appendingPathComponent("audio-library.json")) == before, "所有坏参数都没改清单")
            }

            try test("根、Audio和清单链接均不跟随写出") {
                let outside = root("outside")
                try fm.createDirectory(at: outside, withIntermediateDirectories: true)
                let linkedRoot = root("linked-root")
                try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
                try rejects(.unsafePath, "root链接") { _ = try AudioLibraryStore(rootURL: linkedRoot) }
                try expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "没写入root链接目标")
                let linkedAudio = root("linked-audio")
                try fm.createDirectory(at: linkedAudio, withIntermediateDirectories: false)
                try fm.createSymbolicLink(at: linkedAudio.appendingPathComponent("Audio"), withDestinationURL: outside)
                try rejects(.unsafePath, "Audio链接") { _ = try AudioLibraryStore(rootURL: linkedAudio) }
                try expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "没写入Audio链接目标")
                let linkedManifest = root("linked-manifest")
                try fm.createDirectory(at: linkedManifest, withIntermediateDirectories: false)
                let sentinel = outside.appendingPathComponent("sentinel")
                let sentinelBytes = Data("不许改".utf8)
                try sentinelBytes.write(to: sentinel)
                try fm.createSymbolicLink(at: linkedManifest.appendingPathComponent("audio-library.json"), withDestinationURL: sentinel)
                try rejects(.unsafePath, "清单链接") { _ = try AudioLibraryStore(rootURL: linkedManifest) }
                try expect(try Data(contentsOf: sentinel) == sentinelBytes, "清单链接目标没变")
            }

            try test("恶意清单引用与媒体链接不能越出Audio") {
                let url = root("references")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "引用")
                let track = try store.importTracks([source], into: id)[0]
                for invalid in ["../" + track.fileName, "Audio/" + track.fileName, "/tmp/" + track.fileName, "hello.wav", "..\\" + track.fileName] {
                    try rejects(.invalidFileName, "越界文件名") { _ = try store.audioURL(fileName: invalid) }
                }
                let manifest = url.appendingPathComponent("audio-library.json")
                let original = try Data(contentsOf: manifest)
                var value = try json(manifest)
                var lists = value["playlists"] as! [[String: Any]]
                var tracks = lists[0]["tracks"] as! [[String: Any]]
                tracks[0]["fileName"] = "../private.wav"
                lists[0]["tracks"] = tracks; value["playlists"] = lists
                try saveJSON(value, manifest)
                let malicious = try Data(contentsOf: manifest)
                try rejects(.damagedManifest, "清单路径穿越") { _ = try AudioLibraryStore(rootURL: url) }
                try expect(try Data(contentsOf: manifest) == malicious, "坏引用不重写")
                try original.write(to: manifest)
                let imported = try store.audioURL(fileName: track.fileName)
                try fm.removeItem(at: imported)
                try fm.createSymbolicLink(at: imported, withDestinationURL: source)
                try rejects(.unsafePath, "媒体链接播放") { _ = try store.audioURL(fileName: track.fileName) }
                try rejects(.unsafePath, "媒体链接清单加载") { _ = try AudioLibraryStore(rootURL: url) }
                try expect(try Data(contentsOf: source) == originalBytes, "媒体链接源仍没变")
            }

            try test("重复标识和冲突文件引用不进入有效库") {
                let url = root("duplicate-identities")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "身份")
                _ = try store.importTracks([source], into: id)
                let manifest = url.appendingPathComponent("audio-library.json")
                let original = try json(manifest)
                let originalLists = original["playlists"] as! [[String: Any]]
                let originalTracks = originalLists[0]["tracks"] as! [[String: Any]]
                func rejected(_ changed: [String: Any], _ description: String) throws {
                    try saveJSON(changed, manifest)
                    let before = try Data(contentsOf: manifest)
                    try rejects(.damagedManifest, description) { _ = try AudioLibraryStore(rootURL: url) }
                    try expect(try Data(contentsOf: manifest) == before, "无效身份清单保留")
                }
                var changed = original
                changed["playlists"] = originalLists + originalLists
                try rejected(changed, "重复歌单ID")
                changed = original
                var lists = originalLists
                lists[0]["tracks"] = originalTracks + originalTracks
                changed["playlists"] = lists
                try rejected(changed, "同歌单重复歌曲ID")
                changed = original
                lists = originalLists
                var tracks = originalTracks
                tracks[0]["id"] = UUID().uuidString
                lists[0]["tracks"] = tracks
                changed["playlists"] = lists
                try rejected(changed, "歌曲ID和UUID文件名不相符")
                changed = original
                changed["reminderAssets"] = [originalTracks[0]["fileName"]!, originalTracks[0]["fileName"]!]
                try rejected(changed, "重复提醒引用")
                changed = original
                lists = originalLists
                var otherList = originalLists[0]
                otherList["id"] = UUID().uuidString
                var otherTracks = originalTracks
                otherTracks[0]["duration"] = 999.0
                otherList["tracks"] = otherTracks
                lists.append(otherList)
                changed["playlists"] = lists
                try rejected(changed, "同一歌曲跨列表时长冲突")
            }

            try test("运行中媒体目录被换成链接时不读写外部目标") {
                let url = root("runtime-link")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "运行边界")
                let track = try store.importTracks([source], into: id)[0]
                let audio = url.appendingPathComponent("Audio")
                let aside = url.appendingPathComponent("Audio-test-backup")
                let outside = root("runtime-outside")
                try fm.createDirectory(at: outside, withIntermediateDirectories: false)
                try fm.moveItem(at: audio, to: aside)
                try fm.createSymbolicLink(at: audio, withDestinationURL: outside)
                try rejects(.unsafePath, "运行中Audio链接读取") { _ = try store.audioURL(fileName: track.fileName) }
                try rejects(.unsafePath, "运行中Audio链接导入") { _ = try store.importTracks([source], into: id) }
                try expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "外部目录没有被写入")
                try expect(store.playlists[0].tracks.count == 1, "失败不改变原状态")
                try fm.removeItem(at: audio)
                try fm.moveItem(at: aside, to: audio)
            }

            try test("共享歌曲引用未删完时不删副本，最后引用才清理") {
                let url = root("shared")
                let store = try AudioLibraryStore(rootURL: url)
                let a = try store.createPlaylist(name: "A")
                let b = try store.createPlaylist(name: "B")
                let track = try store.importTracks([source], into: a)[0]
                let asset = try store.audioURL(fileName: track.fileName)
                let manifest = url.appendingPathComponent("audio-library.json")
                var value = try json(manifest)
                var lists = value["playlists"] as! [[String: Any]]
                lists[1]["tracks"] = lists[0]["tracks"]
                value["playlists"] = lists
                try saveJSON(value, manifest)
                let shared = try AudioLibraryStore(rootURL: url)
                try shared.removeTrack(id: track.id, from: a)
                try expect(fm.fileExists(atPath: asset.path), "B仍引用则保留")
                try expect(shared.playlists[1].tracks.count == 1, "不改其他歌单")
                try shared.removePlaylist(id: b)
                try expect(!fm.fileExists(atPath: asset.path), "最后引用移除才删副本")
                try expect(try Data(contentsOf: source) == originalBytes, "原文件始终保留")
            }

            try test("自定义提醒独立复制且不被歌单删除伤及") {
                let url = root("reminder")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "音乐")
                let track = try store.importTracks([source], into: id)[0]
                let reminder = try store.importReminder(source)
                try expect(reminder.fileName != track.fileName, "同源提醒独立副本")
                let reminderURL = try store.audioURL(fileName: reminder.fileName)
                let reopened = try AudioLibraryStore(rootURL: url)
                try reopened.removePlaylist(id: id)
                try expect(fm.fileExists(atPath: reminderURL.path), "删歌单保留提醒")
                try expect(try mediaNames(url) == [reminder.fileName], "仅剩注册提醒")
                let value = try json(url.appendingPathComponent("audio-library.json"))
                try expect(value["reminderAssets"] as? [String] == [reminder.fileName], "提醒引用有落盘登记")
            }

            try test("歌单与提醒共享旧引用时提醒仍受保护") {
                let url = root("shared-reminder")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "共享提醒")
                let track = try store.importTracks([source], into: id)[0]
                let asset = try store.audioURL(fileName: track.fileName)
                let manifest = url.appendingPathComponent("audio-library.json")
                var value = try json(manifest)
                value["reminderAssets"] = [track.fileName]
                try saveJSON(value, manifest)
                let reopened = try AudioLibraryStore(rootURL: url)
                try reopened.removePlaylist(id: id)
                try expect(fm.fileExists(atPath: asset.path), "提醒引用保护同名资产")
            }

            try test("用户误删副本后只报缺失，不读取原路径兜底") {
                let url = root("missing")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "缺失")
                let track = try store.importTracks([source], into: id)[0]
                let asset = try store.audioURL(fileName: track.fileName)
                try fm.removeItem(at: asset)
                let reopened = try AudioLibraryStore(rootURL: url)
                try expect(reopened.playlists[0].tracks.count == 1, "保留可移除的缺失条目")
                try rejects(.missingAudio, "副本缺失") { _ = try reopened.audioURL(fileName: track.fileName) }
                try reopened.removeTrack(id: track.id, from: id)
                try expect(reopened.playlists[0].tracks.isEmpty, "可安全移除缺失条目")
                try expect(try Data(contentsOf: source) == originalBytes, "不伤原音频")
            }

            try test("并发导入和提醒由同一把锁串行，清单没有覆盖丢失") {
                let url = root("concurrent")
                let store = try AudioLibraryStore(rootURL: url)
                let id = try store.createPlaylist(name: "并发")
                let queue = DispatchQueue(label: "FocusClock.AudioLibraryTests", attributes: .concurrent)
                let group = DispatchGroup()
                let resultLock = NSLock()
                var failures: [String] = []
                for index in 0..<8 {
                    group.enter()
                    queue.async {
                        defer { group.leave() }
                        do {
                            if index % 2 == 0 { _ = try store.importTracks([source], into: id) }
                            else { _ = try store.importReminder(second) }
                            _ = store.playlists
                        } catch {
                            resultLock.lock(); failures.append(error.localizedDescription); resultLock.unlock()
                        }
                    }
                }
                group.wait()
                try expect(failures.isEmpty, "并发导入不失败")
                let reopened = try AudioLibraryStore(rootURL: url)
                try expect(reopened.playlists[0].tracks.count == 4, "四首歌都保存")
                let value = try json(url.appendingPathComponent("audio-library.json"))
                try expect((value["reminderAssets"] as? [String])?.count == 4, "四提醒都保存")
                try expect(try mediaNames(url).count == 8, "八份音频与清单一致")
            }

            print("AudioLibrary：\(cases)组，\(assertions)项断言通过。未播放声音，未启动应用，测试素材仅在.build内生成并清理。")
        } catch {
            fputs("AudioLibrary测试失败：\(error)\n", stderr)
            try? fm.removeItem(at: sandbox)
            exit(1)
        }
    }
}
