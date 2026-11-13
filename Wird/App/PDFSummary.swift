import SwiftUI
import UIKit
import WebKit

// The book summary («ملخص الكتاب»): web/js/06-extras.js, PDF_SECS … pdfMake. The page itself is built as HTML,
// character for character as the web app builds it, then PDFMaker turns it into an A4 PDF.

@MainActor
enum PDFSummary {
    /// PDF_SECS
    static let sections: [(String, String)] = [
        ("review", "المراجعة والتقييم"), ("quotes", "الاقتباسات"), ("thoughts", "الأفكار"),
        ("chars", "الشخصيات"), ("words", "الكلمات"), ("sess", "الجلسات")
    ]

    private static func truthy(_ o: JSONObject, _ k: String) -> Bool { o[k]?.truthy ?? false }

    /// pdfCount: how many entries a section would hold
    static func count(_ b: Book, _ key: String) -> Int {
        switch key {
        case "review":
            let vr = b.volReviews.values.filter { v in
                guard let r = v.object else { return false }
                return truthy(r, "rating") || truthy(r, "review")
            }.count
            let own = (b.rating != 0 || !b.review.isEmpty || !b.moods.isEmpty || !b.pace.isEmpty) ? 1 : 0
            return own + vr + b.history.filter { truthy($0, "rating") || truthy($0, "review") }.count
        case "sess": return Library.shared.state.sessions(of: b.id).count
        case "quotes": return b.quotes.count
        case "thoughts": return b.thoughts.count
        case "chars": return b.chars.count
        case "words": return b.words.count
        default: return 0
        }
    }

    private static func f(_ d: Double) -> String { JSONValue.format(d) }
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
    private static func jsRound(_ d: Double) -> Double { (d + 0.5).rounded(.down) }

    /// hexOfHSL
    private static func hexOfHSL(_ h: Double, _ s0: Double, _ l0: Double) -> String {
        let s = s0 / 100, l = l0 / 100
        let a = s * min(l, 1 - l)
        func ch(_ n: Double) -> String {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            let v = l - a * max(-1, min(k - 3, 9 - k, 1))
            return String(format: "%02lx", Int(min(255, max(0, jsRound(v * 255)))))
        }
        return "#" + ch(0) + ch(8) + ch(4)
    }

    private static func hsl(_ b: Book) -> (h: Double, s: Double, l: Double, raw: [Double]) {
        let c = b.color ?? [b.raw.num("hue", 0), 38, 32]
        return (c[0], min(c[1], 55), c[2], c)
    }

    /// pdfPalette: dark pages in the book's own colour
    static func palette(_ b: Book) -> (bg: String, acc: String, bar: String, mute: String, card: String, line: String, line2: String) {
        let c = hsl(b), h = c.h, s = c.s
        return (bg: hexOfHSL(h, jsRound(s * 0.6), 11),
                acc: "hsl(\(f(h)),\(f(clamp(s + 10, 30, 60)))%,77%)",
                bar: "hsl(\(f(h)),\(f(clamp(s, 30, 55)))%,60%)",
                mute: "rgba(239,233,223,.58)", card: "rgba(255,255,255,.055)",
                line: "rgba(255,255,255,.09)", line2: "rgba(255,255,255,.16)")
    }

    /// pdfImages: the cover, and the pictures of the sections that are in the file, as data URLs
    static func images(_ b: Book, _ sec: Set<String>) -> [String: String] {
        var ids: [String] = []
        if let c = b.cover, !c.isEmpty { ids.append(c) }
        if sec.contains("chars") { for c in b.chars { if let p = c.photo, !p.isEmpty { ids.append(p) } } }
        if sec.contains("quotes") { for q in b.quotes { if let p = q.img, !p.isEmpty { ids.append(p) } } }
        var out: [String: String] = [:]
        for id in ids where out[id] == nil {
            if let d = Store.shared.imageData(id) { out[id] = "data:" + Store.mime(of: d) + ";base64," + d.base64EncodedString() }
        }
        return out
    }

    /// «ملخص <title>.pdf», without the characters a file name cannot hold
    static func fileName(_ b: Book) -> String {
        let bad = Set("\\/:*?\"<>|")
        var t = "", lastBad = false
        for c in b.title {
            if bad.contains(c) { if !lastBad { t.append(" ") }; lastBad = true } else { t.append(c); lastBad = false }
        }
        return "ملخص " + t.trimmingCharacters(in: .whitespacesAndNewlines) + ".pdf"
    }

