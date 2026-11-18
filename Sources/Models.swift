import Foundation
import AVFoundation

// MARK: - 数据模型

struct Track: Identifiable, Equatable {
    let id: String          // 用文件绝对路径作为唯一标识
    let url: URL
    let rootPath: String    // 所属的根文件夹
    let folder: String      // 相对子文件夹（用于分组显示）
    var title: String
    var artist: String?
    var duration: Double?

    init(url: URL, rootPath: String, folder: String) {
        self.id = url.path
        self.url = url
        self.rootPath = rootPath
        self.folder = folder
        self.title = url.deletingPathExtension().lastPathComponent
    }
}

struct TrackMeta {
    let title: String?
    let artist: String?
    let duration: Double?
}

enum RepeatMode: String {
    case off   // 顺序播放，播完停
    case all   // 列表循环
    case one   // 单曲循环

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbolName: String {
        switch self {
        case .one: return "repeat.1"
        default: return "repeat"
        }
    }

    var label: String {
        switch self {
        case .off: return "顺序播放"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }
}

enum ShuffleMode: String {
    case off    // 不随机
    case fair   // 洗牌袋：一轮内不重复
    case pure   // 真随机：每次独立抽取

    var next: ShuffleMode {
        switch self {
        case .off: return .fair
        case .fair: return .pure
        case .pure: return .off
        }
    }

    var label: String {
        switch self {
        case .off: return "顺序播放"
        case .fair: return "随机（一轮不重复）"
        case .pure: return "真随机（可能重样）"
        }
    }

    var shortLabel: String {
        switch self {
        case .off: return "不随机"
        case .fair: return "洗牌随机"
        case .pure: return "真随机"
        }
    }

    var isOn: Bool { self != .off }
}

// MARK: - 扫描与元数据

enum Library {

    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "flac", "alac", "caf", "m4r", "ape", "wv"
    ]

    /// 递归扫描文件夹，返回按分组 + 名称自然排序的曲目
    static func scan(roots: [URL]) -> [Track] {
        var result: [Track] = []
        let fm = FileManager.default

        for root in roots {
            let rootStd = root.standardizedFileURL
            guard let enumerator = fm.enumerator(
                at: rootStd,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard audioExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }

                let dirComponents = fileURL.deletingLastPathComponent().standardizedFileURL.pathComponents
                let rootComponents = rootStd.pathComponents
                let relative: [String] = dirComponents.count > rootComponents.count
                    ? Array(dirComponents[rootComponents.count...])
                    : []

                let folder = relative.isEmpty ? rootStd.lastPathComponent : relative.joined(separator: " / ")

                result.append(Track(url: fileURL, rootPath: rootStd.path, folder: folder))
            }
        }

        result.sort { lhs, rhs in
            if lhs.rootPath != rhs.rootPath {
                return lhs.rootPath.localizedStandardCompare(rhs.rootPath) == .orderedAscending
            }
            if lhs.folder != rhs.folder {
                return lhs.folder.localizedStandardCompare(rhs.folder) == .orderedAscending
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        return result
    }

    /// 读取标题 / 艺术家 / 时长
    static func metadata(for url: URL) async -> TrackMeta {
        let asset = AVURLAsset(url: url)
        var title: String?
        var artist: String?
        var duration: Double?

        if let time = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite && seconds > 0 { duration = seconds }
        }

        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
                case .commonKeyArtist, .commonKeyAuthor:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { artist = value }
                default:
                    break
                }
            }
        }

        return TrackMeta(title: title, artist: artist, duration: duration)
    }

    /// 封面数据（在后台线程读取，回到主线程再转成 NSImage）
    static func artworkData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue) { return data }
            }
        }
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            let items = (try? await asset.loadMetadata(for: format)) ?? []
            for item in items where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue) { return data }
            }
        }
        return nil
    }
}

// MARK: - 小工具

func timeString(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    let m = total / 60
    let s = total % 60
    if m >= 60 {
        let h = m / 60
        return String(format: "%d:%02d:%02d", h, m % 60, s)
    }
    return String(format: "%d:%02d", m, s)
}
