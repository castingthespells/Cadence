import Foundation
import AVFoundation
import AppKit
import Combine


func dbg(_ message: String) {
    guard ProcessInfo.processInfo.environment["CADENCE_DEBUG"] != nil else { return }
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/cadence.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

final class PlayerModel: NSObject, ObservableObject {

    // 曲库
    @Published private(set) var tracks: [Track] = []
    @Published var roots: [URL] = []
    @Published var selectedRoot: URL?
    @Published var searchText: String = ""
    @Published var isScanning = false

    // 播放状态
    @Published var currentID: String?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var artwork: NSImage?
    @Published var errorText: String?

    // 设置
    @Published var volume: Double = 0.8 {
        didSet {
            playerNode.volume = Float(volume)
            UserDefaults.standard.set(volume, forKey: Keys.volume)
        }
    }
    @Published var repeatMode: RepeatMode = .all {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: Keys.repeatMode) }
    }
    @Published var shuffleMode: ShuffleMode = .off {
        didSet { UserDefaults.standard.set(shuffleMode.rawValue, forKey: Keys.shuffle) }
    }
    @Published var showMeters = false {
        didSet {
            UserDefaults.standard.set(showMeters, forKey: Keys.showMeters)
            if showMeters { meter.start() } else { meter.stop() }
        }
    }
    @Published var showingStats = false
    @Published var showingSync = false
    @Published var statsRevision = 0

    // 音频
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var generation = 0
    private var playStartTime: Double = 0
    let analyzer = AudioAnalyzer()
    let sync = SyncEngine()
    private var applyingRemote = false
    private var lastSyncSeek = Date.distantPast
    lazy var meter = MeterModel(analyzer: analyzer)

    // 计时与统计
    private var timer: Timer?
    private var scrubbing = false
    private var lastTick = Date()
    private var scanGeneration = 0
    private var session: Session?

    private struct Session {
        let path: String
        let title: String
        let artist: String?
        let duration: Double
        let startedAt: Date
        var listened: Double
    }

    // 随机与历史
    private var bag: [String] = []
    private var history: [String] = []

    private enum Keys {
        static let roots = "roots"
        static let volume = "volume"
        static let repeatMode = "repeatMode"
        static let shuffle = "shuffle"
        static let showMeters = "showMeters"
    }

    override init() {
        super.init()
        let defaults = UserDefaults.standard

        if let saved = defaults.array(forKey: Keys.roots) as? [String] {
            roots = saved.map { URL(fileURLWithPath: $0) }
        }
        if defaults.object(forKey: Keys.volume) != nil {
            volume = defaults.double(forKey: Keys.volume)
        }
        if let raw = defaults.string(forKey: Keys.repeatMode), let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        if let raw = defaults.string(forKey: Keys.shuffle), let mode = ShuffleMode(rawValue: raw) {
            shuffleMode = mode
        }
        showMeters = defaults.bool(forKey: Keys.showMeters)

        setupEngine()

        // init 里赋值不触发 didSet，得手动把仪表的数据泵打开，
        // 否则上次退出时仪表是展开的，这次启动就会一直空着。
        if showMeters { meter.start() }

        sync.snapshot = { [weak self] in self?.currentSnapshot() }
        sync.onRemote = { [weak self] remote in self?.applyRemote(remote) }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.finalizeSession(completed: false)
        }

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !self.engine.isRunning {
                try? self.engine.start()
            }
        }

        let launchArgs = ProcessInfo.processInfo.arguments
        if let index = launchArgs.firstIndex(of: "--sync-join"), index + 1 < launchArgs.count {
            let code = launchArgs[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.sync.joinRoom(code)
            }
        }
        if launchArgs.contains("--sync-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.showingSync = true
            }
        }
        if launchArgs.contains("--sync-create") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.sync.createRoom()
            }
        }

        if !roots.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.rescan() }
        }
        if showMeters {
            DispatchQueue.main.async { [weak self] in self?.meter.start() }
        }
    }

    // MARK: - 引擎

    private func setupEngine() {
        engine.attach(playerNode)

        let initialFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        engine.connect(playerNode, to: engine.mainMixerNode, format: initialFormat)
        engine.mainMixerNode.outputVolume = 1
        playerNode.volume = Float(volume)

        do {
            try engine.start()
        } catch {
            errorText = "音频引擎启动失败：\(error.localizedDescription)"
            return
        }

        let tapFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else { return }

        let analyzerRef = analyzer
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
            analyzerRef.feed(buffer)
        }
    }

    private func startPlayback(_ track: Track) throws {
        let newFile = try AVAudioFile(forReading: track.url)

        playerNode.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: newFile.processingFormat)
        if !engine.isRunning {
            try engine.start()
        }

        file = newFile
        analyzer.reset()
        duration = Double(newFile.length) / newFile.processingFormat.sampleRate
        scheduleSegment(fromFrame: 0)
    }

    private func scheduleSegment(fromFrame startFrame: AVAudioFramePosition) {
        guard let file else { return }
        let total = file.length
        var start = startFrame
        if start < 0 { start = 0 }
        if start >= total { start = 0 }

        let remaining = AVAudioFrameCount(max(1, total - start))
        playStartTime = Double(start) / file.processingFormat.sampleRate

        generation += 1
        let currentGeneration = generation
        playerNode.scheduleSegment(
            file,
            startingFrame: start,
            frameCount: remaining,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleCompletion(generation: currentGeneration)
            }
        }
        playerNode.play()
        isPlaying = true
    }

    private func handleCompletion(generation completedGeneration: Int) {
        dbg("completion gen=\(completedGeneration) cur=\(generation)")
        guard completedGeneration == generation else { return }
        guard currentTrack != nil else {
            isPlaying = false
            return
        }
        if sync.active && !sync.isAuthor {
            // 跟随者不自己切歌：等对方的状态消息告诉我们下一首是什么
            isPlaying = false
            return
        }
        finalizeSession(completed: true)
        advanceAfterFinish()
        didLocalChange()
    }

    // MARK: - 计算属性

    var visibleTracks: [Track] {
        var list = tracks
        if let root = selectedRoot {
            list = list.filter { $0.rootPath == root.path }
        }
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(keyword)
                || ($0.artist ?? "").localizedCaseInsensitiveContains(keyword)
            }
        }
        return list
    }

    var currentTrack: Track? {
        guard let id = currentID else { return nil }
        return tracks.first { $0.id == id }
    }

    var totalDuration: Double {
        tracks.compactMap { $0.duration }.reduce(0, +)
    }

    func count(in root: URL) -> Int {
        tracks.filter { $0.rootPath == root.path }.count
    }

    // MARK: - 曲库

    func addRoots(_ urls: [URL]) {
        var changed = false
        for url in urls {
            let path = url.standardizedFileURL.path
            if !roots.contains(where: { $0.path == path }) {
                roots.append(URL(fileURLWithPath: path))
                changed = true
            }
        }
        if changed {
            saveRoots()
            rescan()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择一个放音乐的文件夹"
        if panel.runModal() == .OK {
            addRoots(panel.urls)
        }
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0.path == url.path }
        if selectedRoot?.path == url.path { selectedRoot = nil }
        saveRoots()
        rescan()
    }

    private func saveRoots() {
        UserDefaults.standard.set(roots.map { $0.path }, forKey: Keys.roots)
    }

    func rescan() {
        let currentRoots = roots
        scanGeneration += 1
        let generation = scanGeneration

        guard !currentRoots.isEmpty else {
            tracks = []
            isScanning = false
            return
        }

        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Library.scan(roots: currentRoots)
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                let previousID = self.currentID
                self.tracks = found
                self.isScanning = false
                self.bag.removeAll()
                dbg("rescan done found=\(found.count) prev=\(previousID ?? "nil")")
                if let previousID, !found.contains(where: { $0.id == previousID }) {
                    self.stop()
                }
                self.startMetadataPass(generation: generation)

                if ProcessInfo.processInfo.arguments.contains("--debug-autoplay"),
                   self.currentID == nil,
                   let first = self.visibleTracks.first {
                    self.playTrack(first, pushHistory: true)
                }
            }
        }
    }

    private func startMetadataPass(generation: Int) {
        let snapshot = tracks
        guard !snapshot.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var index = 0
            let batchSize = 8
            while index < snapshot.count {
                if let self, self.scanGeneration != generation { return }
                let upper = min(index + batchSize, snapshot.count)
                let batch = Array(snapshot[index..<upper])
                let group = DispatchGroup()
                var results: [String: TrackMeta] = [:]
                let lock = NSLock()

                for track in batch {
                    group.enter()
                    Task.detached {
                        let meta = await Library.metadata(for: track.url)
                        lock.lock()
                        results[track.id] = meta
                        lock.unlock()
                        group.leave()
                    }
                }
                group.wait()

                let collected = results
                DispatchQueue.main.async {
                    self?.apply(collected, generation: generation)
                }
                index = upper
            }
        }
    }

    private func apply(_ metas: [String: TrackMeta], generation: Int) {
        guard scanGeneration == generation, !metas.isEmpty else { return }
        var updated = tracks
        for i in updated.indices {
            guard let meta = metas[updated[i].id] else { continue }
            if let title = meta.title { updated[i].title = title }
            if let artist = meta.artist { updated[i].artist = artist }
            if let duration = meta.duration {
                updated[i].duration = duration
            }
        }
        tracks = updated
    }

    // MARK: - 播放控制

    func play(_ track: Track) {
        defer { didLocalChange() }
        playTrack(track, pushHistory: true)
    }

    private func playTrack(_ track: Track, pushHistory: Bool) {
        dbg("playTrack \(track.url.lastPathComponent)")
        do {
            try startPlayback(track)
        } catch {
            dbg("playTrack FAILED \(error)")
            errorText = "这个文件解不开：\(track.url.lastPathComponent)"
            isPlaying = false
            return
        }

        finalizeSession(completed: false)

        currentID = track.id
        currentTime = 0
        artwork = nil
        errorText = nil
        ensureTimer()
        loadArtwork(for: track)

        session = Session(
            path: track.url.path,
            title: track.title,
            artist: track.artist,
            duration: duration,
            startedAt: Date(),
            listened: 0
        )
        lastTick = Date()

        if pushHistory {
            history.append(track.id)
            if history.count > 200 { history.removeFirst() }
        }
    }

    func togglePlay() {
        defer { didLocalChange() }
        guard file != nil else {
            if let first = visibleTracks.first { playTrack(first, pushHistory: true) }
            return
        }
        if isPlaying {
            updateCurrentTime()
            playerNode.pause()
            isPlaying = false
        } else {
            playerNode.play()
            isPlaying = true
            lastTick = Date()
        }
    }

    func stop() {
        dbg("stop called")
        generation += 1
        playerNode.stop()
        file = nil
        isPlaying = false
        currentID = nil
        currentTime = 0
        duration = 0
        artwork = nil
        analyzer.reset()
        timer?.invalidate()
        timer = nil
        finalizeSession(completed: false)
    }

    func next() {
        defer { didLocalChange() }
        let list = visibleTracks
        guard !list.isEmpty else { return }

        if shuffleMode != .off, let id = nextShuffledID(in: list),
           let track = tracks.first(where: { $0.id == id }) {
            playTrack(track, pushHistory: true)
            return
        }

        guard let id = currentID, let index = list.firstIndex(where: { $0.id == id }) else {
            playTrack(list[0], pushHistory: true)
            return
        }
        let nextIndex = index + 1
        playTrack(list[nextIndex < list.count ? nextIndex : 0], pushHistory: true)
    }

    func previous() {
        defer { didLocalChange() }
        if currentTime > 3, file != nil {
            seek(to: 0)
            return
        }

        if shuffleMode != .off, history.count >= 2 {
            let previousID = history[history.count - 2]
            if let track = tracks.first(where: { $0.id == previousID }) {
                playTrack(track, pushHistory: false)
                if !history.isEmpty { history.removeLast() }
                return
            }
        }

        let list = visibleTracks
        guard !list.isEmpty else { return }
        guard let id = currentID, let index = list.firstIndex(where: { $0.id == id }) else {
            playTrack(list[0], pushHistory: true)
            return
        }
        playTrack(list[index > 0 ? index - 1 : list.count - 1], pushHistory: true)
    }

    func seek(to time: Double) {
        defer { didLocalChange() }
        guard let file else { return }
        let clamped = max(0, min(time, duration))
        let wasPlaying = isPlaying

        generation += 1
        playerNode.stop()

        let frame = AVAudioFramePosition(clamped * file.processingFormat.sampleRate)
        scheduleSegment(fromFrame: frame)
        currentTime = clamped

        if !wasPlaying {
            playerNode.pause()
            isPlaying = false
        }
    }

    func setScrubbing(_ value: Bool) {
        scrubbing = value
        if !value { seek(to: currentTime) }
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
    }

    func cycleShuffle() {
        switch shuffleMode {
        case .off: shuffleMode = .fair
        case .fair: shuffleMode = .pure
        case .pure: shuffleMode = .off
        }
        bag.removeAll()
    }

    private func advanceAfterFinish() {
        let list = visibleTracks
        dbg("advance list=\(list.count) repeat=\(repeatMode.rawValue) shuffle=\(shuffleMode.rawValue) cur=\(currentID ?? "nil")")
        guard !list.isEmpty else {
            isPlaying = false
            return
        }

        if repeatMode == .one, let track = currentTrack {
            playTrack(track, pushHistory: false)
            return
        }

        if shuffleMode != .off, let id = nextShuffledID(in: list),
           let track = tracks.first(where: { $0.id == id }) {
            playTrack(track, pushHistory: true)
            return
        }

        guard let id = currentID, let index = list.firstIndex(where: { $0.id == id }) else {
            isPlaying = false
            return
        }

        let nextIndex = index + 1
        if nextIndex < list.count {
            playTrack(list[nextIndex], pushHistory: true)
        } else if repeatMode == .all {
            playTrack(list[0], pushHistory: true)
        } else {
            dbg("advance: end of list, repeat=off, stopping")
            generation += 1
            playerNode.stop()
            isPlaying = false
            currentTime = 0
        }
    }

    private func nextShuffledID(in list: [Track]) -> String? {
        guard !list.isEmpty else { return nil }

        if shuffleMode == .pure {
            guard list.count > 1 else { return list.first?.id }
            var candidate = list[Int.random(in: 0..<list.count)].id
            var attempts = 0
            while candidate == currentID && attempts < 8 {
                candidate = list[Int.random(in: 0..<list.count)].id
                attempts += 1
            }
            return candidate
        }

        let validIDs = Set(list.map { $0.id })
        bag.removeAll { !validIDs.contains($0) }

        if bag.isEmpty {
            var ids = list.map { $0.id }
            ids.shuffle()
            if ids.count > 1, ids.first == currentID {
                ids.swapAt(0, ids.count - 1)
            }
            bag = ids
        }

        if bag.first == currentID, bag.count > 1 {
            bag.swapAt(0, bag.count - 1)
        }
        return bag.isEmpty ? nil : bag.removeFirst()
    }

    // MARK: - 计时

    private func ensureTimer() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            let delta = now.timeIntervalSince(self.lastTick)
            self.lastTick = now

            if self.isPlaying {
                if !self.scrubbing { self.updateCurrentTime() }
                if self.session != nil {
                    self.session?.listened += min(max(delta, 0), 0.6)
                }
            }

        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func updateCurrentTime() {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }
        let time = playStartTime + Double(playerTime.sampleTime) / playerTime.sampleRate
        currentTime = max(0, min(time, duration))
    }

    // MARK: - 统计记录

    private func finalizeSession(completed: Bool) {
        guard let finished = session else { return }
        session = nil

        dbg("finalize listened=\(finished.listened) completed=\(completed) dur=\(finished.duration)")
        guard finished.listened >= 3 else { return }

        let record = PlayRecord(
            path: finished.path,
            title: finished.title,
            artist: finished.artist,
            trackDuration: finished.duration,
            seconds: finished.listened,
            startedAt: finished.startedAt,
            completed: completed,
            repeatMode: repeatMode.rawValue,
            shuffle: shuffleMode.rawValue
        )
        StatsStore.shared.record(record)
        statsRevision += 1
    }

    // MARK: - 封面

    private func loadArtwork(for track: Track) {
        let url = track.url
        let id = track.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Task {
                let data = await Library.artworkData(for: url)
                DispatchQueue.main.async {
                    guard let self, self.currentID == id else { return }
                    if let data, let image = NSImage(data: data) {
                        self.artwork = image
                    }
                }
            }
        }
    }

    // MARK: - 一起听

    func currentSnapshot() -> SyncEngine.Snapshot? {
        guard let track = currentTrack else { return nil }
        if isPlaying { updateCurrentTime() }
        return SyncEngine.Snapshot(
            dur: Int((track.duration ?? duration).rounded()),
            name: track.url.lastPathComponent.lowercased(),
            title: track.title,
            pos: currentTime,
            playing: isPlaying
        )
    }

    private func didLocalChange() {
        guard !applyingRemote else { return }
        sync.noteLocalChange()
    }

    private func matchRemoteTrack(_ remote: SyncEngine.Remote) -> Track? {
        let name = remote.name.lowercased()
        if !name.isEmpty,
           let exact = tracks.first(where: { $0.url.lastPathComponent.lowercased() == name }) {
            return exact
        }
        let sameLength = tracks.filter {
            guard let d = $0.duration else { return false }
            return abs(d.rounded() - Double(remote.dur)) < 0.5
        }
        return sameLength.count == 1 ? sameLength[0] : nil
    }

    private func applyRemote(_ remote: SyncEngine.Remote) {
        applyingRemote = true
        defer { applyingRemote = false }

        if remote.dur <= 0 {
            sync.setMissing(nil)
            if isPlaying {
                playerNode.pause()
                isPlaying = false
            }
            return
        }

        guard let track = matchRemoteTrack(remote) else {
            sync.setMissing(remote.title.isEmpty ? remote.name : remote.title)
            if isPlaying {
                playerNode.pause()
                isPlaying = false
            }
            return
        }
        sync.setMissing(nil)

        if currentID != track.id {
            playTrack(track, pushHistory: false)
            lastSyncSeek = Date.distantPast
        }

        if !scrubbing {
            let diff = abs(remote.target - currentTime)
            // 对方主动拖动、切歌、恢复播放：立刻对齐；
            // 其余情况能不动就不动——小跳比 0.3 秒的固定滞后更烦人
            let limit: Double = remote.hardJump ? 0.04 : 0.35
            let cooldown: Double = remote.hardJump ? 0 : 3.0
            if diff > limit, Date().timeIntervalSince(lastSyncSeek) > cooldown {
                dbg("sync seek diff=\(String(format: "%.3f", diff)) -> \(String(format: "%.2f", remote.target))")
                fadeSeek(to: remote.target)
                lastSyncSeek = Date()
            }
        }

        if remote.playing != isPlaying {
            if remote.playing {
                playerNode.play()
                isPlaying = true
                lastTick = Date()
            } else {
                updateCurrentTime()
                playerNode.pause()
                isPlaying = false
            }
        }
    }

    /// 跳转时用极短淡入淡出遮住波形断裂，避免「咔」一声
    private func fadeSeek(to time: Double) {
        let restored = playerNode.volume
        playerNode.volume = 0
        seek(to: time)
        for step in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.004 * Double(step)) { [weak self] in
                guard let self else { return }
                self.playerNode.volume = restored * Float(step) / 5
            }
        }
    }

}