    // MARK: small helpers of pdfHTML

    private static func esc(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(c)
            }
        }
        return o
    }

    /// hueOf (01-core.js), over UTF-16 units like the web's charCodeAt
    private static func hueOf(_ s: String) -> Int {
        var h = 0
        for u in s.utf16 { h = (h * 31 + Int(u)) % 360 }
        return h
    }

    private static func stars(_ r: Double) -> String {
        var t = ""
        for i in 1...5 { t += Double(i) <= r ? "★" : "☆" }
        return "<span class=\"st\">" + t + "</span>"
    }

    private static func meta(_ arr: [String]) -> String {
        let a = arr.filter { !$0.isEmpty }
        return a.isEmpty ? "" : "<div class=\"mt\">" + a.joined(separator: " · ") + "</div>"
    }

    private static func ord(_ n: Int) -> String { Words.ord(n == 0 ? 1 : n) }

    /// locLabel(b, vol, loc): the position printed as the web prints it
    private static func locLabel(_ b: Book, _ x: NoteItem) -> String {
        guard let loc = x.loc else { return "" }
        return (b.series ? "م\(x.vol + 1) · " : "") + (b.unit.time ? Words.hm(loc) : b.unit.abbr + " " + f(loc))
    }

    /// pdfByLoc: read, volume, place, time (a stable sort)
    private static func byLoc(_ a: [NoteItem]) -> [NoteItem] {
        func key(_ x: NoteItem) -> [Double] { [Double(x.read == 0 ? 1 : x.read), Double(x.vol), x.loc ?? 1e9, x.at] }
        return a.enumerated().sorted { p, q in
            let k = key(p.element), m = key(q.element)
            for i in 0..<4 where k[i] != m[i] { return k[i] < m[i] }
            return p.offset < q.offset
        }.map { $0.element }
    }

    private static func unitCnt(_ unit: String, _ n: Double) -> String {
        if unit == "min" { return Words.fmtMin(n) }
        return Words.cnt(n, (Unit(rawValue: unit) ?? .page).forms)
    }

    // MARK: the page

    /// pdfHTML (the app case: fonts come from fonts/fonts.css)
    static func html(_ b: Book, _ sec: Set<String>, _ imgs: [String: String]) -> String {
        let c = hsl(b), h = c.h, s = c.s, cl = c.l
        let u = b.unit, v = b.verbs
        let st = Library.shared.state
        let ss = st.sessions(of: b.id)
        let min = ss.reduce(0.0) { $0 + $1.minutes }
        let sp = st.speed(ss, u)
        func img(_ id: String?) -> String { id.flatMap { imgs[$0] } ?? "" }
        let hist = b.history
        let multi = !hist.isEmpty
        let P = palette(b), acc = P.acc
        let heroL = f(Swift.min(42, cl + 8))

        let css = [
            "*{box-sizing:border-box;-webkit-print-color-adjust:exact;print-color-adjust:exact}html{background:\(P.bg)}",
            ##"body{margin:0;padding:40px 38px;font:400 12.5px/1.75 "IBM Plex Sans Arabic","Geeza Pro",sans-serif;color:#efe9df;background:transparent;-webkit-text-size-adjust:100%}"##,
            "@media print{body{padding:0}}",
            ".hero{display:flex;gap:22px;align-items:flex-end;padding:22px;border-radius:20px;background:linear-gradient(150deg,hsla(\(f(h)),\(f(s))%,\(heroL)%,.95),hsla(\(f(h)),\(f(s))%,\(heroL)%,0) 78%)}",
            ".cov{flex:none;width:118px;border-radius:5px;overflow:hidden;box-shadow:0 12px 28px rgba(0,0,0,.5);background:hsl(\(f(h)),\(f(s))%,\(f(cl))%)}.cov img{display:block;width:100%}",
            ##".cov.ph{height:176px;display:flex;align-items:center;justify-content:center;padding:12px;text-align:center;font:600 15px/1.5 "Reem Kufi",sans-serif}"##,
            ##".ht{flex:1;min-width:0}.kick{margin:0 0 2px;font-size:11px;color:\##(P.mute)}h1{margin:0;font:700 27px/1.35 "Reem Kufi",sans-serif;color:#fff}.by{margin:4px 0 0;font-size:13px;color:rgba(255,255,255,.8)}"##,
            ".hero .st{display:block;margin-top:8px;font-size:17px;letter-spacing:2px}.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}.chips span{padding:1px 10px;border-radius:99px;background:rgba(255,255,255,.12);font-size:10.5px}",
            ".facts{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px;margin-top:16px}.fact{padding:9px 12px;border-radius:12px;background:\(P.card);border:1px solid \(P.line)}",
            ##".fact b{display:block;font:600 16px/1.35 "Reem Kufi",sans-serif;color:\##(acc)}.fact span{font-size:10px;color:\##(P.mute)}"##,
            ##"h2{display:flex;align-items:baseline;gap:8px;margin:28px 0 12px;padding-bottom:6px;border-bottom:1px solid \##(P.line2);font:700 18px/1.3 "Reem Kufi",sans-serif;color:\##(acc);break-after:avoid;page-break-after:avoid}"##,
            ##"h2 small{font:500 11px "IBM Plex Sans Arabic",sans-serif;color:\##(P.mute)}h3{margin:16px 0 6px;font:600 13.5px "Reem Kufi",sans-serif;color:#fff;break-after:avoid;page-break-after:avoid}"##,
            ".mt{margin-top:3px;font-size:10.5px;color:\(P.mute)}.st{color:#ffd36b;letter-spacing:1px}",
            ".moods{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 10px}.moods span{padding:1px 10px;border-radius:99px;border:1px solid \(P.line2);font-size:10.5px;color:rgba(239,233,223,.8)}",
            ##".rv{margin:0;font:400 15px/1.95 "Amiri",serif;white-space:pre-wrap}.blk{break-inside:avoid;page-break-inside:avoid;margin:0 0 12px;padding:10px 14px;border-radius:12px;background:\##(P.card)}.blk .rv{font-size:14px}"##,
            ".qi{display:block;max-width:100%;max-height:300px;margin:2px 0 8px;border-radius:8px}",
            ##".q{break-inside:avoid;page-break-inside:avoid;margin:0 0 13px;padding:2px 14px 2px 0;border-right:3px solid \##(P.bar)}.q p{margin:0;font:400 15px/1.9 "Amiri",serif;color:#f6f1e8}"##,
            ##".th{break-inside:avoid;page-break-inside:avoid;margin:0 0 10px;padding:10px 14px;border-radius:12px;background:\##(P.card)}.th p{margin:0;white-space:pre-wrap}.th .ps{margin-top:6px;padding-right:10px;border-right:2px solid \##(P.line2);font:400 13px/1.85 "Amiri",serif;color:rgba(239,233,223,.72)}"##,
            ".chars{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.ch{break-inside:avoid;page-break-inside:avoid;display:flex;gap:10px;padding:10px 12px;border-radius:12px;background:\(P.card);border:1px solid \(P.line)}",
            ##".av{flex:none;width:38px;height:38px;border-radius:50%;display:flex;align-items:center;justify-content:center;overflow:hidden;font:600 16px "Reem Kufi",sans-serif}.av img{width:100%;height:100%;object-fit:cover}"##,
            ##".ch>div{min-width:0}.ch b{font:600 13.5px/1.5 "Reem Kufi",sans-serif;color:#fff}.ch p{margin:3px 0 0;font-size:11.5px;line-height:1.7}.ch p i{font-style:normal;color:\##(P.mute)}"##,
            "table{width:100%;border-collapse:collapse;font-size:11.5px}th{text-align:right;font-weight:600;color:\(acc);padding:6px 8px;border-bottom:1px solid \(P.line2)}",
            ##"td{padding:6px 8px;border-bottom:1px solid \##(P.line);vertical-align:top}tr{break-inside:avoid;page-break-inside:avoid}.w{font-weight:600;color:#fff}.ex{display:block;margin-top:2px;font:400 12.5px/1.7 "Amiri",serif;color:rgba(239,233,223,.7)}.num{font-variant-numeric:tabular-nums}"##,
            "footer{margin-top:32px;padding-top:12px;border-top:1px solid \(P.line);display:flex;justify-content:space-between;align-items:baseline;gap:12px;font-size:10.5px;color:\(P.mute);break-inside:avoid}",
            ##"footer b{font:700 14px "Reem Kufi",sans-serif;color:\##(acc)}footer i{font:400 12.5px "Amiri",serif;font-style:normal;color:rgba(239,233,223,.75)}"##
        ].joined()
        let font = "<link rel=\"stylesheet\" href=\"fonts/fonts.css\">"

        // hero
        var by = [b.author]
        if b.translated && !b.translator.isEmpty { by.append("ترجمة " + b.translator) }
        if b.format == .audio && !b.narrator.isEmpty { by.append("بصوت " + b.narrator) }
        by = by.filter { !$0.isEmpty }
        var chips = [b.status.label, b.format.label + (b.series ? " · " + Words.cnt(Double(b.volumes.count), Words.vols) : "")]
        chips += b.genres.prefix(4)
        if multi { chips.append("قرأته " + Words.cnt(Double(hist.count + (b.status == .done ? 1 : 0)), Words.times)) }
        let cover = img(b.cover)
        let cov = cover.isEmpty ? "<div class=\"cov ph\">" + esc(b.title) + "</div>" : "<div class=\"cov\"><img src=\"" + cover + "\" alt=\"\"></div>"
        var out = "<header class=\"hero\">" + cov + "<div class=\"ht\"><p class=\"kick\">ملخص قراءة</p><h1>" + esc(b.title) + "</h1>"
            + (by.isEmpty ? "" : "<p class=\"by\">" + esc(by.joined(separator: " · ")) + "</p>")
            + (b.rating != 0 ? stars(b.rating) : "")
            + "<div class=\"chips\">" + chips.filter { !$0.isEmpty }.map { "<span>" + esc($0) + "</span>" }.joined() + "</div></div></header>"

        // facts
        var fa: [(String, String)] = []
        let tot = b.sumTotal, p = b.pct
        if let a = b.start, a > 0 { fa.append((Words.date(a, year: true), "بدأت")) }
        if let z = b.finish, z > 0 { fa.append((Words.date(z, year: true), "أنهيت")) }
        if let a = b.start, a > 0, let z = b.finish, z > 0 {
            fa.append((Words.cnt(Swift.max(1, jsRound((z - a) / DAY)), Words.days), "مدة القراءة"))
        } else if b.status == .reading, let p = p {
            fa.append(("\(Int(jsRound(p * 100)))٪", "وصلت"))
        }
        if tot != 0 { fa.append(u.time ? (Words.fmtMin(tot), "مدة الكتاب") : (Words.n0(tot), u.plu)) }
        if min != 0 { fa.append((Words.fmtMin(min), v.time)) }
        if !ss.isEmpty { fa.append((Words.n0(Double(ss.count)), "الجلسات")) }
        if let sp = sp, sp != 0, !u.time { fa.append((Words.n0(sp), u.pl + " في الساعة")) }
        if !b.quotes.isEmpty { fa.append((Words.n0(Double(b.quotes.count)), "اقتباسات")) }
        if !fa.isEmpty {
            out += "<div class=\"facts\">" + fa.prefix(8).map { "<div class=\"fact\"><b class=\"num\">" + esc($0.0) + "</b><span>" + esc($0.1) + "</span></div>" }.joined() + "</div>"
        }

        // review
        if sec.contains("review") && count(b, "review") > 0 {
            let pace = Words.paces[b.pace]
            out += "<h2>المراجعة" + (multi ? "<small>القراءة " + ord(b.readNo) + "</small>" : "") + "</h2>"
            if !b.moods.isEmpty || pace != nil {
                out += "<div class=\"moods\">" + b.moods.map { "<span>" + esc($0) + "</span>" }.joined() + (pace.map { "<span>الإيقاع: " + $0 + "</span>" } ?? "") + "</div>"
            }
            if !b.review.isEmpty { out += "<p class=\"rv\">" + esc(b.review) + "</p>" }
            else if b.rating != 0 { out += "<p class=\"mt\">" + stars(b.rating) + "</p>" }
            var vrs = ""
            for (i, vo) in b.volumes.enumerated() {
                guard let r = b.volReviews[vo.id]?.object, truthy(r, "rating") || truthy(r, "review") else { continue }
                vrs += "<div class=\"blk\"><h3 style=\"margin-top:0\">المجلد \(i + 1)" + (vo.title.isEmpty ? "" : " · " + esc(vo.title))
                    + (truthy(r, "rating") ? " " + stars(r.num("rating")) : "") + "</h3>"
                    + (r.str("review").isEmpty ? "" : "<p class=\"rv\">" + esc(r.str("review")) + "</p>") + "</div>"
            }
            if !vrs.isEmpty { out += "<h3>مراجعات المجلدات</h3>" + vrs }
            var hs = ""
            for x in hist where truthy(x, "rating") || truthy(x, "review") {
                let when = (x.optNum("start") ?? 0) > 0
                    ? Words.date(x.optNum("start"), year: true) + ((x.optNum("finish") ?? 0) > 0 ? " ← " + Words.date(x.optNum("finish"), year: true) : "") : ""
                hs += "<div class=\"blk\"><h3 style=\"margin-top:0\">القراءة " + ord(x.int("n")) + (truthy(x, "rating") ? " " + stars(x.num("rating")) : "") + "</h3>"
                    + meta([when]) + (x.str("review").isEmpty ? "" : "<p class=\"rv\">" + esc(x.str("review")) + "</p>") + "</div>"
            }
            if !hs.isEmpty { out += "<h3>القراءات السابقة</h3>" + hs }
        }
        func head2(_ t: String, _ n: Int) -> String { "<h2>" + t + "<small>\(n)</small></h2>" }

        // quotes
        if sec.contains("quotes") && !b.quotes.isEmpty {
            out += head2("الاقتباسات", b.quotes.count)
            for x in byLoc(b.quotes) {
                let sid = x.raw.str("speakerId")
                let spk = !sid.isEmpty && sid != "__o" ? (b.chars.first { $0.id == sid }?.name ?? "") : x.raw.str("speakerName")
                let qi = img(x.img), hasImg = !(x.img ?? "").isEmpty
                out += "<div class=\"q\">" + (qi.isEmpty ? "" : "<img class=\"qi\" src=\"" + qi + "\" alt=\"\">")
                    + (x.text.isEmpty ? "" : "<p>" + (hasImg ? esc(x.text) : "«" + esc(x.text) + "»") + "</p>")
                    + meta([x.fav ? "<span class=\"st\">★</span>" : "", spk.isEmpty ? "" : "— " + esc(spk), esc(locLabel(b, x)),
                            multi ? "القراءة " + ord(x.read) : ""]) + "</div>"
            }
        }

        // thoughts
        if sec.contains("thoughts") && !b.thoughts.isEmpty {
            out += head2("أفكاري", b.thoughts.count)
            for x in byLoc(b.thoughts) {
                out += "<div class=\"th\"><p>" + esc(x.text) + "</p>" + (x.passage.isEmpty ? "" : "<p class=\"ps\">" + esc(x.passage) + "</p>")
                    + meta([esc(locLabel(b, x)), Words.date(x.at, year: true)]) + "</div>"
            }
        }

        // characters
        if sec.contains("chars") && !b.chars.isEmpty {
            let all = b.chars
            func rank(_ r: String) -> Int { r == "main" ? 0 : r == "secondary" ? 1 : 2 }
            let sorted = all.enumerated().sorted { p, q in
                let a = rank(p.element.role), z = rank(q.element.role)
                if a != z { return a < z }
                if p.element.at != q.element.at { return p.element.at < q.element.at }
                return p.offset < q.offset
            }.map { $0.element }
            out += head2("الشخصيات", all.count) + "<div class=\"chars\">"
            for ch in sorted {
                let name = ch.name.isEmpty ? "?" : ch.name
                let hu = hueOf(name)
                let age = ch.raw.str("age")
                let sub = [ch.alias, ch.role == "main" ? "رئيسية" : ch.role == "secondary" ? "ثانوية" : "", age.isEmpty ? "" : "العمر: " + age].filter { !$0.isEmpty }
                func ln(_ l: String, _ t: String) -> String { t.isEmpty ? "" : "<p>" + (l.isEmpty ? "" : "<i>" + l + ": </i>") + esc(t) + "</p>" }
                let rel = ch.rel.compactMap { r -> String? in
                    guard let o = all.first(where: { $0.id == r.str("to") }) else { return nil }
                    let lab = r.str("label")
                    return (lab.isEmpty ? "" : esc(lab) + " ") + esc(o.name)
                }.joined(separator: "، ")
                let initial = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
                let photo = img(ch.photo)
                var custom = ""
                for r in ch.custom where !r.str("k").isEmpty && !r.str("v").isEmpty { custom += ln(esc(r.str("k")), r.str("v")) }
                out += "<div class=\"ch\"><span class=\"av\" style=\"background:hsl(\(hu),32%,27%);color:hsl(\(hu),60%,84%)\">"
                    + (photo.isEmpty ? esc(initial) : "<img src=\"" + photo + "\" alt=\"\">") + "</span><div><b>" + esc(ch.name) + "</b>" + meta(sub.map(esc))
                    + ln("", ch.desc) + ln("الشكل", ch.raw.str("appearance")) + ln("الصفات", ch.raw.str("traits")) + ln("العيوب", ch.raw.str("flaws")) + ln("الموت", ch.raw.str("death"))
                    + custom + (rel.isEmpty ? "" : "<p><i>العلاقات: </i>" + rel + "</p>") + "</div></div>"
            }
            out += "</div>"
        }

        // words
        if sec.contains("words") && !b.words.isEmpty {
            out += head2("الكلمات", b.words.count)
                + "<table><thead><tr><th style=\"width:28%\">الكلمة</th><th>المعنى</th><th style=\"width:16%\">الموضع</th></tr></thead><tbody>"
            for w in byLoc(b.words) {
                let lg = w.raw.str("lang"), lname = Words.lang(lg)
                let mean = [w.raw.str("tr"), w.meaning].filter { !$0.isEmpty }.joined(separator: " — ")
                let ex = w.raw.str("ex")
                out += "<tr><td><span class=\"w\" dir=\"auto\">" + esc(w.word) + "</span>"
                    + (!lg.isEmpty && lg != "ar" && !lname.isEmpty ? "<div class=\"mt\">" + esc(lname) + "</div>" : "")
                    + "</td><td>" + esc(mean) + (ex.isEmpty ? "" : "<span class=\"ex\">" + esc(ex) + "</span>")
                    + "</td><td class=\"num\">" + esc(locLabel(b, w)) + "</td></tr>"
            }
            out += "</tbody></table>"
        }

        // sessions
        if sec.contains("sess") && !ss.isEmpty {
            out += head2("الجلسات", ss.count) + "<table><thead><tr><th>التاريخ</th>" + (multi ? "<th>القراءة</th>" : "") + "<th>المدة</th><th>الإنجاز</th></tr></thead><tbody>"
            for x in ss.enumerated().sorted(by: { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }).map({ $0.element }) {
                out += "<tr><td>" + Words.date(x.start, year: true) + "</td>" + (multi ? "<td>" + ord(x.read) + "</td>" : "")
                    + "<td class=\"num\">" + Words.fmtMin(x.minutes) + "</td><td class=\"num\">" + unitCnt(x.unit, x.units) + "</td></tr>"
            }
            out += "</tbody></table>"
        }

        out += "<footer><span><b>جَليس</b> · <i>وخيرُ جليسٍ في الزمانِ كتابُ</i></span><span>" + Words.date(Millis.now, year: true) + "</span></footer>"
        return "<!doctype html><html lang=\"ar\" dir=\"rtl\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=595\"><title>"
            + esc(b.title) + "</title>" + font + "<style>" + css + "</style></head><body>" + out + "</body></html>"
    }
}

