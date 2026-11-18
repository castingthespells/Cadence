import Foundation
import SQLite3

// MARK: - 记录结构

struct PlayRecord {
    var path: String
    var title: String
    var artist: String?
    var trackDuration: Double
    var seconds: Double
    var startedAt: Date
    var completed: Bool
    var repeatMode: String
    var shuffle: String
}

struct DayTotal: Identifiable {
    let id: String      // yyyy-MM-dd
    let label: String   // 周一 / 11-16
    let seconds: Double
}

struct TrackTotal: Identifiable {
    let id: String
    let title: String
    let artist: String?
    let plays: Int
    let seconds: Double
    let lastPlayed: Date?
}

struct StatsSummary {
    var todaySeconds: Double = 0
    var weekSeconds: Double = 0
    var totalSeconds: Double = 0
    var todayPlays: Int = 0
    var weekPlays: Int = 0
    var totalPlays: Int = 0
    var completedPlays: Int = 0
    var skipRate: Double = 0
    var hourly: [Double] = Array(repeating: 0, count: 24)
    var last7: [DayTotal] = []
    var topTracks: [TrackTotal] = []
    var trackCount: Int = 0
}

// MARK: - SQLite 存储

final class StatsStore {

    static let shared = StatsStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.cadence.stats")
    private var isOpen = false

    private init() {
        openDatabase()
    }

    private func openDatabase() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent("Cadence", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("stats.db")

        guard sqlite3_open(file.path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        isOpen = true

        exec("""
        CREATE TABLE IF NOT EXISTS plays (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            title TEXT NOT NULL,
            artist TEXT,
            track_duration REAL NOT NULL,
            seconds REAL NOT NULL,
            started_at REAL NOT NULL,
            completed INTEGER NOT NULL,
            repeat_mode TEXT,
            shuffle TEXT
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_plays_started ON plays(started_at);")
        exec("CREATE INDEX IF NOT EXISTS idx_plays_path ON plays(path);")
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: 写入

    func record(_ record: PlayRecord) {
        guard record.seconds >= 3 else { return }
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
            INSERT INTO plays (path, title, artist, track_duration, seconds, started_at, completed, repeat_mode, shuffle)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, (record.path as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (record.title as NSString).utf8String, -1, nil)
            if let artist = record.artist {
                sqlite3_bind_text(statement, 3, (artist as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            sqlite3_bind_double(statement, 4, record.trackDuration)
            sqlite3_bind_double(statement, 5, record.seconds)
            sqlite3_bind_double(statement, 6, record.startedAt.timeIntervalSince1970)
            sqlite3_bind_int(statement, 7, record.completed ? 1 : 0)
            sqlite3_bind_text(statement, 8, (record.repeatMode as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 9, (record.shuffle as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
    }

    func reset() {
        queue.sync { [weak self] in
            self?.exec("DELETE FROM plays;")
        }
    }

    // MARK: 查询

    func summary(trackCount: Int) -> StatsSummary {
        var result = StatsSummary()
        result.trackCount = trackCount

        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }

            result.totalPlays = self.scalarInt(db, "SELECT COUNT(*) FROM plays;")
            result.totalSeconds = self.scalarDouble(db, "SELECT COALESCE(SUM(seconds), 0) FROM plays;")
            result.completedPlays = self.scalarInt(db, "SELECT COUNT(*) FROM plays WHERE completed = 1;")

            result.todayPlays = self.scalarInt(db, """
            SELECT COUNT(*) FROM plays
            WHERE date(started_at, 'unixepoch', 'localtime') = date('now', 'localtime');
            """)
            result.todaySeconds = self.scalarDouble(db, """
            SELECT COALESCE(SUM(seconds), 0) FROM plays
            WHERE date(started_at, 'unixepoch', 'localtime') = date('now', 'localtime');
            """)

            result.weekPlays = self.scalarInt(db, """
            SELECT COUNT(*) FROM plays WHERE started_at >= strftime('%s','now','-6 days','start of day','localtime');
            """)
            result.weekSeconds = self.scalarDouble(db, """
            SELECT COALESCE(SUM(seconds), 0) FROM plays WHERE started_at >= strftime('%s','now','-6 days','start of day','localtime');
            """)

            let skips = self.scalarInt(db, """
            SELECT COUNT(*) FROM plays WHERE seconds < MIN(15.0, track_duration * 0.3);
            """)
            if result.totalPlays > 0 {
                result.skipRate = Double(skips) / Double(result.totalPlays)
            }

            // 24 小时分布
            var hourly = [Double](repeating: 0, count: 24)
            self.query(db, """
            SELECT CAST(strftime('%H', started_at, 'unixepoch', 'localtime') AS INTEGER) AS h,
                   SUM(seconds)
            FROM plays GROUP BY h;
            """) { statement in
                let hour = Int(sqlite3_column_int(statement, 0))
                let seconds = sqlite3_column_double(statement, 1)
                if hour >= 0 && hour < 24 { hourly[hour] = seconds }
            }
            result.hourly = hourly

            // 最近 7 天
            var byDay: [String: Double] = [:]
            self.query(db, """
            SELECT date(started_at, 'unixepoch', 'localtime') AS d, SUM(seconds)
            FROM plays
            WHERE started_at >= strftime('%s','now','-6 days','start of day','localtime')
            GROUP BY d;
            """) { statement in
                if let cString = sqlite3_column_text(statement, 0) {
                    let key = String(cString: cString)
                    byDay[key] = sqlite3_column_double(statement, 1)
                }
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let calendar = Calendar.current
            let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            var days: [DayTotal] = []
            for offset in stride(from: 6, through: 0, by: -1) {
                guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
                let key = formatter.string(from: date)
                let weekday = calendar.component(.weekday, from: date)
                days.append(DayTotal(id: key, label: weekdayNames[(weekday - 1) % 7], seconds: byDay[key] ?? 0))
            }
            result.last7 = days

            // 播放最多的曲子
            var tops: [TrackTotal] = []
            self.query(db, """
            SELECT path, title, artist, COUNT(*) AS plays, SUM(seconds), MAX(started_at)
            FROM plays
            GROUP BY path
            ORDER BY plays DESC, SUM(seconds) DESC
            LIMIT 10;
            """) { statement in
                let path = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let artist = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let plays = Int(sqlite3_column_int(statement, 3))
                let seconds = sqlite3_column_double(statement, 4)
                let last = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                tops.append(TrackTotal(id: path, title: title, artist: artist, plays: plays, seconds: seconds, lastPlayed: last))
            }
            result.topTracks = tops
        }

        return result
    }

    /// 返回很久没播放过的曲目路径集合
    func stalePaths(sinceDays: Int) -> Set<String> {
        var played: Set<String> = []
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            self.query(db, """
            SELECT path FROM plays
            WHERE started_at >= strftime('%s','now','-\(sinceDays) days');
            """) { statement in
                if let text = sqlite3_column_text(statement, 0) {
                    played.insert(String(cString: text))
                }
            }
        }
        return played
    }

    // MARK: 底层

    private func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func scalarDouble(_ db: OpaquePointer, _ sql: String) -> Double {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(statement, 0)
    }

    private func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement!)
        }
    }
}
