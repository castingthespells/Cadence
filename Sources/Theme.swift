import SwiftUI
import AppKit

// MARK: - 颜色工具

extension Color {
    /// "#RRGGBB" → Color
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        if cleaned.count == 6 {
            self.init(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: 1
            )
        } else {
            self.init(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)
        }
    }
}

// MARK: - 主题

/// 全局外观。所有界面颜色都从这里取，改一次全窗口跟着变。
final class Theme: ObservableObject {
    static let shared = Theme()

    // MARK: 选项

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "跟随系统"
            case .light:  return "浅色"
            case .dark:   return "深色"
            }
        }
    }

    enum Density: String, CaseIterable, Identifiable {
        case compact, cozy, loose
        var id: String { rawValue }
        var label: String {
            switch self {
            case .compact: return "紧凑"
            case .cozy:    return "标准"
            case .loose:   return "宽松"
            }
        }
        /// 单行上下内边距
        var rowPadding: CGFloat {
            switch self {
            case .compact: return 2
            case .cozy:    return 5
            case .loose:   return 8
            }
        }
        var titleSize: CGFloat {
            switch self {
            case .compact: return 11.5
            case .cozy:    return 12.5
            case .loose:   return 13.5
            }
        }
        var subtitleSize: CGFloat {
            switch self {
            case .compact: return 10
            case .cozy:    return 10.5
            case .loose:   return 11.5
            }
        }
    }

    /// 底色色板（hue 为 nil 表示纯中性灰）
    struct TintPreset: Identifiable {
        let id: String
        let name: String
        let hue: Double?
    }

    static let tintPresets: [TintPreset] = [
        .init(id: "gray",   name: "中性", hue: nil),
        .init(id: "blue",   name: "蓝",   hue: 214),
        .init(id: "indigo", name: "靛",   hue: 242),
        .init(id: "purple", name: "紫",   hue: 272),
        .init(id: "rose",   name: "玫红", hue: 336),
        .init(id: "orange", name: "橙",   hue: 28),
        .init(id: "green",  name: "绿",   hue: 148),
        .init(id: "teal",   name: "青",   hue: 186)
    ]

    /// 一键配色方案
    struct Scheme: Identifiable {
        let id: String
        let name: String
        let appearance: Appearance
        let hue: Double
        let tint: Double
        let accent: String
    }

    static let schemes: [Scheme] = [
        .init(id: "graphite", name: "石墨", appearance: .light, hue: 214, tint: 0,    accent: ""),
        .init(id: "navy",     name: "藏蓝", appearance: .light, hue: 214, tint: 0.62, accent: "#0A84FF"),
        .init(id: "midnight", name: "午夜", appearance: .dark,  hue: 242, tint: 0.55, accent: "#5E5CE6"),
        .init(id: "forest",   name: "森林", appearance: .dark,  hue: 148, tint: 0.50, accent: "#30D158"),
        .init(id: "sakura",   name: "樱",   appearance: .light, hue: 336, tint: 0.45, accent: "#FF375F")
    ]

    struct AccentPreset: Identifiable {
        let id: String
        let name: String
        let hex: String   // 空字符串 = 跟随系统
    }

    static let accentPresets: [AccentPreset] = [
        .init(id: "system", name: "跟随系统", hex: ""),
        .init(id: "blue",   name: "蓝",   hex: "#0A84FF"),
        .init(id: "indigo", name: "靛",   hex: "#5E5CE6"),
        .init(id: "purple", name: "紫",   hex: "#BF5AF2"),
        .init(id: "rose",   name: "玫红", hex: "#FF375F"),
        .init(id: "orange", name: "橙",   hex: "#FF9F0A"),
        .init(id: "green",  name: "绿",   hex: "#30D158"),
        .init(id: "teal",   name: "青",   hex: "#40C8E0")
    ]

    // MARK: 持久化字段

    @Published var appearance: Appearance = .system {
        didSet { applyAppearance(); save() }
    }
    @Published var baseHue: Double = 214 {
        didSet { save() }
    }
    /// 0 = 纯中性灰，1 = 最浓
    @Published var tint: Double = 0 {
        didSet { save() }
    }
    @Published var accentHex: String = "" {
        didSet { save() }
    }
    @Published var density: Density = .cozy {
        didSet { save() }
    }
    @Published var sidebarWidth: Double = 200 {
        didSet { save() }
    }

    // MARK: 初始化

    /// 读取阶段的赋值会触发 didSet，必须挡住，否则会用「半初始化的默认值」
    /// 把刚读进来的配置覆盖回磁盘，导致所有设置下次启动全失效。
    private var loading = true

    private init() {
        let store = UserDefaults.standard

        if let raw = store.string(forKey: "theme.appearance"),
           let value = Appearance(rawValue: raw) {
            appearance = value
        }
        if store.object(forKey: "theme.hue") != nil {
            baseHue = store.double(forKey: "theme.hue")
        }
        if store.object(forKey: "theme.tint") != nil {
            tint = store.double(forKey: "theme.tint")
        }
        if let accent = store.string(forKey: "theme.accent") {
            accentHex = accent
        }
        if let raw = store.string(forKey: "theme.density"),
           let value = Density(rawValue: raw) {
            density = value
        }
        if store.object(forKey: "theme.sidebar") != nil {
            sidebarWidth = store.double(forKey: "theme.sidebar")
        }

        loading = false
        applyAppearance()

        // 系统切深浅色时，让所有取色视图重算
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func save() {
        guard !loading else { return }
        let store = UserDefaults.standard
        store.set(appearance.rawValue, forKey: "theme.appearance")
        store.set(baseHue, forKey: "theme.hue")
        store.set(tint, forKey: "theme.tint")
        store.set(accentHex, forKey: "theme.accent")
        store.set(density.rawValue, forKey: "theme.density")
        store.set(sidebarWidth, forKey: "theme.sidebar")
    }

    func apply(_ scheme: Scheme) {
        appearance = scheme.appearance
        baseHue = scheme.hue
        tint = scheme.tint
        accentHex = scheme.accent
    }

    /// 当前状态是否就是这套方案（跟随系统时按实际明暗判断）
    func matches(_ scheme: Scheme) -> Bool {
        guard abs(baseHue - scheme.hue) < 8, abs(tint - scheme.tint) < 0.08 else { return false }
        if appearance == scheme.appearance { return true }
        if appearance == .system {
            return (scheme.appearance == .light) == !isDark
        }
        return false
    }

    func reset() {
        appearance = .system
        baseHue = 214
        tint = 0
        accentHex = ""
        density = .cozy
        sidebarWidth = 200
    }

    // MARK: 外观

    private func applyAppearance() {
        let app = NSApplication.shared
        switch appearance {
        case .system: app.appearance = nil
        case .light:  app.appearance = NSAppearance(named: .aqua)
        case .dark:   app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var isDark: Bool {
        switch appearance {
        case .dark:  return true
        case .light: return false
        case .system:
            let match = NSApplication.shared.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua
        }
    }

    /// 是否处于"选了颜色"的状态（用于色板选中态）
    var hasTint: Bool { tint > 0.001 }

    // MARK: 底色

    /// 由「亮度 + 该层可容纳的最大饱和度」算出表面色。
    /// 深色模式下颜色感知更钝，所以饱和度乘 1.4 补偿。
    private func surface(dark: Double, light: Double, cap: Double) -> Color {
        let brightness = isDark ? dark : light
        let saturation = min(tint * cap * (isDark ? 1.4 : 1.0), 0.9)
        return Color(hue: baseHue / 360, saturation: saturation, brightness: brightness)
    }

    /// 窗口主背景（列表区）
    var windowBase: Color { surface(dark: 0.138, light: 0.974, cap: 0.30) }
    /// 侧栏与播放条
    var bar: Color { surface(dark: 0.104, light: 0.933, cap: 0.33) }
    /// 浮起元素：搜索框、卡片
    var elevated: Color { surface(dark: 0.196, light: 1.000, cap: 0.22) }
    /// 凹陷元素：封面占位
    var sunken: Color { surface(dark: 0.074, light: 0.902, cap: 0.32) }
    /// 进度槽：深色下要比背景亮、浅色下要比背景暗，否则看不见
    var groove: Color { surface(dark: 0.285, light: 0.800, cap: 0.26) }
    /// 分隔线
    var separator: Color { surface(dark: 0.252, light: 0.858, cap: 0.28) }
    /// 分组标题底色（略压暗，滚过时能盖住下面的行）
    var groupHeader: Color { surface(dark: 0.168, light: 0.955, cap: 0.30) }

    // MARK: 强调色

    var accent: Color {
        accentHex.isEmpty ? Color.accentColor : Color(hex: accentHex)
    }

    /// 强调色的半透明填充（选中行、选中项）
    var accentWash: Color { accent.opacity(0.14) }
}
