import Foundation
import AVFoundation
import CryptoKit

/// Gemini reads aloud: an accurate Arabic reading (fusha with its case endings) that the phone's voices can't give.
/// The user's own free key from Google AI Studio, kept only on the phone (the novels' database, not the backups).
/// The speech models are tried most accurate first; each has its own free daily allowance, so when one runs out the
/// next one reads. When every one is out for the day, Gemini's text model puts the diacritics (tashkeel) in and the
/// phone's voice reads that; without a key, or offline, the phone's voice reads the text as it is.
/// Audio is kept on the phone (by voice and text), so a passage is asked for once.
@MainActor
enum GeminiVoice {
    // MARK: settings

    /// One of the user's keys. The list lives in the Keychain (Secrets), never in the database, the backups or logs.
    struct KeyEntry: Codable, Identifiable, Equatable {
        var id: String
        var label: String
        var key: String
    }

    /// The keys in the order they are used: the first until its allowance is out, then the next, and so on.
    /// The single key of the older versions (`gemini.key`) becomes the first one.
    static var entries: [KeyEntry] {
        get {
            // in the Keychain (Secrets); an older copy in the database moves there on the first read
            if let s = Secrets.read("gemini.keys", kv: "gemini.keys"), let d = s.data(using: .utf8),
               let a = try? JSONDecoder().decode([KeyEntry].self, from: d) { return a }
            let old = (DB.shared.get("gemini.key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !old.isEmpty else { return [] }
            let a = [KeyEntry(id: UUID().uuidString, label: "", key: old)]
            save(a)
            DB.shared.set("gemini.key", nil)
            return a
        }
        set { save(newValue) }
    }

    private static func save(_ a: [KeyEntry]) {
        if let d = try? JSONEncoder().encode(a), let s = String(data: d, encoding: .utf8) {
            Secrets.set("gemini.keys", s)
            DB.shared.set("gemini.keys", nil)
        }
        badKeys = []
        badKey = false
    }

    /// The first key (kept for the code that only needs to know there is one).
    static var key: String {
        get { entries.first?.key ?? "" }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            var a = entries
            if v.isEmpty { if !a.isEmpty { a.removeFirst() } }
            else if a.isEmpty { a = [KeyEntry(id: UUID().uuidString, label: "", key: v)] }
            else { a[0].key = v }
            entries = a
        }
    }
    static var hasKey: Bool { !entries.isEmpty }
    /// set when Google said no to every key; cleared when the keys change
    static var badKey = false
    /// keys Google said no to (until the keys change or the app starts again)
    private(set) static var badKeys: Set<String> = []

    /// Adds a key at the end of the list; false when it is empty or already there.
    @discardableResult
    static func addKey(_ raw: String, label: String = "") -> Bool {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var a = entries
        guard !k.isEmpty, !a.contains(where: { $0.key == k }) else { return false }
        a.append(KeyEntry(id: UUID().uuidString, label: label.trimmingCharacters(in: .whitespacesAndNewlines), key: k))
        entries = a
        return true
    }

    static func removeKey(_ id: String) {
        entries = entries.filter { $0.id != id }
        for m in models + textModels {
            DB.shared.set("tts.out.\(id).\(m)", nil)
            DB.shared.set("tts.outat.\(id).\(m)", nil)
        }
    }

    /// moves a key one place up (-1) or down (+1) in the order
    static func moveKey(_ id: String, by d: Int) {
        var a = entries
        guard let i = a.firstIndex(where: { $0.id == id }), a.indices.contains(i + d) else { return }
        a.swapAt(i, i + d)
        entries = a
    }

    enum KeyState: Equatable {
        case working
        case rejected
        /// every speech model is out for today: since when (seconds since 1970), and until when
        case out(since: Double, until: Double)
    }

    /// For the settings: is this key working, refused by Google, or out of speech allowance for today?
    static func state(of id: String) -> KeyState {
        if badKeys.contains(id) { return .rejected }
        let now = Date().timeIntervalSince1970
        let outs = models.map { outUntil(id, $0) }
        guard outs.allSatisfy({ GeminiKeyRotation.isOut(until: $0, now: now) }) else { return .working }
        let since = models.compactMap { Double(DB.shared.get("tts.outat.\(id).\($0)") ?? "") }.max() ?? now
        return .out(since: since, until: outs.min() ?? nextReset())
    }

    enum Engine: String, CaseIterable {
        case gemini, tashkeel, phone
        var title: String {
            switch self {
            case .gemini: return "Gemini (الأدق)"
            case .tashkeel: return "صوت الجوال مع تشكيل Gemini"
            case .phone: return "صوت الجوال"
            }
        }
    }

    /// The reading the user chose; Gemini by default once there is a key.
    static var engine: Engine {
        get {
            guard hasKey else { return .phone }
            return Engine(rawValue: DB.shared.get("tts.engine") ?? "") ?? .gemini
        }
        set { DB.shared.set("tts.engine", newValue.rawValue) }
    }

    static var voice: String {
        get { let v = DB.shared.get("tts.gvoice") ?? ""; return v.isEmpty ? "Charon" : v }
        set { DB.shared.set("tts.gvoice", newValue) }
    }

    struct Voice { let id: String; let male: Bool; let tone: String }
    /// Gemini's 30 voices; every one speaks Arabic.
    static let voices: [Voice] = [
        Voice(id: "Charon", male: true, tone: "واضح، راوٍ"), Voice(id: "Iapetus", male: true, tone: "صافي"),
        Voice(id: "Sadaltager", male: true, tone: "رزين، عارف"), Voice(id: "Rasalgethi", male: true, tone: "راوٍ"),
        Voice(id: "Orus", male: true, tone: "ثابت"), Voice(id: "Alnilam", male: true, tone: "ثابت"),
        Voice(id: "Schedar", male: true, tone: "متزن"), Voice(id: "Algieba", male: true, tone: "ناعم"),
        Voice(id: "Umbriel", male: true, tone: "مريح"), Voice(id: "Enceladus", male: true, tone: "هامس"),
        Voice(id: "Algenib", male: true, tone: "خشن"), Voice(id: "Achird", male: true, tone: "ودود"),
        Voice(id: "Zubenelgenubi", male: true, tone: "عفوي"), Voice(id: "Sadachbia", male: true, tone: "حيوي"),
        Voice(id: "Puck", male: true, tone: "مرح"), Voice(id: "Fenrir", male: true, tone: "متحمّس"),
        Voice(id: "Kore", male: false, tone: "ثابت"), Voice(id: "Erinome", male: false, tone: "صافي"),
        Voice(id: "Sulafat", male: false, tone: "دافئ"), Voice(id: "Vindemiatrix", male: false, tone: "لطيف"),
        Voice(id: "Achernar", male: false, tone: "هادئ"), Voice(id: "Despina", male: false, tone: "ناعم"),
        Voice(id: "Gacrux", male: false, tone: "ناضج"), Voice(id: "Callirrhoe", male: false, tone: "مريح"),
        Voice(id: "Aoede", male: false, tone: "خفيف"), Voice(id: "Leda", male: false, tone: "شبابي"),
        Voice(id: "Zephyr", male: false, tone: "مشرق"), Voice(id: "Autonoe", male: false, tone: "مشرق"),
        Voice(id: "Laomedeia", male: false, tone: "مرح"), Voice(id: "Pulcherrima", male: false, tone: "مباشر"),
    ]

    /// The speech models, most accurate first.
    static let models = ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts", "gemini-3.1-flash-tts-preview",
                         "gemini-2.5-pro-preview-tts", "gemini-2.5-flash-preview-tts"]
    /// The text models that write the diacritics in.
    static let textModels = ["gemini-3.5-flash-lite", "gemini-flash-latest", "gemini-3.1-flash-lite", "gemini-2.5-flash-lite"]

