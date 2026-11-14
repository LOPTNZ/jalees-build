import Foundation
import ActivityKit

/// The App Group shared by the app and its widgets. AltStore renames groups when it signs the app and
/// lists the real names under ALTAppGroups; otherwise the group is "group." + the app's bundle id.
enum SharedGroup {
    static let fallback = "group.com.abdullah.wird.reader"

    private static func appInfo() -> [String: Any]? {
        let u = Bundle.main.bundleURL
        guard u.pathExtension == "appex" else { return nil }
        let app = u.deletingLastPathComponent().deletingLastPathComponent()
        return NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any]
    }

    static var candidates: [String] {
        var c: [String] = []
        for info in [Bundle.main.infoDictionary, appInfo()] {
            if let groups = info?["ALTAppGroups"] as? [String] { c += groups }
        }
        if var id = Bundle.main.bundleIdentifier {
            for suffix in [".widget", ".share"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
            c.append("group." + id)
        }
        c.append(fallback)
        return c
    }

    static let container: URL? = {
        for g in candidates {
            if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) { return u }
        }
        return nil
    }()
}

/// What the app writes for the widgets (see widgetPost() in the web app).
struct WBook: Codable {
    var id: String
    var title: String
    var author: String
    var pct: Double?
    var pos: String
    var status: String
    var audio: Bool
    var cover: String
    var color: String
    /// a web novel: where you are, chapters not read yet, and new ones not seen yet
    var novel: Bool?
    var chapter: String?
    var unread: Int?
    var fresh: Int?
}

/// A novel with chapters waiting, for the «الجديد في رواياتك» widget.
struct WNovel: Codable {
    var id: String
    var t: String
    var unread: Int
    var fresh: Int
    var last: String
}

/// A quote from the notebook for the quote widget: text, book title, author, and ids for the tap.
struct WQuote: Codable {
    var t: String
    var b: String
    var a: String
    var id: String
}

struct WSnap: Codable {
    var day: String
    var today: Int
    var goal: Int
    var streak: Int
    var todayHas: Bool
    var year: Int
    var yearGoal: Int
    var book: WBook?
    var accent: String?
    var quotes: [WQuote]?
    var novels: [WNovel]?
}

/// The running reading/listening session shown on the lock screen.
struct WirdSessionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var start: Date?
        var elapsed: Int
        var paused: Bool
        var pos: String
    }
    var title: String
    var author: String
    var audio: Bool
}

extension Calendar {
    /// Days, months and years as the web app counted them (JavaScript's Date): always Gregorian, in the phone's time
    /// zone, whatever calendar the phone shows (an Arabic region may default to Hijri, which made «حصاد 1448»).
    static let greg: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .autoupdatingCurrent
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
}

/// Links shared to Jalees from Safari (the share extension), waiting for the app to add them.
enum SharedLinks {
    private static var file: URL? { SharedGroup.container?.appendingPathComponent("shared-links.json") }

    static func push(_ url: String) {
        guard let f = file else { return }
        var list = ((try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []
        if !list.contains(url) { list.append(url) }
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: f, options: .atomic) }
    }

    static func take() -> [String] {
        guard let f = file, let d = try? Data(contentsOf: f), let list = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        try? FileManager.default.removeItem(at: f)
        return list
    }
}
