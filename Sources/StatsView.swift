import SwiftUI

struct StatsView: View {
    @ObservedObject private var theme = Theme.shared
    @EnvironmentObject var model: PlayerModel

    @State private var summary = StatsSummary()
    @State private var staleTracks: [Track] = []
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                overview
                weeklyChart
                hourlyChart
                topTracks
                neglected
                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: reload)
        .onChange(of: model.statsRevision) { _, _ in reload() }
        .onChange(of: model.tracks.count) { _, _ in reload() }
        .alert("清空所有听歌记录？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                StatsStore.shared.reset()
                model.statsRevision += 1
                reload()
            }
        } message: {
            Text("这会删除本地 stats.db 里的全部播放事件，无法恢复。")
        }
    }

    // MARK: 概览

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("概览")

            HStack(spacing: 10) {
                statCard("今天", value: humanDuration(summary.todaySeconds), detail: "\(summary.todayPlays) 次播放")
                statCard("最近 7 天", value: humanDuration(summary.weekSeconds), detail: "\(summary.weekPlays) 次播放")
                statCard("全部", value: humanDuration(summary.totalSeconds), detail: "\(summary.totalPlays) 次播放")
            }

            HStack(spacing: 10) {
                statCard("跳过率", value: String(format: "%.0f%%", summary.skipRate * 100), detail: "播不到 30% 就算跳过")
                statCard("完整听完", value: "\(summary.completedPlays)", detail: "共 \(summary.totalPlays) 次播放")
                statCard("曲库", value: "\(summary.trackCount)", detail: "首本地曲目")
            }
        }
    }

    private func statCard(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.elevated.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.separator, lineWidth: 0.5)
        )
    }

    // MARK: 七日

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("最近 7 天")

            let maxValue = max(1, summary.last7.map { $0.seconds }.max() ?? 1)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(summary.last7) { day in
                    VStack(spacing: 4) {
                        Text(day.seconds > 0 ? shortDuration(day.seconds) : "")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day.seconds > 0 ? theme.accent.opacity(0.75) : Color.clear)
                            .frame(height: day.seconds > 0 ? max(4, CGFloat(day.seconds / maxValue) * 78) : 4)
                        Text(day.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 108, alignment: .bottom)
            .padding(.horizontal, 4)
        }
    }

    // MARK: 时段

    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("一天里的听歌时段")

            let maxValue = max(1, summary.hourly.max() ?? 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(summary.hourly[hour] > 0 ? theme.accent.opacity(0.7) : Color.clear)
                            .frame(height: summary.hourly[hour] > 0
                                   ? max(3, CGFloat(summary.hourly[hour] / maxValue) * 56)
                                   : 3)
                        if hour % 6 == 0 {
                            Text("\(hour)")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(" ")
                                .font(.system(size: 8))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 76, alignment: .bottom)
        }
    }

    // MARK: 最常听

    private var topTracks: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("听得最多的曲子")

            if summary.topTracks.isEmpty {
                emptyHint("还没有记录。放几首歌就有了。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(summary.topTracks.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                if let artist = item.artist, !artist.isEmpty {
                                    Text(artist)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 8)

                            Text(humanDuration(item.seconds))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Text("\(item.plays) 次")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        if index < summary.topTracks.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.elevated.opacity(0.7))
                )
            }
        }
    }

    // MARK: 冷落

    private var neglected: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("最近两个月没碰过的（\(staleTracks.count)）")

            if staleTracks.isEmpty {
                emptyHint("没有冷落的曲子。")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(staleTracks.prefix(8)) { track in
                        HStack(spacing: 8) {
                            Image(systemName: "circle.dashed")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(track.title)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            Spacer()
                            Text(track.folder)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if staleTracks.count > 8 {
                        Text("还有 \(staleTracks.count - 8) 首…")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.elevated.opacity(0.7))
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("记录存在 ~/Library/Application Support/Cadence/stats.db")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("清空统计") { showResetConfirm = true }
                .buttonStyle(.link)
                .font(.system(size: 10))
        }
        .padding(.top, 4)
    }

    // MARK: 工具

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
    }

    private func shortDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%.1fh", Double(minutes) / 60)
    }

    private func reload() {
        summary = StatsStore.shared.summary(trackCount: model.tracks.count)
        let played = StatsStore.shared.stalePaths(sinceDays: 60)
        staleTracks = model.tracks.filter { !played.contains($0.url.path) }
    }
}

func humanDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total) 秒" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes) 分" }
    let hours = minutes / 60
    let remain = minutes % 60
    return remain == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remain) 分"
}
