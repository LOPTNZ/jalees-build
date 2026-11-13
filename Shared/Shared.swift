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
            if id.hasSuffix(".widget") { id = String(id.dropLast(".widget".count)) }
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