    enum Failure: LocalizedError {
        case noKey, badKey, exhausted, offline, failed(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "ما فيه مفتاح Gemini"
            case .badKey: return "مفتاح Gemini ما اشتغل، تأكد منه في الإعدادات ← متقدمة"
            case .exhausted: return "خلص حد Gemini المجاني لليوم"
            case .offline: return "ما فيه اتصال"
            case .failed(let s): return s
            }
        }
    }

    // MARK: allowances

    /// a model is out for a key until this time (seconds since 1970): its daily allowance ran out, or it isn't offered
    static func outUntil(_ id: String, _ m: String) -> Double { Double(DB.shared.get("tts.out.\(id).\(m)") ?? "") ?? 0 }
    private static func markOut(_ id: String, _ m: String, until t: Double) {
        let now = Date().timeIntervalSince1970
        if !GeminiKeyRotation.isOut(until: outUntil(id, m), now: now) { DB.shared.set("tts.outat.\(id).\(m)", String(Int(now))) }
        DB.shared.set("tts.out.\(id).\(m)", String(Int(t)))
    }
    /// per-minute limits: the model rests for a bit (per key and model)
    private static var resting: [String: Date] = [:]

    private static func usable(_ id: String, _ m: String) -> Bool {
        !badKeys.contains(id) && !GeminiKeyRotation.isOut(until: outUntil(id, m), now: Date().timeIntervalSince1970)
    }

    /// Daily allowances start again at midnight in California.
    static func nextReset() -> Double { GeminiKeyRotation.nextReset(after: Date().timeIntervalSince1970) }

    /// Is any speech model left today, with any key?
    static var speechLeft: Bool {
        let a = entries
        return models.contains { m in a.contains { usable($0.id, m) } }
    }

    // MARK: the audio of a passage

    private static var inflight: [String: Task<URL, Error>] = [:]

    static func cacheDir() -> URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The passage's audio file (made once, then kept).
    static func audio(_ text: String) async throws -> URL {
        guard hasKey, !badKey else { throw Failure.noKey }
        let id = hash(voice + "\n" + text)
        for ext in ["m4a", "wav"] {
            let f = cacheDir().appendingPathComponent(id + "." + ext)
            if FileManager.default.fileExists(atPath: f.path) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
                return f
            }
        }
        if let t = inflight[id] { return try await t.value }
        let v = voice
        let t = Task<URL, Error> { try await make(text, id: id, voice: v) }
        inflight[id] = t
        defer { inflight[id] = nil }
        return try await t.value
    }

    /// Models in order; for each, the keys in order (a key that ran out for it is skipped until the reset).
    private static func make(_ text: String, id: String, voice: String) async throws -> URL {
        var waited = 0.0
        while true {
            var restUntil: Date?
            let list = entries
            if list.isEmpty { throw Failure.noKey }
            for m in models {
                for e in list where usable(e.id, m) {
                    let rk = e.id + "|" + m
                    if let r = resting[rk], r > Date() { restUntil = min(restUntil ?? r, r); continue }
                    switch await Speech.request(model: m, text: text, voice: voice, key: e.key) {
                    case .audio(let pcm, let rate):
                        let dest = cacheDir().appendingPathComponent(id + ".m4a")
                        let url = try await Task.detached(priority: .userInitiated) { try Speech.save(pcm: pcm, rate: rate, to: dest) }.value
                        trimCache()
                        return url
                    case .daily:
                        markOut(e.id, m, until: nextReset())
                    case .minute(let secs):
                        let r = Date().addingTimeInterval(min(90, max(5, secs)))
                        resting[rk] = r
                        restUntil = min(restUntil ?? r, r)
                    case .unsupported:
                        // the model isn't offered: no key will do
                        for x in list { markOut(x.id, m, until: nextReset()) }
                    case .badKey:
                        badKeys.insert(e.id)
                        if list.allSatisfy({ badKeys.contains($0.id) }) { badKey = true; throw Failure.badKey }
                    case .offline:
                        throw Failure.offline
                    case .failed:
                        continue
                    }
                }
            }
            // every model left is only resting for a minute: wait for the first one (the audio is asked for ahead of
            // time, so a short wait isn't heard), rather than switch to another voice
            guard let r = restUntil, waited < 150 else { throw Failure.exhausted }
            let wait = max(1, r.timeIntervalSinceNow)
            waited += wait
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// The kept audio stays under about 300 MB; the oldest heard goes first.
    private static var trimmed = Date.distantPast
    private static func trimCache() {
        guard Date().timeIntervalSince(trimmed) > 600 else { return }
        trimmed = Date()
        let d = cacheDir()
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys) else { return }
            var rows = files.compactMap { f -> (URL, Int, Date)? in
                guard let v = try? f.resourceValues(forKeys: Set(keys)) else { return nil }
                return (f, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
            }
            var total = rows.reduce(0) { $0 + $1.1 }
            rows.sort { $0.2 < $1.2 }
            for r in rows where total > 300_000_000 {
                try? fm.removeItem(at: r.0)
                total -= r.1
            }
        }
    }

    /// Removes all the kept audio (Settings).
    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir())
    }

    static func cacheSize() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir(), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: diacritics

    /// The same sentences with full diacritics, written by Gemini's text model (kept on the phone like the audio).
    /// A sentence that came back with other words than it had is kept as it was.
    static func diacritize(_ lines: [String]) async throws -> [String] {
        guard hasKey, !badKey else { throw Failure.noKey }
        let id = hash("tashkeel\n" + lines.joined(separator: "\n"))
        let f = cacheDir().appendingPathComponent(id + ".json")
        if let d = try? Data(contentsOf: f), let a = try? JSONDecoder().decode([String].self, from: d), a.count == lines.count { return a }
        let list = entries
        for m in textModels {
            for e in list where usable(e.id, m) {
                let rk = e.id + "|" + m
                if let r = resting[rk], r > Date() { continue }
                switch await Speech.diacritize(model: m, lines: lines, key: e.key) {
                case .lines(let out):
                    let fixed = zip(lines, out).map { o, n in Speech.bare(o) == Speech.bare(n) ? n : o }
                    if let d = try? JSONEncoder().encode(fixed) { try? d.write(to: f) }
                    return fixed
                case .daily: markOut(e.id, m, until: nextReset())
                case .unsupported: for x in list { markOut(x.id, m, until: nextReset()) }
                case .minute(let s): resting[rk] = Date().addingTimeInterval(min(90, max(5, s)))
                case .badKey:
                    badKeys.insert(e.id)
                    if list.allSatisfy({ badKeys.contains($0.id) }) { badKey = true; throw Failure.badKey }
                case .offline: throw Failure.offline
                case .failed: continue
                }
            }
        }
        throw Failure.exhausted
    }

    /// For the settings: a short line read aloud with the chosen voice, to try the key and the voice.
    static func sample() async throws -> URL {
        try await audio("أهلًا بك في جليس. هذا صوتي وأنا أقرأ لك الرواية.")
    }
}

