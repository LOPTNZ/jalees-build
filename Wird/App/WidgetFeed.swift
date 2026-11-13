import Foundation
import UIKit

// The widgets' snapshot (inventory-3, 6.1–6.6; the web's widgetPost): today's minutes, the streak, the year, the book
// read last and up to 60 quotes, written to the App Group a moment after each save, only when it changed.

@MainActor
enum WidgetFeed {
    private static var last = ""
    private static var work: DispatchWorkItem?

    /// After a save: wait for the edits to settle (0.9 s), then write.
    static func schedule() {
        work?.cancel()
        let w = DispatchWorkItem { update() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    static func update() {
        let st = Library.shared.state
        let streak = st.streak
        var snap: [String: Any] = [
            "day": Words.dkey(Millis.now), "today": Int(st.todayMin.rounded()), "goal": st.goals.daily,
            "streak": streak.cur, "todayHas": streak.todayHas, "year": st.finishedThisYear, "yearGoal": st.goals.year,
            "accent": (Theme.accents[st.settings.accent] ?? Theme.accents["teal"]!).dark[0], "quotes": quotes(st),
        ]
        if let id = st.lastBookId(), let b = st.book(id) {
            snap["book"] = ["id": b.id, "title": b.title, "author": b.author, "pct": b.pct.map { $0 as Any } ?? NSNull(), "pos": b.posLabel,
                            "status": b.status.rawValue, "audio": b.isAudio, "cover": b.cover ?? "", "color": b.colorHex] as [String: Any]
        } else {
            snap["book"] = NSNull()
        }
        guard let d = try? JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys]), let j = String(data: d, encoding: .utf8), j != last else { return }
        last = j
        WidgetSync.write(snap)
    }

    /// Favourites first, then the newest; short ones only (up to 240 characters).
    private static func quotes(_ st: AppState) -> [[String: Any]] {
        var all: [(t: String, b: String, a: String, id: String, f: Int, at: Double)] = []
        for b in st.books {
            for q in b.items(.quote) {
                let t = q.raw.str("text").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !t.isEmpty && t.count <= 240 { all.append((t, b.title, b.author, b.id + ":" + q.id, q.raw.bool("fav") ? 1 : 0, q.raw.num("at"))) }
            }
        }
        let sorted = all.enumerated().sorted { x, y in
            x.element.f != y.element.f ? x.element.f > y.element.f : (x.element.at != y.element.at ? x.element.at > y.element.at : x.offset < y.offset)
        }
        return sorted.prefix(60).map { ["t": $0.element.t, "b": $0.element.b, "a": $0.element.a, "id": $0.element.id] }
    }
}

extension Book {
    /// The book's colour as #rrggbb (the web's hslHex(bookColor(b))).
    var colorHex: String {
        let c = color ?? [hue, 38, 32]
        let h = c[0] / 360, s = c[1] / 100, l = c[2] / 100
        func f(_ n: Double) -> Int {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12), a = s * min(l, 1 - l)
            return Int((255 * (l - a * max(-1, min(k - 3, 9 - k, 1)))).rounded())
        }
        return String(format: "#%02x%02x%02x", f(0), f(8), f(4))
    }
}
