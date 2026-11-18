import SwiftUI

// MARK: - 设置面板

struct SettingsView: View {
    @ObservedObject private var theme = Theme.shared

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    schemeRow
                    card("明暗") {
                        Picker("", selection: $theme.appearance) {
                            ForEach(Theme.Appearance.allCases) { item in
                                Text(item.label).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    baseColorCard
                    accentCard
                    listCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }

            footer
        }
        .frame(width: 460, height: 700)
        .background(theme.windowBase)
        .tint(theme.accent)
    }

    // MARK: 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("外观")
                .font(.system(size: 19, weight: .semibold))
            Text("改动会立即反映到主窗口")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack {
            Button("恢复默认") { theme.reset() }
                .controlSize(.small)
            Spacer()
            Text("⌘, 随时打开")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }

    // MARK: 卡片容器

    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.separator.opacity(0.55), lineWidth: 0.5)
            )
        }
    }

    // MARK: 配色方案

    private var schemeRow: some View {
        HStack(spacing: 8) {
            ForEach(Theme.schemes) { scheme in
                Button {
                    theme.apply(scheme)
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(previewSurface(scheme, level: 0))
                                .frame(width: 13, height: 13)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.26), lineWidth: 0.5))
                            Circle()
                                .fill(previewSurface(scheme, level: 1))
                                .frame(width: 13, height: 13)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.26), lineWidth: 0.5))
                            Circle()
                                .fill(scheme.accent.isEmpty
                                      ? Color.accentColor
                                      : Color(hex: scheme.accent))
                                .frame(width: 13, height: 13)
                        }
                        Text(scheme.name)
                            .font(.system(size: 10.5))
                            .foregroundStyle(isActive(scheme) ? theme.accent : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isActive(scheme)
                                  ? theme.accent.opacity(0.12)
                                  : theme.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isActive(scheme) ? theme.accent : theme.separator.opacity(0.55),
                                lineWidth: isActive(scheme) ? 1.5 : 0.5
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func previewSurface(_ scheme: Theme.Scheme, level: Int) -> Color {
        let dark = scheme.appearance == .dark
        let brightness: Double = dark
            ? (level == 0 ? 0.138 : 0.104)
            : (level == 0 ? 0.974 : 0.933)
        let saturation = scheme.tint * (dark ? 0.42 : 0.30)
        return Color(hue: scheme.hue / 360, saturation: saturation, brightness: brightness)
    }

    private func isActive(_ scheme: Theme.Scheme) -> Bool {
        theme.matches(scheme)
    }

    // MARK: 底色

    private var baseColorCard: some View {
        card("界面底色") {
            HStack(spacing: 9) {
                ForEach(Theme.tintPresets) { preset in
                    let selected = preset.hue == nil
                        ? !theme.hasTint
                        : (theme.hasTint && abs(theme.baseHue - (preset.hue ?? 0)) < 6)

                    Button {
                        if let hue = preset.hue {
                            theme.baseHue = hue
                            if theme.tint < 0.35 { theme.tint = 0.6 }
                        } else {
                            theme.tint = 0
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(swatchColor(hue: preset.hue))
                            .frame(height: 28)
                            .frame(maxWidth: .infinity)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        selected ? theme.accent : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("浓度")
                        .font(.system(size: 11.5))
                    Spacer()
                    Text(theme.hasTint ? "\(Int((theme.tint * 100).rounded()))%" : "中性灰")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $theme.tint, in: 0...1)
                    .controlSize(.small)
            }

            preview
        }
    }

    /// 色板只负责「区分色相」，所以用醒目的中间调。
    /// 真实观感由下面的预览条和主窗口呈现——按实际背景色画会全糊成一片黑。
    private func swatchColor(hue: Double?) -> Color {
        let brightness = theme.isDark ? 0.62 : 0.93
        let saturation = hue == nil ? 0 : 0.40
        return Color(hue: (hue ?? 0) / 360, saturation: saturation, brightness: brightness)
    }

    private var preview: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.sunken)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("曲名显示在这里")
                    .font(.system(size: 11.5, weight: .medium))
                Text("侧栏 · 列表 · 播放条")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            ZStack {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 20, height: 20)
                Image(systemName: "play.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: 0.5)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.bar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.separator, lineWidth: 0.5)
        )
    }

    // MARK: 强调色

    private var accentCard: some View {
        card("强调色") {
            HStack(spacing: 9) {
                ForEach(Theme.accentPresets) { preset in
                    let selected = theme.accentHex == preset.hex
                    Button {
                        theme.accentHex = preset.hex
                    } label: {
                        if preset.hex.isEmpty {
                            ZStack {
                                Circle()
                                    .fill(theme.sunken)
                                    .frame(width: 24, height: 24)
                                Image(systemName: "circle.lefthalf.filled")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .overlay(
                                Circle().strokeBorder(
                                    selected ? theme.accent : Color.primary.opacity(0.12),
                                    lineWidth: selected ? 2 : 0.5
                                )
                            )
                        } else {
                            Circle()
                                .fill(Color(hex: preset.hex))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .opacity(selected ? 1 : 0)
                                )
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            selected ? Color.primary.opacity(0.45) : Color.clear,
                                            lineWidth: 1.5
                                        )
                                        .padding(-3)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 列表

    private var listCard: some View {
        card("列表") {
            Picker("", selection: $theme.density) {
                ForEach(Theme.Density.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("侧栏宽度")
                        .font(.system(size: 11.5))
                    Spacer()
                    Text("\(Int(theme.sidebarWidth)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $theme.sidebarWidth, in: 150...300, step: 4)
                    .controlSize(.small)
            }
        }
    }
}