// MARK: - the sheet (SH.pdfSum)

struct PDFSummarySheet: View {
    let bookID: String
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    /// the switches the owner touched; the rest follow the defaults (on when there is something, except the sessions)
    @State private var touched: [String: Bool] = [:]
    @State private var busy = false
    @State private var maker: PDFMaker?
    @State private var previewHTML = ""
    @State private var contentH: CGFloat = 842

    private var book: Book? { lib.state.book(bookID) }

    private func isOn(_ b: Book, _ k: String) -> Bool {
        PDFSummary.count(b, k) > 0 && (touched[k] ?? (k != "sess"))
    }
    private func selected(_ b: Book) -> Set<String> { Set(PDFSummary.sections.map { $0.0 }.filter { isOn(b, $0) }) }

    /// changes whenever a switch changes, which restarts the debounced preview
    private var previewKey: String {
        guard let b = book else { return "" }
        return selected(b).sorted().joined(separator: ",")
    }

    private func sub(_ b: Book, _ k: String) -> String {
        let n = PDFSummary.count(b, k)
        if n == 0 { return "ما فيه شي بعد" }
        return k == "review" ? "مراجعتك وتقييمك" + (b.history.isEmpty ? "" : " مع القراءات السابقة") : "\(n) في الملف"
    }

    var body: some View {
        JSheet(title: "ملخص الكتاب") {
            if let b = book {
                (Text("ملف PDF مرتب بحجم A4 فيه كل اللي كتبته عن ").font(JFont.body(14))
                    + Text(b.title).font(JFont.body(14, .semibold))
                    + Text(". اختر وش يدخل فيه:").font(JFont.body(14)))
                    .foregroundStyle(Color(L.ink2))
                    .frame(maxWidth: .infinity, alignment: .leading)
                JPanel {
                    ForEach(PDFSummary.sections, id: \.0) { s in
                        let n = PDFSummary.count(b, s.0)
                        JSwitchRow(title: s.1, sub: sub(b, s.0),
                                   on: Binding(get: { isOn(b, s.0) }, set: { touched[s.0] = $0 }))
                            .disabled(n == 0).opacity(n == 0 ? 0.5 : 1)
                    }
                }
                Button { make() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                        Text(busy ? "جاري التجهيز…" : "إنشاء ملف PDF")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(JButtonStyle(look: L, primary: true))
                .disabled(busy)
                Text("معاينة").font(JFont.display(16, .semibold)).foregroundStyle(Color(L.ink))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear
                    .aspectRatio(595 / max(contentH, 1), contentMode: .fit)
                    .overlay(PDFPreview(html: previewHTML, contentHeight: $contentH))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
            }
        }
        .task(id: previewKey) { await refreshPreview() }
    }

    /// about 0.12 s after the last switch, so quick taps build one preview
    @MainActor private func refreshPreview() async {
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }
        guard let b = book else { return }
        let sel = selected(b)
        previewHTML = PDFSummary.html(b, sel, PDFSummary.images(b, sel))
    }

