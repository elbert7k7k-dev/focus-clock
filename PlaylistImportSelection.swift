import Foundation

/// Expands only explicitly supplied files and the immediate audio children of
/// selected folders. Local M3U references must stay inside the manifest folder.
/// Every referenced path component is checked without enumerating its parents.
enum PlaylistImportSelection {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf"]
    private static let maximumCount = 100
    private static let maximumManifestBytes = 262_144

    static func expand(_ urls: [URL]) throws -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            let type = try pathTypeWithoutLinks(url)
            if type == .typeDirectory {
                let children = try fm.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for child in children {
                    // A nested folder is never traversed, even if its name ends
                    // in .mp3. A symbolic link fails before its target is read.
                    let childType = try pathTypeWithoutLinks(child)
                    if childType == .typeDirectory { continue }
                    try appendAudio(child, to: &result)
                }
            } else if ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
                guard type == .typeRegular else { throw SelectionError.invalid("请载入实际的本地歌单文件。") }
                let size = try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                guard let size, size.intValue <= maximumManifestBytes else {
                    throw SelectionError.invalid("歌单清单过大，请直接选择音频文件。")
                }
                let data = try Data(contentsOf: url)
                guard data.count <= maximumManifestBytes, let text = String(data: data, encoding: .utf8) else {
                    throw SelectionError.invalid("歌单须为不超过256KB的UTF-8本地M3U文件。")
                }
                let parent = url.deletingLastPathComponent().standardizedFileURL
                let prefix = parent.path == "/" ? "/" : parent.path + "/"
                for raw in text.components(separatedBy: .newlines) {
                    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
                    if line.isEmpty || line.hasPrefix("#") { continue }
                    guard !line.contains("://"), !line.hasPrefix("~"), !line.contains("\0"),
                          !(line as NSString).pathComponents.contains("..") else {
                        throw SelectionError.invalid("歌单只可引用所在文件夹里的本机音乐，不使用在线链接或上级路径。")
                    }
                    let item = line.hasPrefix("/") ? URL(fileURLWithPath: line)
                        : parent.appendingPathComponent(line)
                    let normalized = item.standardizedFileURL
                    guard normalized.path.hasPrefix(prefix) else {
                        throw SelectionError.invalid("歌单只能引用其所在文件夹内的本机音频。")
                    }
                    try appendAudio(item, to: &result)
                }
            } else {
                try appendAudio(url, to: &result)
            }
        }
        guard !result.isEmpty else {
            throw SelectionError.invalid("没有找到支持的音频。可拖入音乐、多首歌曲、音乐文件夹或本地M3U歌单。")
        }
        return result
    }

    private static func appendAudio(_ url: URL, to result: inout [URL]) throws {
        guard audioExtensions.contains(url.pathExtension.lowercased()) else {
            throw SelectionError.invalid("只支持MP3、M4A、WAV、AIFF、AIF和CAF本机音频。")
        }
        guard try pathTypeWithoutLinks(url) == .typeRegular else {
            throw SelectionError.invalid("请载入实际音频文件，不使用子文件夹或链接。")
        }
        guard result.count < maximumCount else {
            throw SelectionError.invalid("每次最多载入100首，请分批添加。")
        }
        result.append(url.standardizedFileURL)
    }

    private static func pathTypeWithoutLinks(_ url: URL) throws -> FileAttributeType {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.contains("\0") else {
            throw SelectionError.invalid("只支持本机音频，不支持在线歌单链接。")
        }
        let components = (url.path as NSString).pathComponents
        guard components.first == "/", !components.contains(".."), !components.contains(".") else {
            throw SelectionError.invalid("请使用实际的本机文件路径。")
        }
        var path = "/"
        var result: FileAttributeType = .typeDirectory
        for (index, component) in components.dropFirst().enumerated() {
            path = (path as NSString).appendingPathComponent(component)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let type = attributes[.type] as? FileAttributeType, type != .typeSymbolicLink else {
                throw SelectionError.invalid("请拖入实际音频或文件夹，不使用替身链接或带链接的路径。")
            }
            if index < components.count - 2, type != .typeDirectory {
                throw SelectionError.invalid("音频的上级路径不是实际文件夹。")
            }
            result = type
        }
        return result
    }

    enum SelectionError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }
}
