import AppKit
import UniformTypeIdentifiers

@MainActor
private final class MusicDropView: NSView {
    var onFiles: (([URL]) -> Void)?
    var isEnabled = true
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isEnabled && files(sender).isEmpty == false ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        guard isEnabled, !urls.isEmpty else { return false }
        onFiles?(urls); return true
    }
    private func files(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

@MainActor
final class PlaylistViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var store: AudioLibraryStore?
    var player: FocusMusicController?
    var onLibraryChange: (() -> Void)?
    private let playlistPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let nowPlaying = NSTextField(labelWithString: "尚未播放")
    private let volume = NSSlider(value: 0.35, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let loops = NSSegmentedControl(labels: ["列表循环", "单曲循环"], trackingMode: .selectOne, target: nil, action: nil)
    private let follows = NSButton(checkboxWithTitle: "随专注开始 / 暂停", target: nil, action: nil)
    private let playButton = NSButton(title: "播放", target: nil, action: nil)
    private let drop = MusicDropView(frame: .zero)
    private var controls: [NSControl] = []
    private var busy = false
    private var libraryWarning: String?
    private var selectedPlaylist: FocusPlaylist? {
        guard let store else { return nil }
        return store.playlists.first { $0.id == store.selectedPlaylistID }
    }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 510))
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(srgbRed: 0.985, green: 0.976, blue: 0.957, alpha: 1).cgColor
        label("专注歌单", NSRect(x: 24, y: 466, width: 550, height: 28), size: 22, bold: true)
        label("载入本机音乐，按你的顺序循环播放", NSRect(x: 24, y: 442, width: 550, height: 20))
        playlistPopup.frame = NSRect(x: 20, y: 403, width: 342, height: 28)
        playlistPopup.target = self; playlistPopup.action = #selector(playlistChanged)
        playlistPopup.setAccessibilityLabel("当前专注歌单")
        view.addSubview(playlistPopup); controls.append(playlistPopup)
        button("新歌单", NSRect(x: 370, y: 402, width: 92, height: 29), #selector(createPlaylist))
        button("删除歌单", NSRect(x: 466, y: 402, width: 110, height: 29), #selector(deletePlaylist))
        drop.frame = NSRect(x: 24, y: 328, width: 552, height: 66)
        drop.wantsLayer = true; drop.layer?.cornerRadius = 10
        drop.layer?.backgroundColor = NSColor(srgbRed: 0.91, green: 0.95, blue: 0.93, alpha: 1).cgColor
        let hint = NSTextField(labelWithString: "把音乐、音乐文件夹或本地歌单拖到这里")
        hint.frame = NSRect(x: 14, y: 35, width: 410, height: 18)
        hint.font = .systemFont(ofSize: 13, weight: .medium); drop.addSubview(hint)
        let formats = NSTextField(labelWithString: "MP3 · M4A · WAV · AIFF · CAF · M3U")
        formats.frame = NSRect(x: 14, y: 13, width: 405, height: 17)
        formats.font = .systemFont(ofSize: 11); formats.textColor = .secondaryLabelColor; drop.addSubview(formats)
        let add = NSButton(title: "载入音乐", target: self, action: #selector(chooseFiles))
        add.frame = NSRect(x: 426, y: 18, width: 112, height: 30); add.bezelStyle = .rounded
        drop.addSubview(add); controls.append(add); view.addSubview(drop)
        drop.onFiles = { [weak self] urls in self?.importFiles(urls) }
        let trackColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        trackColumn.title = "歌曲"; trackColumn.width = 437
        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("duration"))
        timeColumn.title = "时长"; timeColumn.width = 80
        table.addTableColumn(trackColumn); table.addTableColumn(timeColumn)
        table.dataSource = self; table.delegate = self
        table.rowHeight = 28; table.usesAlternatingRowBackgroundColors = true
        table.target = self; table.doubleAction = #selector(playSelected)
        table.setAccessibilityLabel("专注歌曲列表，双击播放")
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 140, width: 552, height: 176))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        view.addSubview(scroll)
        nowPlaying.frame = NSRect(x: 24, y: 111, width: 440, height: 20)
        nowPlaying.lineBreakMode = .byTruncatingMiddle
        nowPlaying.font = .systemFont(ofSize: 12, weight: .medium); view.addSubview(nowPlaying)
        button("移除歌曲", NSRect(x: 476, y: 106, width: 100, height: 28), #selector(removeSelected))
        button("上一首", NSRect(x: 20, y: 70, width: 80, height: 29), #selector(previous))
        playButton.frame = NSRect(x: 102, y: 70, width: 80, height: 29)
        playButton.bezelStyle = .rounded; playButton.target = self; playButton.action = #selector(toggle)
        playButton.setAccessibilityLabel("播放或暂停音乐"); view.addSubview(playButton); controls.append(playButton)
        button("下一首", NSRect(x: 184, y: 70, width: 80, height: 29), #selector(next))
        loops.frame = NSRect(x: 316, y: 70, width: 260, height: 28)
        loops.target = self; loops.action = #selector(preferencesChanged); view.addSubview(loops); controls.append(loops)
        label("音乐音量", NSRect(x: 24, y: 39, width: 70, height: 18), size: 11)
        volume.frame = NSRect(x: 94, y: 35, width: 180, height: 24)
        volume.target = self; volume.action = #selector(preferencesChanged)
        volume.setAccessibilityLabel("专注音乐音量"); view.addSubview(volume); controls.append(volume)
        follows.frame = NSRect(x: 316, y: 34, width: 260, height: 25)
        follows.target = self; follows.action = #selector(preferencesChanged); view.addSubview(follows); controls.append(follows)
        status.frame = NSRect(x: 24, y: 7, width: 552, height: 22)
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor; view.addSubview(status)
        if busy { setInstallationState(true) } else { reloadLibrary() }
    }
    private func label(_ title: String, _ frame: NSRect, size: CGFloat = 12, bold: Bool = false) {
        let field = NSTextField(labelWithString: title); field.frame = frame
        field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        field.textColor = bold ? NSColor(srgbRed: 0.12, green: 0.20, blue: 0.31, alpha: 1) : .secondaryLabelColor
        view.addSubview(field)
    }
    private func button(_ title: String, _ frame: NSRect, _ action: Selector) {
        let b = NSButton(title: title, target: self, action: action); b.frame = frame; b.bezelStyle = .rounded
        view.addSubview(b); controls.append(b)
    }
    func reloadLibrary() {
        guard isViewLoaded, !busy else { return }
        playlistPopup.removeAllItems()
        for list in store?.playlists ?? [] {
            playlistPopup.addItem(withTitle: list.name)
            playlistPopup.lastItem?.representedObject = list.id.uuidString
        }
        if let id = store?.selectedPlaylistID,
           let index = store?.playlists.firstIndex(where: { $0.id == id }) { playlistPopup.selectItem(at: index) }
        if playlistPopup.numberOfItems == 0 { playlistPopup.addItem(withTitle: "尚未添加歌单") }
        volume.doubleValue = store?.musicVolume ?? 0.35
        loops.selectedSegment = store?.loopMode == .single ? 1 : 0
        follows.state = store?.followsFocusTimer == true ? .on : .off
        table.reloadData(); refreshPlayback()
    }
    func refreshPlayback() {
        guard isViewLoaded, !busy else { return }
        playButton.title = player?.isPlaying == true ? "暂停" : "播放"
        nowPlaying.stringValue = player?.currentTrack.map { "\(player?.isPlaying == true ? "正在播放" : "已暂停") · \($0.title)" } ?? "尚未播放"
        if let error = libraryWarning ?? player?.lastError { status.stringValue = error; status.textColor = .systemRed }
        else {
            status.stringValue = "仅保存本机副本 · 到点时降低音乐音量 · 退出后不自动播放"
            status.textColor = .secondaryLabelColor
        }
    }
    func setInstallationState(_ installing: Bool, error: String? = nil) {
        busy = installing
        libraryWarning = error
        guard isViewLoaded else { return }
        controls.forEach { $0.isEnabled = !installing }
        drop.isEnabled = !installing
        if installing {
            status.stringValue = "正在准备内置音乐…"; status.textColor = .secondaryLabelColor
        } else { reloadLibrary() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { busy ? 0 : selectedPlaylist?.tracks.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !busy, let list = selectedPlaylist, list.tracks.indices.contains(row) else { return nil }
        let track = list.tracks[row]
        let text: String
        if tableColumn?.identifier.rawValue == "duration" {
            let seconds = Int(track.duration.rounded()); text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        } else { text = "\(row + 1). \(track.title)" }
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle; field.toolTip = track.title
        return field
    }
    private func operation(_ body: () throws -> Void) {
        guard !busy else { return }
        do { try body(); onLibraryChange?(); reloadLibrary() } catch { show(error) }
    }
    private func show(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "歌单未能更新"; alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    @objc private func createPlaylist() {
        guard !busy, let store else { return }
        let alert = NSAlert(); alert.messageText = "新歌单"; alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: "我的歌单"); field.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        operation { _ = try store.createPlaylist(name: field.stringValue) }
    }
    @objc private func deletePlaylist() {
        guard let list = selectedPlaylist, let store else { return }
        let alert = NSAlert(); alert.messageText = "删除“\(list.name)”？"
        alert.informativeText = "仅移除本工具里的歌单及其导入副本，原始音乐文件保留。"
        alert.addButton(withTitle: "删除歌单"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        player?.stop(); operation { try store.removePlaylist(id: list.id) }
    }
    @objc private func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.title = "载入专注音乐或本地歌单"
        guard panel.runModal() == .OK else { return }; importFiles(panel.urls)
    }
    private func importFiles(_ urls: [URL]) {
        guard !busy, let store else { return }
        do {
            let files = try PlaylistImportSelection.expand(urls)
            let id = try selectedPlaylist?.id ?? store.createPlaylist(name: "我的歌单")
            busy = true; controls.forEach { $0.isEnabled = false }; drop.isEnabled = false
            status.stringValue = "正在载入 \(files.count) 首音乐…"; status.textColor = .secondaryLabelColor
            // Decoding/probing and copying user-selected audio can be slow.
            // During this single import, library mutations and reads in this
            // view are disabled; the timer and cached playback remain active.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try store.importTracks(files, into: id) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = false; self.controls.forEach { $0.isEnabled = true }; self.drop.isEnabled = true
                    self.onLibraryChange?(); self.reloadLibrary()
                    if case .failure(let error) = result { self.show(error) }
                }
            }
        } catch { show(error) }
    }
    @objc private func playlistChanged() {
        guard let store, let text = playlistPopup.selectedItem?.representedObject as? String, let id = UUID(uuidString: text) else { return }
        operation { try store.savePreferences(selected: id, volume: volume.doubleValue,
            loop: loops.selectedSegment == 1 ? .single : .playlist, followsTimer: follows.state == .on) }
    }
    @objc private func preferencesChanged() {
        guard let store else { return }
        operation { try store.savePreferences(selected: store.selectedPlaylistID, volume: volume.doubleValue,
            loop: loops.selectedSegment == 1 ? .single : .playlist, followsTimer: follows.state == .on) }
    }
    @objc private func removeSelected() {
        guard let store, let list = selectedPlaylist, list.tracks.indices.contains(table.selectedRow) else { return }
        let track = list.tracks[table.selectedRow]
        if player?.currentTrack?.id == track.id { player?.stop() }
        operation { try store.removeTrack(id: track.id, from: list.id) }
    }
    @objc private func playSelected() { if !busy { player?.playTrack(at: table.clickedRow) } }
    @objc private func toggle() { player?.toggle() }
    @objc private func previous() { player?.previous() }
    @objc private func next() { player?.next() }
}
