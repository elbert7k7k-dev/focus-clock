import Foundation
import AppKit
import AVFoundation

private struct SelectionTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class SelectionChecks {
    private(set) var assertions = 0
    private(set) var cases = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw SelectionTestFailure(description: message) }
    }
    func rejects(_ action: () throws -> Void, _ message: String) throws {
        assertions += 1
        do { try action() } catch { return }
        throw SelectionTestFailure(description: message)
    }
    func run(_ title: String, _ body: () throws -> Void) throws {
        try body(); cases += 1; print("PASS \(title)")
    }
}

/// These tests never call play on a nonempty player, start NSApplication, or
/// touch the user's audio library. All fixtures live below this binary's .build.
@main
@MainActor
private struct MusicSelectionTestRunner {
    private static func tinyWAV() -> Data {
        var data = Data()
        func tag(_ text: String) { data.append(contentsOf: text.utf8) }
        func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func long(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let frames: UInt32 = 400
        tag("RIFF"); long(36 + frames * 2); tag("WAVEfmt "); long(16)
        word(1); word(1); long(8_000); long(16_000); word(2); word(16)
        tag("data"); long(frames * 2); data.append(Data(repeating: 0, count: Int(frames * 2)))
        return data
    }
    static func main() throws {
        let check = SelectionChecks()
        let fm = FileManager.default
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard binary.deletingLastPathComponent().lastPathComponent == ".build" else {
            throw SelectionTestFailure(description: "Run this suite from the project's .build directory")
        }
        let root = binary.deletingLastPathComponent().appendingPathComponent("music-selection-fixtures-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        func folder(_ name: String) throws -> URL {
            let path = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: path, withIntermediateDirectories: false)
            return path
        }
        func write(_ url: URL, _ text: String = "test fixture") throws -> URL {
            try Data(text.utf8).write(to: url); return url
        }
        func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }
        let source = try folder("source")
        let first = try write(source.appendingPathComponent("song1.wav"))
        let second = try write(source.appendingPathComponent("song2.mp3"))
        let tenth = try write(source.appendingPathComponent("song10.M4A"))
        let ignored = try write(source.appendingPathComponent("notes.txt"))
        _ = try write(source.appendingPathComponent(".hidden.wav"))
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedAudio = try write(nested.appendingPathComponent("nested.wav"))
        let audioNamedFolder = source.appendingPathComponent("not-a-song.mp3", isDirectory: true)
        try fm.createDirectory(at: audioNamedFolder, withIntermediateDirectories: false)
        _ = try write(audioNamedFolder.appendingPathComponent("must-not-scan.wav"))

