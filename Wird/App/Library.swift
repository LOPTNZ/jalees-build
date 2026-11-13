import Foundation
import UIKit
import Combine

/// The library in memory. It is read from and saved to the same state.json the web app used (Store), so nothing has
/// to move: the books, sessions, notebook and pictures are already there. Changes are saved a moment later, together.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published var state: AppState
    /// true on the very first launch with no library yet
    let firstRun: Bool
    private var saveWork: DispatchWorkItem?

    private init() {
        // the web app's library, untouched, from before the first save of this version
        Store.shared.keepCopy(as: "state.before-swift.json")
        if let d = Store.shared.loadStateData(), let o = JSONValue.parse(d)?.object, o["books"]?.array != nil {
            state = AppState(Library.upgrade(o))
            firstRun = false
        } else {
            // a file that is there but can't be read is kept aside before anything new is written
            if Store.shared.loadStateData() != nil { Store.shared.keepCopy(as: "state.unreadable-\(Int(Date().timeIntervalSince1970)).json") }
            firstRun = true
            state = AppState(Library.upgrade(Library.edition == "demo" ? Library.seed() : Library.empty()))
            scheduleSave()
        }
    }

    /// "clean" starts empty, "demo" with sample books (Info.plist WirdEdition)
    static var edition: String { (Bundle.main.object(forInfoDictionaryKey: "WirdEdition") as? String) ?? "clean" }

    // MARK: changing and saving

    /// Every change goes through here, so it is saved.
    func change(_ f: (inout AppState) -> Void) {
        f(&state)
        scheduleSave()
    }

    func changeBook(_ id: String, _ f: (inout Book) -> Void) {
        guard let i = state.index(of: id) else { return }
        change { f(&$0.books[i]) }
    }

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let d = JSONValue.object(state.json).data(), let s = String(data: d, encoding: .utf8) else { return }
        Store.shared.saveState(s)
        WidgetFeed.schedule()
    }

    // MARK: pictures (same files as before: Application Support/Wird/img/<id>)

    private let images = NSCache<NSString, UIImage>()

    func image(_ id: String?) -> UIImage? {
        guard let id = id, !id.isEmpty else { return nil }
        if let i = images.object(forKey: id as NSString) { return i }
        guard let i = Store.shared.image(id) else { return nil }
        images.setObject(i, forKey: id as NSString)
        return i
    }

    /// Saves a picture and returns its new id.
    func putImage(_ img: UIImage, quality: CGFloat = 0.84, prefix: String = "i") -> String? {
        guard let d = img.jpegData(compressionQuality: quality) else { return nil }
        let id = prefix + uid()
        Store.shared.putImage(id, dataURL: "data:image/jpeg;base64," + d.base64EncodedString())
        images.setObject(img, forKey: id as NSString)
        return id
    }

    /// Pictures may have changed on disk (a restored backup): read them again.
    func forgetImages() { images.removeAllObjects() }

    func deleteImage(_ id: String?) {
        guard let id = id, !id.isEmpty else { return }
        images.removeObject(forKey: id as NSString)
        Store.shared.deleteImage(id)
    }

    // MARK: the web app's rules for stored data (upgrade, fixBook, blankBook, emptyState)

    static func upgrade(_ s: JSONObject) -> JSONObject {
        var s = s
        // settings: the defaults under what is stored, the nested ones too
        var set = Settings.defaults()
        let stored = s.obj("set")
        for (k, v) in stored { set[k] = v }
        for k in ["remind", "f", "show"] {
            var d = Settings.defaults().obj(k)
            for (kk, vv) in stored.obj(k) { d[kk] = vv }
            set[k] = .object(d)
        }
        if !["walnut", "library"].contains(set.str("shelfTheme")) { set.set("shelfTheme", "walnut") }
        s["set"] = .object(set)
        if s["goals"]?.object == nil { s["goals"] = .object(["daily": .number(30), "year": .number(12)]) }
        s.set("sessions", objects: s.objs("sessions").map { x in
            var x = x
            if x["read"] == nil || x["read"]?.isNull == true { x.set("read", 1) }
            return x
        })
        s.set("books", objects: s.objs("books").map(fixBook))
        if s["ach"]?.object == nil { s["ach"] = .object([:]) }
        s.set("v", 3)
        return s
    }

    static func blankBook() -> JSONObject {
        [
            "id": .string(uid()), "title": .string(""), "author": .string(""), "lang": .string("ar"), "translated": .bool(false),
            "origLang": .string("en"), "translator": .string(""), "narrator": .string(""), "structure": .string("volume"),
            "format": .string("physical"), "audioBy": .string("time"), "speed": .number(1), "series": .bool(false),
            "volumes": .array([.object(Volume.blank().raw)]), "ongoing": .bool(false), "vi": .number(0), "pos": .number(0),
            "status": .string("want"), "genres": .array([]), "cols": .array([]), "cover": .null, "coverRatio": .null,
            "spine": .null, "spineRatio": .null, "color": .null, "hue": .number(Double(Int.random(in: 0..<360))), "dims": .null,
            "start": .null, "finish": .null, "rating": .number(0), "review": .string(""), "moods": .array([]), "pace": .string(""),
            "volReviews": .object([:]), "readNo": .number(1), "history": .array([]), "target": .string(""), "platform": .string(""),
            "link": .string(""), "isbn": .string(""),
            "purchase": .object(["where": .string(""), "price": .string(""), "date": .string(""), "gift": .bool(false), "giftFrom": .string("")]),
            "loan": .object(["lent": .bool(false), "lentTo": .string(""), "lentDate": .string(""), "borrowed": .bool(false), "borrowedFrom": .string(""), "borrowedDate": .string("")]),
            "quotes": .array([]), "thoughts": .array([]), "words": .array([]), "chars": .array([]),
            "added": .number(Millis.now), "opened": .number(0)
        ]
    }

    static func fixBook(_ b: JSONObject) -> JSONObject {
        var b = b
        if b["audioBy"] == nil { b.set("audioBy", b.str("format") == "audio" ? "chapters" : "time") }
        for (k, v) in blankBook() where b[k] == nil { b[k] = v }
        if b.arr("volumes").isEmpty { b["volumes"] = .array([.object(Volume.blank().raw)]) }
        for k in ["purchase", "loan"] {
            var d = blankBook().obj(k)
            for (kk, vv) in b.obj(k) { d[kk] = vv }
            b[k] = .object(d)
        }
        for k in ["quotes", "thoughts", "words", "chars", "genres", "cols", "history", "moods"] where b[k]?.array == nil { b[k] = .array([]) }
        b.set("chars", objects: b.objs("chars").map { c in
            var c = c
            if c.str("gender") == "o" { c.set("gender", "") }
            if c["rel"]?.array == nil { c["rel"] = .array([]) }
            if c["custom"]?.array == nil { c["custom"] = .array([]) }
            return c
        })
        if b["volReviews"]?.object == nil { b["volReviews"] = .object([:]) }
        // novels and EPUB books keep their highlights and bookmarks on the book
        if b["novel"]?.object != nil {
            if b["marks"]?.array == nil { b["marks"] = .array([]) }
            if b["bmarks"]?.array == nil { b["bmarks"] = .array([]) }
        }
        return b
    }

    static func empty() -> JSONObject {
        [
            "v": .number(3), "demo": .bool(false), "books": .array([]), "sessions": .array([]),
            "goals": .object(["daily": .number(30), "year": .number(12)]), "set": .object(Settings.defaults()),
            "shelf": .null, "timer": .null, "lastBook": .null, "ach": .object([:]), "achInit": .bool(true), "imgMig": .bool(true)
        ]
    }

    /// The demo library (the web app's seed), its times moved so they end today, and its four covers.
    static func seed() -> JSONObject {
        guard let u = Bundle.main.url(forResource: "seed", withExtension: "json"), let d = try? Data(contentsOf: u),
              var o = JSONValue.parse(d)?.object else { return empty() }
        let shift = Millis.now - o.num("seedAt", Millis.now)
        o["seedAt"] = nil
        func move(_ v: JSONValue) -> JSONValue {
            switch v {
            case .object(var x):
                for (k, vv) in x {
                    if ["start", "finish", "added", "opened", "at"].contains(k), let n = vv.double, n > 1e12 { x[k] = .number(n + shift) } else { x[k] = move(vv) }
                }
                return .object(x)
            case .array(let a): return .array(a.map(move))
            default: return v
            }
        }
        o = move(.object(o)).object ?? o
        for id in ["s_mis", "s_lotm", "s_lotm_sp", "s_aga"] where !Store.shared.hasImage(id) {
            if let u = Bundle.main.url(forResource: id, withExtension: "jpg"), let d = try? Data(contentsOf: u) {
                Store.shared.putImage(id, dataURL: "data:image/jpeg;base64," + d.base64EncodedString())
            }
        }
        return o
    }
}