/// Which key to use and when allowances start again: pure, so it needs no network and no database.
enum GeminiKeyRotation {
    /// a key (or model) is out while its out-until time is still ahead
    static func isOut(until: Double, now: Double) -> Bool { now < until }

    /// The ids still usable, in the user's order. `outUntil` is keyed by id (missing means not out).
    static func usable(ids: [String], outUntil: [String: Double], now: Double) -> [String] {
        ids.filter { !isOut(until: outUntil[$0] ?? 0, now: now) }
    }

    /// The key to use now: the first one in the order that isn't out, so key 1 is back as soon as its allowance is.
    static func pick(ids: [String], outUntil: [String: Double], now: Double) -> String? {
        usable(ids: ids, outUntil: outUntil, now: now).first
    }

    /// Daily allowances start again at midnight in California (Pacific time); a minute is added to be safe.
    static func nextReset(after now: Double) -> Double {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let date = Date(timeIntervalSince1970: now)
        let start = c.startOfDay(for: date)
        return (c.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)).timeIntervalSince1970 + 60
    }

    /// A key shown with only its ends ("AIza…x1y2"), never whole.
    static func mask(_ k: String) -> String {
        guard k.count >= 12 else { return "••••••" }
        return String(k.prefix(4)) + "…" + String(k.suffix(4))
    }
}