    /// pdfMake
    private func make() {
        guard !busy, let b = book else { return }
        let host = NovelBridge.host?.view ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.compactMap(\.keyWindow).first?.rootViewController?.view
        guard let hostView = host else { ToastCenter.shared.show("تعذّر إنشاء الملف"); return }
        busy = true
        let sel = selected(b)
        let html = PDFSummary.html(b, sel, PDFSummary.images(b, sel))
        let name = PDFSummary.fileName(b)
        let m = PDFMaker()
        maker = m // kept until it answers
        m.make(html: html, bg: PDFSummary.palette(b).bg, in: hostView) { data in
            Task { @MainActor in
                maker = nil
                guard let data = data else { busy = false; ToastCenter.shared.show("تعذّر إنشاء الملف"); return }
                Share.data(data, name: name) { shared in
                    busy = false
                    ToastCenter.shared.show(shared ? "تم حفظ الملف" : "تم الإلغاء")
                }
            }
        }
    }
}

// MARK: - the live preview

/// The summary page in a web view 595 px wide, scaled down to the width it is given; its height follows the content.
private struct PDFPreview: UIViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat

    final class Host: UIView {
        let web: WKWebView
        var contentH: CGFloat = 842
        init(web: WKWebView) {
            self.web = web
            super.init(frame: .zero)
            clipsToBounds = true
            addSubview(web)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            let k = bounds.width / 595
            guard k > 0 else { return }
            web.transform = .identity
            web.bounds = CGRect(x: 0, y: 0, width: 595, height: contentH)
            web.transform = CGAffineTransform(scaleX: k, y: k)
            web.center = CGPoint(x: 595 * k / 2, y: contentH * k / 2)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = ""
        var token = 0
        var report: (CGFloat) -> Void = { _ in }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let mine = token
            let js = "await document.fonts.ready; await Promise.all([...document.images].map(i => i.decode ? i.decode().catch(() => 0) : 0)); return document.documentElement.scrollHeight"
            webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] r in
                guard let self = self, mine == self.token, case .success(let v) = r, let n = v as? NSNumber, n.doubleValue > 0 else { return }
                DispatchQueue.main.async { self.report(CGFloat(n.doubleValue)) }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Host {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: AppSchemeHandler.scheme)
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842), configuration: cfg)
        w.navigationDelegate = context.coordinator
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.isUserInteractionEnabled = false
        return Host(web: w)
    }

    func updateUIView(_ host: Host, context: Context) {
        let co = context.coordinator
        co.report = { h in contentHeight = h }
        if host.contentH != contentHeight { host.contentH = contentHeight; host.setNeedsLayout() }
        if !html.isEmpty && html != co.loaded {
            co.loaded = html
            co.token += 1
            host.web.loadHTMLString(html, baseURL: URL(string: AppSchemeHandler.scheme + "://app/"))
        }
    }
}
