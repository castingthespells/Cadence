import SwiftUI
import AppKit

struct SyncView: View {
    @ObservedObject private var theme = Theme.shared
    @ObservedObject var sync: SyncEngine
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 14)

            if sync.active {
                joined
            } else {
                setup
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 400, height: sync.active ? 300 : 256)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 17))
                .foregroundStyle(theme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text("一起听")
                    .font(.system(size: 15, weight: .semibold))
                Text("两边都能按暂停、切歌，状态互相同步")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 未加入

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                sync.createRoom()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text("创建房间")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.separator)
                    .frame(height: 1)
                Text("或者输入朋友的房间码")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle()
                    .fill(theme.separator)
                    .frame(height: 1)
            }

            HStack(spacing: 8) {
                TextField("8 位房间码", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onChange(of: code) { value in
                        let clean = value.uppercased().filter { $0.isLetter || $0.isNumber }
                        if clean != value { code = String(clean.prefix(8)) }
                        if clean.count > 8 { code = String(clean.prefix(8)) }
                    }
                    .onSubmit { join() }

                Button("加入") { join() }
                    .buttonStyle(.bordered)
                    .disabled(code.count != 8)
            }

            Text("两边都要有同一个音频文件。声音不走网络，各自播放本地的那一份。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func join() {
        guard code.count == 8 else { return }
        sync.joinRoom(code)
    }

    // MARK: - 已加入

    private var joined: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("房间码")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(sync.room)
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .tracking(3)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sync.room, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("复制房间码")
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                statusRow(
                    icon: sync.link == "已连接" ? "antenna.radiowaves.left.and.right" : "arrow.triangle.2.circlepath",
                    tint: sync.link == "已连接" ? .green : .orange,
                    title: sync.link
                )
                statusRow(
                    icon: "person.fill",
                    tint: sync.peerOnline ? .green : .secondary,
                    title: sync.peerName ?? (sync.peerOnline ? "有人进来了" : "等待对方进入…"),
                    detail: sync.peerOnline ? nil : nil
                )
                statusRow(
                    icon: sync.isAuthor ? "arrow.up.circle" : "arrow.down.circle",
                    tint: .secondary,
                    title: sync.isAuthor ? "你现在控制播放" : "跟随对方的播放",
                    detail: sync.rttMs > 0
                        ? String(format: "中转往返 %.0f ms", sync.rttMs)
                        : "正在测链路…"
                )
            }

            if let missing = sync.missingTitle {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text("对方在放《\(missing)》，你本地没有这首")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)

            HStack {
                Text("双方都可以操作，谁后动谁说了算")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("离开房间") {
                    sync.leave()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func statusRow(icon: String, tint: Color, title: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