/// The requests themselves, away from the main thread.
enum Speech {
    enum Answer { case audio(Data, Double), daily, minute(Double), unsupported, badKey, offline, failed(String) }
    enum TextAnswer { case lines([String]), daily, minute(Double), unsupported, badKey, offline, failed(String) }

    private static let base = "https://generativelanguage.googleapis.com/v1beta/"
    static let style = "Calm, clear audiobook narrator. Read the text exactly as written, word for word. For Arabic, use correct Modern Standard Arabic pronunciation with proper case endings (i'rab)."

    static func request(model: String, text: String, voice: String, key: String) async -> Answer {
        // the Interactions API (the current one), then generateContent for models that only answer there
        let body: [String: Any] = [
            "model": model,
            "input": [["type": "user_input", "content": [["type": "text", "text": text,
                                                          "annotations": [["type": "speech_metadata", "style": style]]]]]],
            "response_format": ["type": "audio"],
            "generation_config": ["speech_config": [["voice": voice]]]
        ]
        let a = await post(base + "interactions", body, key: key, timeout: 150)
        switch a {
        case .ok(let json):
            if let d = audioData(json) { return pcm(d) }
            return .failed("no audio")
        case .status(let code, let raw) where code == 400 || code == 404:
            if isBadKey(raw) { return .badKey }
            let b: [String: Any] = [
                "contents": [["parts": [["text": "Read aloud as a calm, clear audiobook narrator, exactly as written:\n\n" + text]]]],
                "generationConfig": ["responseModalities": ["AUDIO"],
                                     "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]]]
            ]
            switch await post(base + "models/\(model):generateContent", b, key: key, timeout: 150) {
            case .ok(let json):
                if let d = audioData(json) { return pcm(d) }
                return .failed("no audio")
            case .status(let c, let r): return classify(c, r)
            case .offline: return .offline
            }
        case .status(let code, let raw): return classify(code, raw)
        case .offline: return .offline
        }
    }

    static func diacritize(model: String, lines: [String], key: String) async -> TextAnswer {
        guard let arr = try? JSONSerialization.data(withJSONObject: lines), let list = String(data: arr, encoding: .utf8) else { return .failed("json") }
        let prompt = """
        شكّل كل نص في المصفوفة التالية تشكيلًا كاملًا صحيحًا بالعربية الفصحى، مع علامات الإعراب في أواخر الكلمات، كما يقرؤه قارئ متقن.
        لا تغيّر أي حرف ولا كلمة ولا ترتيب ولا علامة ترقيم، ولا تضف شيئًا ولا تحذف شيئًا. النصوص غير العربية تبقى كما هي.
        أعد مصفوفة JSON من النصوص المشكولة، بنفس العدد ونفس الترتيب.

        \(list)
        """
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0, "responseMimeType": "application/json",
                                 "responseSchema": ["type": "ARRAY", "items": ["type": "STRING"]]]
        ]
        switch await post(base + "models/\(model):generateContent", body, key: key, timeout: 90) {
        case .ok(let json):
            let parts = (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard let d = text.data(using: .utf8), let out = try? JSONSerialization.jsonObject(with: d) as? [String], out.count == lines.count else {
                return .failed("bad answer")
            }
            return .lines(out)
        case .status(let c, let r):
            switch classify(c, r) {
            case .daily: return .daily
            case .minute(let s): return .minute(s)
            case .unsupported: return .unsupported
            case .badKey: return .badKey
            case .offline: return .offline
            default: return .failed("http \(c)")
            }
        case .offline: return .offline
        }
    }

