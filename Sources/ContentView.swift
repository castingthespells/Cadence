import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: PlayerModel
    @ObservedObject private var theme = Theme.shared
    @Environment(\.openSettings) private var openSettings

    @State private var hoveredID: String?
    @State private var isDropTargeted = false
    @State private var keyMonitor: Any?

    private struct TrackGroup: Identifiable {
        let id: String
        let name: String
        let tracks: [Track]
    }

    private var groups: [TrackGroup] {
        var order: [String] = []
        var buckets: [String: [Track]] = [:]
        let multiRoot = model.roots.count > 1

        for track in model.visibleTracks {
            let key = track.rootPath + "||" + track.folder
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(track)
        }

        return order.map { key in
            let items = buckets[key] ?? []
            var name = items.first?.folder ?? ""
            if multiRoot, let first = items.first {
                let rootName = URL(fileURLWithPath: first.rootPath).lastPathComponent
                name = name == rootName ? name : "\(rootName) / \(name)"
            }
            return TrackGroup(id: key, name: name, tracks: items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                vSeparator
                VStack(spacing: 0) {
                    header
                    hSeparator
                    content
                }
                if model.showMeters {
                    vSeparator
                    MetersView(meter: model.meter) { model.showMeters = false }
                }
            }
            hSeparator
            PlayerBar(artwork: model.artwork)
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(theme.windowBase)
        .tint(theme.accent)
        .overlay(dropOverlay)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .sheet(isPresented: $model.showingSync) {
            SyncView(sync: model.sync)
        }
        .onAppear(perform: installKeyMonitor)
        .onAppear {
            let args = ProcessInfo.processInfo.arguments

            if let index = args.firstIndex(of: "--apply-scheme"), index + 1 < args.count,
               let scheme = Theme.schemes.first(where: { $0.id == args[index + 1] }) {
                theme.apply(scheme)
            }

            guard args.contains("--open-settings") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                openSettings()
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("曲库")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            SidebarRow(
                title: "全部歌曲",
                count: model.tracks.count,
                symbol: "music.note.list",
                isSelected: model.selectedRoot == nil && !model.showingStats
            ) {
                model.showingStats = false
                model.selectedRoot = nil
            }

            ForEach(model.roots, id: \.path) { root in
                SidebarRow(
                    title: root.lastPathComponent,
                    count: model.count(in: root),
                    symbol: "folder",
                    isSelected: model.selectedRoot?.path == root.path && !model.showingStats
                ) {
                    model.showingStats = false
                    model.selectedRoot = root
                }
                .contextMenu {
                    Button("在访达中显示") {
                        NSWorkspace.shared.open(root)
                    }
                    Button("移除此文件夹", role: .destructive) {
                        model.removeRoot(root)
                    }
                }
            }

            SidebarRow(
                title: "听歌统计",
                count: nil,
                symbol: "chart.bar.xaxis",
                isSelected: model.showingStats
            ) {
                model.showingStats = true
            }

            Spacer(minLength: 8)

            if model.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("扫描中…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            if let error = model.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }

            Button {
                addFolder()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                    Text("添加文件夹")
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: theme.sidebarWidth)
        .background(theme.bar)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            if !model.showingStats {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(minWidth: 56, idealWidth: 120, maxWidth: 120)
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.separator, lineWidth: 1)
                )
            }

            Button {
                model.showMeters.toggle()
            } label: {
                Image(systemName: model.showMeters ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help(model.showMeters ? "收起仪表（⌘M）" : "展开仪表（⌘M）")

            if !model.showingStats {
                Button {
                    model.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("重新扫描文件夹")

                Button {
                    model.showingSync = true
                } label: {
                    Text(model.sync.active ? "一起听 · 已连接" : "一起听")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help(model.sync.active
                      ? "正在和\(model.sync.peerName ?? "朋友")一起听（⇧⌘J）"
                      : "和朋友同步播放（⇧⌘J）")

                Button("添加文件夹") { addFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }

            Button {
                openSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("外观设置（⌘,）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var headerTitle: String {
        if model.showingStats { return "听歌统计" }
        return model.selectedRoot?.lastPathComponent ?? "全部歌曲"
    }

    private var subtitleText: String {
        if model.showingStats {
            return "本地记录，不上传"
        }
        let count = model.visibleTracks.count
        let total = model.visibleTracks.compactMap { $0.duration }.reduce(0, +)
        if total > 0 {
            return "\(count) 首 · \(timeString(total))"
        }
        return "\(count) 首"
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if model.showingStats {
            StatsView()
        } else if model.tracks.isEmpty {
            emptyState
        } else if model.visibleTracks.isEmpty {
            VStack(spacing: 8) {
                Text("没有匹配的歌曲").foregroundStyle(.secondary)
                Button("清空搜索") { model.searchText = "" }
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { offset, track in
                                    row(track, number: offset + 1)
                                        .id(track.id)
                                }
                            } header: {
                                if groups.count > 1 {
                                    groupHeader(group.name)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onChange(of: model.currentID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.quaternary)
            Text("还没有添加音乐文件夹")
                .font(.system(size: 14, weight: .medium))
            Text("选一个文件夹，里面的歌曲会自动被找到")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("选择文件夹…") { addFolder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupHeader(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
            Text(name)
                .font(.system(size: 11, weight: .medium))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(theme.groupHeader)
    }

    private func row(_ track: Track, number: Int) -> some View {
        let isCurrent = track.id == model.currentID
        let isHovered = track.id == hoveredID

        return HStack(spacing: 10) {
            ZStack {
                if isCurrent {
                    Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "speaker.wave.1.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent)
                } else {
                    Text("\(number)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: theme.density.titleSize, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? theme.accent : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: theme.density.subtitleSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(timeString(track.duration))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, theme.density.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            isCurrent
                ? theme.accent.opacity(0.10)
                : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onTapGesture { model.play(track) }
        .onHover { inside in
            if inside { hoveredID = track.id }
            else if hoveredID == track.id { hoveredID = nil }
        }
        .contextMenu {
            Button("播放") { model.play(track) }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([track.url])
            }
        }
    }

    // MARK: - 其他

    private var hSeparator: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }

    private var vSeparator: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        Group {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func addFolder() {
        model.chooseFolder()
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
                DispatchQueue.main.async {
                    model.addRoots([directory])
                }
            }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.window?.firstResponder is NSTextView { return event }
            switch event.keyCode {
            case 49:  // 空格
                model.togglePlay()
                return nil
            case 123: // ←
                model.previous()
                return nil
            case 124: // →
                model.next()
                return nil
            default:
                return event
            }
        }
    }
}

// MARK: - 侧栏行

private struct SidebarRow: View {
    let title: String
    let count: Int?
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @ObservedObject private var theme = Theme.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? theme.accent.opacity(0.16)
                          : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 播放条

private struct PlayerBar: View {
    @EnvironmentObject var model: PlayerModel
    @ObservedObject private var theme = Theme.shared
    let artwork: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            artworkView
            trackInfo
            transport

            Text(timeString(model.currentTime))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)

            progressBar

            Text(timeString(model.duration))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            modeToggles
            volumeControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.bar)
    }

    // MARK: 曲目信息

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.currentTrack?.title ?? "未在播放")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(model.currentTrack?.artist
                 ?? (model.currentTrack == nil ? "选一首歌开始" : "未知艺术家"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
    }

    private var artworkView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.sunken)
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: 传输控制

    private var transport: some View {
        HStack(spacing: 14) {
            Button { model.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("上一首（←）")

            Button { model.togglePlay() } label: {
                ZStack {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 30, height: 30)
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: model.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "暂停（空格）" : "播放（空格）")

            Button { model.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("下一首（→）")
        }
    }

    // MARK: 进度条

    private var progressBar: some View {
        ProgressBar(
            value: Binding(
                get: { model.currentTime },
                set: { model.currentTime = $0 }
            ),
            total: model.duration,
            onEditingChanged: { model.setScrubbing($0) }
        )
        .frame(minWidth: 110, maxWidth: .infinity)
        .layoutPriority(1)
    }

    // MARK: 模式开关

    private var modeToggles: some View {
        HStack(spacing: 10) {
            Button {
                model.cycleShuffle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 11))
                        .foregroundStyle(model.shuffleMode.isOn ? theme.accent : Color.secondary)
                    if model.shuffleMode == .pure {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 4, height: 4)
                            .offset(x: 3, y: -3)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("随机：\(model.shuffleMode.label)（点击切换）")

            Button {
                model.cycleRepeat()
            } label: {
                Image(systemName: model.repeatMode.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(model.repeatMode == .off ? Color.secondary : theme.accent)
            }
            .buttonStyle(.plain)
            .help("循环模式：\(model.repeatMode.label)")
        }
    }

    // MARK: 音量

    private var volumeControl: some View {
        HStack(spacing: 5) {
            Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(value: $model.volume, in: 0...1)
                .controlSize(.mini)
                .frame(width: 68)
        }
    }
}

// MARK: - 自绘进度条

/// 不用系统 Slider：它的轨道在深色/彩色背景上几乎看不见，而且被挤压时会退化成一个点。
private struct ProgressBar: View {
    @Binding var value: Double
    let total: Double
    let onEditingChanged: (Bool) -> Void

    @ObservedObject private var theme = Theme.shared
    @State private var dragging = false
    @State private var hovering = false

    private var ratio: Double {
        guard total > 0.01 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let knob: CGFloat = dragging ? 12 : (hovering ? 11 : 9)
            let progress = CGFloat(ratio) * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.groove)
                    .frame(height: 4)

                Capsule()
                    .fill(theme.accent.opacity(dragging ? 1.0 : 0.9))
                    .frame(width: max(0, progress), height: 4)

                Circle()
                    .fill(theme.accent)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.20), radius: 1.5, y: 0.5)
                    .offset(x: min(max(progress - knob / 2, 0), max(0, width - knob)))
                    .opacity(total > 0.01 ? 1 : 0.35)
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        guard total > 0.01 else { return }
                        let r = min(max(gesture.location.x / width, 0), 1)
                        value = r * total
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 18)
    }
}
