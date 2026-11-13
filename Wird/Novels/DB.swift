import Foundation
import SQLite3

/// Novels, chapters and their text live in one SQLite file (Application Support/Wird/novels.sqlite),
/// next to the older state.json that still holds the paper books and the notebook.
final class DB {
    static let shared = DB()

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wird", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("novels.sqlite").path
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            handle = nil
        }
        run("PRAGMA journal_mode=WAL")
        run("PRAGMA foreign_keys=ON")
        migrate()
    }

    private func migrate() {
        let v = Int(query("PRAGMA user_version").first?["user_version"] as? Int64 ?? 0)
        if v < 1 {
            run("""
            CREATE TABLE IF NOT EXISTS novels(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source TEXT NOT NULL, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
              author TEXT, cover TEXT, summary TEXT, status TEXT,
              total INTEGER DEFAULT 0, added REAL, updated REAL, opened REAL,
              cur_chapter INTEGER, cur_p INTEGER DEFAULT 0, cur_o REAL DEFAULT 0)
            """)
            run("""
            CREATE TABLE IF NOT EXISTS chapters(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              novel INTEGER NOT NULL REFERENCES novels(id) ON DELETE CASCADE,
              idx INTEGER NOT NULL, num TEXT, title TEXT, url TEXT NOT NULL, volume TEXT, date TEXT,
              read INTEGER DEFAULT 0, words INTEGER DEFAULT 0,
              UNIQUE(novel, url))
            """)
            run("CREATE INDEX IF NOT EXISTS chapters_order ON chapters(novel, idx)")
            run("""
            CREATE TABLE IF NOT EXISTS texts(
              chapter INTEGER PRIMARY KEY REFERENCES chapters(id) ON DELETE CASCADE,
              title TEXT, paras TEXT NOT NULL, removed INTEGER DEFAULT 0, kept INTEGER DEFAULT 0, fetched REAL)
            """)
            run("CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT)")
            run("PRAGMA user_version=1")
        }
        if v < 2 {
            // the Jalees book this novel is (its id in the library), and what the site says about it
            run("ALTER TABLE novels ADD COLUMN book TEXT")
            run("ALTER TABLE novels ADD COLUMN translator TEXT")
            run("ALTER TABLE novels ADD COLUMN genres TEXT")
            run("PRAGMA user_version=2")
        }
        if v < 3 {
            // where you stopped inside each chapter, so going back to one returns there
            run("ALTER TABLE chapters ADD COLUMN pos_p INTEGER DEFAULT 0")
            run("ALTER TABLE chapters ADD COLUMN pos_o REAL DEFAULT 0")
            run("PRAGMA user_version=3")
        }
        if v < 4 {
            // every chapter opened, for the «السجل» tab
            run("CREATE TABLE IF NOT EXISTS history(id INTEGER PRIMARY KEY, novel INTEGER, chapter INTEGER, at REAL)")
            run("CREATE INDEX IF NOT EXISTS history_at ON history(at)")
            run("PRAGMA user_version=4")
        }
        if v < 5 {
            // when a chapter arrived after the novel was added: the «التحديثات» tab lists these
            run("ALTER TABLE chapters ADD COLUMN found REAL")
            run("PRAGMA user_version=5")
        }
        if v < 6 {
            // comments kept on the phone (with downloads, and whenever they are read)
            run("CREATE TABLE IF NOT EXISTS comments(chapter INTEGER PRIMARY KEY, json TEXT NOT NULL, total INTEGER DEFAULT 0, at REAL)")
            // each commenter's number in a novel, so «قارئ 3» is the same person from the first chapter to the last
            run("CREATE TABLE IF NOT EXISTS commenters(novel INTEGER NOT NULL, author TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(novel, author))")
            run("PRAGMA user_version=6")
        }
    }

    // MARK: statements

    private func bind(_ st: OpaquePointer?, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, n)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as Bool: sqlite3_bind_int64(st, n, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as String: sqlite3_bind_text(st, n, v, -1, DB.transient)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(st, n, $0.baseAddress, Int32(v.count), DB.transient) }
            default: sqlite3_bind_text(st, n, String(describing: a!), -1, DB.transient)
            }
        }
    }

    /// Runs one statement; returns the id of the row it inserted (0 when it inserted none).
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let db = handle else { return 0 }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            NSLog("jalees db: %@ — %@", String(cString: sqlite3_errmsg(db)), sql)
            return 0
        }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW { rc = sqlite3_step(st) }
        if rc != SQLITE_DONE { NSLog("jalees db: %@ — %@", String(cString: sqlite3_errmsg(db)), sql) }
        return sqlite3_last_insert_rowid(db)
    }

    /// Rows as dictionaries: Int64, Double, String or Data values; NULL columns are left out.
    func query(_ sql: String, _ args: [Any?] = []) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let db = handle else { return [] }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            NSLog("jalees db: %@ — %@", String(cString: sqlite3_errmsg(db)), sql)
            return []
        }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        var rows: [[String: Any]] = []
        let n = sqlite3_column_count(st)
        while sqlite3_step(st) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<n {
                let name = String(cString: sqlite3_column_name(st, i))
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(st, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(st, i)
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(st, i) { row[name] = String(cString: c) }
                case SQLITE_BLOB:
                    if let b = sqlite3_column_blob(st, i) { row[name] = Data(bytes: b, count: Int(sqlite3_column_bytes(st, i))) }
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Everything inside `body` is written together, or not at all.
    func transaction(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        run("BEGIN")
        body()
        run("COMMIT")
    }

    // MARK: small settings

    func get(_ key: String) -> String? { query("SELECT v FROM kv WHERE k=?", [key]).first?["v"] as? String }
    func set(_ key: String, _ value: String?) {
        if let v = value { run("INSERT INTO kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", [key, v]) }
        else { run("DELETE FROM kv WHERE k=?", [key]) }
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ k: String) -> Int { Int(self[k] as? Int64 ?? 0) }
    func str(_ k: String) -> String { self[k] as? String ?? "" }
    func dbl(_ k: String) -> Double { (self[k] as? Double) ?? Double(self[k] as? Int64 ?? 0) }
}