    // MARK: http

    enum Reply { case ok([String: Any]), status(Int, String), offline }

    static func post(_ url: String, _ body: [String: Any], key: String, timeout: Double) async -> Reply {
        guard let u = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: body) else { return .status(0, "") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        r.httpBody = data
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return .status(code, String(data: d.prefix(4000), encoding: .utf8) ?? "") }
            guard let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return .status(code, "not json") }
            return .ok(json)
        } catch {
            return .offline
        }
    }

    static func isBadKey(_ raw: String) -> Bool {
        raw.contains("API_KEY_INVALID") || raw.contains("API key not valid") || raw.contains("API key expired")
    }

    static func classify(_ code: Int, _ raw: String) -> Answer {
        if isBadKey(raw) { return .badKey }
        switch code {
        case 429:
            if raw.contains("PerDay") || raw.lowercased().contains("per day") || raw.contains("limit: 0") { return .daily }
            var secs = 30.0
            if let m = raw.range(of: "\"retryDelay\":\\s*\"([0-9.]+)s\"", options: .regularExpression) {
                let digits = raw[m].filter { $0.isNumber || $0 == "." }
                secs = Double(digits) ?? 30
            }
            return .minute(secs)
        case 401, 403:
            return raw.contains("PERMISSION_DENIED") && !raw.lowercased().contains("model") ? .badKey : .unsupported
        case 400, 404:
            return .unsupported
        default:
            return .failed("http \(code)")
        }
    }

    // MARK: audio

    /// The audio in an answer, whichever API gave it: the last "audio" content's data, or an inlineData part.
    static func audioData(_ any: Any) -> Data? {
        var found: String?
        func walk(_ x: Any) {
            if let d = x as? [String: Any] {
                if (d["type"] as? String) == "audio", let s = d["data"] as? String { found = s; return }
                for k in ["inlineData", "inline_data"] {
                    if let i = d[k] as? [String: Any], let s = i["data"] as? String { found = s; return }
                }
                for k in d.keys.sorted() { walk(d[k]!) }
            } else if let a = x as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(any)
        return found.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    }

    /// WAV (with its header) or bare 16-bit PCM at 24 kHz, as samples and their rate.
    static func pcm(_ d: Data) -> Answer {
        guard d.count > 44 else { return .failed("empty audio") }
        if d.prefix(4) == Data("RIFF".utf8) {
            var rate = 24_000.0
            var i = 12
            while i + 8 <= d.count {
                let id = String(data: d.subdata(in: i..<i + 4), encoding: .ascii) ?? ""
                let size = Int(d.subdata(in: i + 4..<i + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                if id == "fmt " && i + 16 <= d.count {
                    rate = Double(d.subdata(in: i + 12..<i + 16).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                }
                if id == "data" {
                    let end = min(d.count, i + 8 + size)
                    return .audio(d.subdata(in: i + 8..<end), rate > 0 ? rate : 24_000)
                }
                i += 8 + size + (size % 2)
            }
            return .audio(d.subdata(in: 44..<d.count), rate)
        }
        return .audio(d, 24_000)
    }

    /// Saves the samples as AAC (about a tenth of the size), or as WAV if that fails.
    static func save(pcm: Data, rate rawRate: Double, to dest: URL) throws -> URL {
        // a rate from a damaged header (0, or billions) would trap in the arithmetic below: kept to a sane range
        let rate = min(max(rawRate.isFinite ? rawRate : 24_000, 8_000), 192_000)
        let frames = AVAudioFrameCount(pcm.count / 2)
        if let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames), let ch = buf.int16ChannelData {
            buf.frameLength = frames
            pcm.withUnsafeBytes { raw in
                if let p = raw.baseAddress { memcpy(ch[0], p, Int(frames) * 2) }
            }
            let part = dest.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part.m4a")
            do {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
                do {
                    let file = try AVAudioFile(forWriting: part, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
                    try file.write(from: buf)
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: part, to: dest)
                return dest
            } catch {
                try? FileManager.default.removeItem(at: part)
            }
        }
        // WAV as it came
        let wav = dest.deletingPathExtension().appendingPathExtension("wav")
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append(Data("RIFF".utf8)); u32(UInt32(36 + pcm.count)); h.append(Data("WAVE".utf8))
        h.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        h.append(Data("data".utf8)); u32(UInt32(pcm.count))
        try (h + pcm).write(to: wav, options: .atomic)
        return wav
    }

    /// A sentence's letters alone (no diacritics, tatweel, spaces or punctuation), to check Gemini changed no word.
    /// Hamza on or under the alef and a final ى/ي count as the same letter (Gemini writing the hamza in helps the reading).
    static func bare(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v = u.value
            if (0x064B...0x065F).contains(v) || v == 0x0670 || v == 0x0640 { continue }
            guard CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) else { continue }
            switch v {
            case 0x0622, 0x0623, 0x0625, 0x0671: out.append(Unicode.Scalar(0x0627)!)
            case 0x0649: out.append(Unicode.Scalar(0x064A)!)
            default: out.append(u)
            }
        }
        return String(out)
    }
}