        try check.run("explicit files retain the user's selected order") {
            let value = try PlaylistImportSelection.expand([tenth, first, second])
            try check.expect(value == [tenth, first, second], "Selected order changed")
        }
        try check.run("folder import sorts naturally and scans immediate audio only") {
            let value = try PlaylistImportSelection.expand([source])
            try check.expect(names(value) == ["song1.wav", "song2.mp3", "song10.M4A"], "Natural order, hidden filtering, or one-level scope failed")
            try check.expect(!value.contains(nestedAudio), "Nested folder was scanned")
            try check.expect(!value.contains(ignored), "Non-audio was included")
        }
        try check.run("multiple inputs preserve input groups and each folder's natural order") {
            let value = try PlaylistImportSelection.expand([nestedAudio, source])
            try check.expect(value == [nestedAudio, first, second, tenth], "Input group order changed")
        }
        try check.run("empty selection and empty folder reject") {
            let empty = try folder("empty")
            try check.rejects({ _ = try PlaylistImportSelection.expand([]) }, "Empty selection accepted")
            try check.rejects({ _ = try PlaylistImportSelection.expand([empty]) }, "Empty folder accepted")
        }
        try check.run("a folder containing only non-audio rejects") {
            let unsupported = try folder("unsupported")
            _ = try write(unsupported.appendingPathComponent("document.txt"))
            try check.rejects({ _ = try PlaylistImportSelection.expand([unsupported]) }, "Non-audio-only folder accepted")
            try check.rejects({ _ = try PlaylistImportSelection.expand([ignored]) }, "Explicit non-audio accepted")
        }
        try check.run("UTF-8 BOM and CRLF M3U preserve track order and skip comments") {
            let manifest = try write(source.appendingPathComponent("ordered.m3u8"), "\u{feff}#EXTM3U\r\n#EXTINF:10,Name\r\nsong10.M4A\r\n\r\n song1.wav \r\nsong2.mp3\r\n")
            let value = try PlaylistImportSelection.expand([manifest])
            try check.expect(value == [tenth, first, second], "BOM, comments, CRLF, or order failed")
        }
        try check.run("local M3U may explicitly include a nested file and local absolute path") {
            let manifest = try write(source.appendingPathComponent("nested.m3u"), "nested/nested.wav\n\(first.path)\n")
            let value = try PlaylistImportSelection.expand([manifest])
            try check.expect(value == [nestedAudio, first], "Valid explicit in-folder M3U reference rejected")
        }
        try check.run("comment-only local playlists reject") {
            let manifest = try write(source.appendingPathComponent("empty.m3u"), "\u{feff}#EXTM3U\n  \n# nothing\n")
            try check.rejects({ _ = try PlaylistImportSelection.expand([manifest]) }, "Empty M3U accepted")
        }
        try check.run("remote input URLs and remote file authorities reject") {
            for url in [URL(string: "https://example.invalid/song.mp3")!, URL(string: "file://remote.invalid\(first.path)")!] {
                try check.rejects({ _ = try PlaylistImportSelection.expand([url]) }, "Remote input accepted")
            }
        }
        try check.run("file URLs carrying queries or fragments reject") {
            for suffix in ["?stream=1", "#fragment"] {
                let url = URL(string: first.absoluteString + suffix)!
                try check.rejects({ _ = try PlaylistImportSelection.expand([url]) }, "Decorated file URL accepted")
            }
        }
        try check.run("remote or file URI entries in M3U reject before importing") {
            for (index, entry) in ["https://example.invalid/a.mp3", "http://example.invalid/a.mp3", first.absoluteString].enumerated() {
                let manifest = try write(source.appendingPathComponent("remote\(index).m3u"), entry)
                try check.rejects({ _ = try PlaylistImportSelection.expand([manifest]) }, "URI entry accepted")
            }
        }
        try check.run("M3U rejects parent traversal home shorthand and absolute outside paths") {
            let outside = try write(root.appendingPathComponent("outside.wav"))
            let sibling = try folder("source-escape")
            let siblingAudio = try write(sibling.appendingPathComponent("outside.wav"))
            for (index, entry) in ["../outside.wav", "~/outside.wav", outside.path, siblingAudio.path].enumerated() {
                let manifest = try write(source.appendingPathComponent("escape\(index).m3u"), entry)
                try check.rejects({ _ = try PlaylistImportSelection.expand([manifest]) }, "Escaping M3U reference accepted")
            }
        }
        try check.run("M3U rejects non-audio directory and missing references") {
            for (index, entry) in ["notes.txt", "not-a-song.mp3", "missing.wav"].enumerated() {
                let manifest = try write(source.appendingPathComponent("invalid\(index).m3u"), entry)
                try check.rejects({ _ = try PlaylistImportSelection.expand([manifest]) }, "Invalid referenced file accepted")
            }
        }
        try check.run("oversized or non-UTF8 local manifests reject") {
            let large = source.appendingPathComponent("large.m3u")
            try Data(repeating: 35, count: 262_145).write(to: large)
            let badEncoding = source.appendingPathComponent("bad-encoding.m3u8")
            try Data([0xff, 0xfe, 0xfd]).write(to: badEncoding)
            try check.rejects({ _ = try PlaylistImportSelection.expand([large]) }, "Oversized M3U accepted")
            try check.rejects({ _ = try PlaylistImportSelection.expand([badEncoding]) }, "Invalid UTF8 M3U accepted")
        }
        try check.run("direct audio and folder symbolic links reject") {
            let fileLink = root.appendingPathComponent("file-link.wav")
            let folderLink = root.appendingPathComponent("folder-link")
            try fm.createSymbolicLink(at: fileLink, withDestinationURL: first)
            try fm.createSymbolicLink(at: folderLink, withDestinationURL: source)
            try check.rejects({ _ = try PlaylistImportSelection.expand([fileLink]) }, "Audio symlink accepted")
            try check.rejects({ _ = try PlaylistImportSelection.expand([folderLink]) }, "Folder symlink accepted")
            try check.rejects({ _ = try PlaylistImportSelection.expand([folderLink.appendingPathComponent("song1.wav")]) }, "Symlink ancestor accepted")
        }
        try check.run("audio symlink within an explicitly selected directory rejects") {
            let directory = try folder("linked-children")
            try fm.createSymbolicLink(at: directory.appendingPathComponent("linked.wav"), withDestinationURL: first)
            try check.rejects({ _ = try PlaylistImportSelection.expand([directory]) }, "Directory child symlink accepted")
        }
        try check.run("M3U symlink references and symlink ancestor references reject") {
            let linked = source.appendingPathComponent("linked.wav")
            try fm.createSymbolicLink(at: linked, withDestinationURL: first)
            let folderLink = source.appendingPathComponent("linked-nested")
            try fm.createSymbolicLink(at: folderLink, withDestinationURL: nested)
            for (index, entry) in ["linked.wav", "linked-nested/nested.wav"].enumerated() {
                let manifest = try write(source.appendingPathComponent("linked-manifest\(index).m3u"), entry)
                try check.rejects({ _ = try PlaylistImportSelection.expand([manifest]) }, "Linked M3U reference accepted")
            }
        }
        try check.run("the M3U file itself may not be a symlink") {
            let target = try write(root.appendingPathComponent("real.m3u"), first.path)
            let linked = root.appendingPathComponent("manifest-link.m3u")
            try fm.createSymbolicLink(at: linked, withDestinationURL: target)
            try check.rejects({ _ = try PlaylistImportSelection.expand([linked]) }, "M3U symlink accepted")
        }
        try check.run("100 files are accepted and 101 explicit inputs reject") {
            let many = try folder("many")
            var files: [URL] = []
            for index in 1...101 { files.append(try write(many.appendingPathComponent("track\(index).wav"))) }
            let accepted = try PlaylistImportSelection.expand(Array(files.prefix(100)))
            try check.expect(accepted.count == 100, "Exactly 100 files rejected")
            try check.rejects({ _ = try PlaylistImportSelection.expand(files) }, "101 explicit files accepted")
            try check.rejects({ _ = try PlaylistImportSelection.expand([many]) }, "101 directory files accepted")
        }
        try check.run("M3U aggregate count cannot bypass the 100-track limit") {
            let manifest = try write(source.appendingPathComponent("many.m3u"), Array(repeating: "song1.wav", count: 101).joined(separator: "\n"))
            try check.rejects({ _ = try PlaylistImportSelection.expand([manifest]) }, "Oversized M3U track list accepted")
        }
        try check.run("controller starts silent and nonempty playlist loading does not resolve audio") {
            let controller = FocusMusicController()
            var resolutions = 0
            controller.resolveURL = { _ in resolutions += 1; return first }
            let track = LibraryTrack(id: UUID(), fileName: "fixture.wav", title: "Fixture", duration: 1)
            let list = FocusPlaylist(id: UUID(), name: "Test", tracks: [track])
            try check.expect(!controller.isPlaying && controller.currentTrack == nil, "Fresh controller is active")
            controller.loadPlaylist(list)
            try check.expect(controller.playlistID == list.id && controller.tracks == [track], "Loaded playlist identity differs")
            try check.expect(!controller.isPlaying && controller.currentIndex == nil, "Loading started playback")
            try check.expect(resolutions == 0 && controller.elapsed == 0 && controller.duration == 0, "Loading accessed audio")
        }
        try check.run("switching reloading pausing and changing music preferences never auto-play") {
            let controller = FocusMusicController()
            var resolutions = 0
            var changes = 0
            controller.resolveURL = { _ in resolutions += 1; return first }
            controller.onChange = { changes += 1 }
            let track = LibraryTrack(id: UUID(), fileName: "fixture.wav", title: "Fixture", duration: 1)
            let list = FocusPlaylist(id: UUID(), name: "Test", tracks: [track])
            controller.loadPlaylist(list); controller.loadPlaylist(list)
            controller.volume = 0.7; controller.isDucked = true; controller.loopMode = .single
            controller.pause(); controller.stop()
            controller.loadPlaylist(FocusPlaylist(id: UUID(), name: "Other", tracks: [track]))
            controller.loadPlaylist(nil)
            try check.expect(!controller.isPlaying && controller.currentTrack == nil, "A state-only operation started playback")
            try check.expect(controller.playlistID == nil && controller.tracks.isEmpty, "Cleared playlist retained tracks")
            try check.expect(resolutions == 0 && changes > 0, "State changes resolved audio or failed to notify")
        }
        try check.run("invalid track indices and empty-list commands do not resolve or play audio") {
            let controller = FocusMusicController()
            var resolutions = 0
            controller.resolveURL = { _ in resolutions += 1; return first }
            controller.playTrack(at: -1); controller.playTrack(at: Int.max)
            controller.next(); controller.previous(); controller.play()
            try check.expect(!controller.isPlaying && resolutions == 0, "Invalid/empty commands reached audio")
            try check.expect(controller.lastError != nil, "Empty play should explain missing music")
            controller.stop(); controller.pause()
            try check.expect(!controller.isPlaying, "Stop or pause activated audio")
        }
        try check.run("actual private import and reopening retain tracks without starting playback") {
            let input = root.appendingPathComponent("tiny.wav")
            try tinyWAV().write(to: input)
            let storeRoot = root.appendingPathComponent("private-library", isDirectory: true)
            let store = try AudioLibraryStore(rootURL: storeRoot)
            let playlistID = try store.createPlaylist(name: "Import test")
            let imported = try store.importTracks(PlaylistImportSelection.expand([input]), into: playlistID)
            let controller = FocusMusicController()
            var resolutions = 0
            controller.resolveURL = { name in resolutions += 1; return try store.audioURL(fileName: name) }
            controller.loadPlaylist(store.playlists.first)
            try check.expect(imported.count == 1 && imported[0].duration > 0, "Tiny audio was not imported")
            try check.expect(!controller.isPlaying && resolutions == 0, "Import/loading started playback")
            let reopened = try AudioLibraryStore(rootURL: storeRoot)
            controller.loadPlaylist(reopened.playlists.first)
            try check.expect(reopened.playlists == store.playlists, "Reopened track list differs")
            try check.expect(!controller.isPlaying && resolutions == 0, "Reopening started playback")
            let retainedInput = try Data(contentsOf: input)
            try check.expect(retainedInput == tinyWAV(), "Import modified the source fixture")
        }
        print("MusicSelection: \(check.cases) cases, \(check.assertions) assertions passed; no audio was played.")
    }
}
