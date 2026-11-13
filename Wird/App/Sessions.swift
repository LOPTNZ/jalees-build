import SwiftUI
import UIKit
import AudioToolbox

// Reading sessions (inventory-2, sections 2.9, 3.9 and 6.1–6.8): a clock that counts from timestamps (so it keeps
// counting in the background and after a relaunch), pause, a countdown, background sounds, the lock screen.

@MainActor
final class SessionModel: ObservableObject {
    static let shared = SessionModel()

    @Published var showScreen = false
    @Published var ending = false
    @Published private(set) var now = Date()
    @Published var volume: Double = 0.6
    @Published var soundOn = false
    private var tick: Timer?

    static let sounds: [(String, String)] = [("rain", "مطر"), ("cafe", "مقهى"), ("fire", "موقد"), ("waves", "أمواج")]

    var timer: JSONObject? { Library.shared.state.timer }
    var book: Book? { timer.flatMap { Library.shared.state.book($0.str("bookId")) } }
    var running: Bool { timer?.optNum("startedAt") != nil }

    /// milliseconds read so far
    var elapsed: Double {
        guard let t = timer else { return 0 }
        let acc = t.num("acc")
        if let s = t.optNum("startedAt") { return acc + (Millis.ms(now) - s) }
        return acc
    }

    private init() {
        if timer != nil { startTicking(); syncLock() }
    }

    private func setTimer(_ f: (inout JSONObject) -> Void) {
        Library.shared.change { st in
            guard var t = st.timer else { return }
            f(&t)
            st.timer = t
        }
    }

    // MARK: start, pause, resume

    func start(_ id: String) {
        guard let b = Library.shared.state.book(id) else { return }
        if let t = timer {
            if t.str("bookId") != id {
                ToastCenter.shared.show("عندك جلسة جارية، أنهِها أولًا")
            }
            showScreen = true
            return
        }
        if b.status == .done { Present.shared.open(.reread(id)); return }
        let now = Millis.now
        Library.shared.change { st in
            st.timer = ["bookId": .string(id), "vi": .number(Double(b.vi)), "pos": .number(b.pos), "startedAt": .number(now), "acc": .number(0),
                        "sessionStart": .number(now), "cd": .null, "min": .bool(false)]
            if let i = st.index(of: id) {
                if st.books[i].status == .want || st.books[i].status == .dnf { st.books[i].status = .reading }
                if st.books[i].start == nil { st.books[i].start = now }
                st.books[i].opened = now
            }
            st.lastBook = id
        }
        awake(true)
        startTicking()
        syncLock()
        showScreen = true
        Haptics.play("soft")
    }

    func pause() {
        let e = elapsed
        setTimer { $0.set("acc", e); $0["startedAt"] = .null }
        awake(false)
        syncLock()
        countdownNotify()
    }

    func resume() {
        setTimer { $0.set("startedAt", Millis.now) }
        awake(true)
        syncLock()
        countdownNotify()
    }

    func minimize() {
        setTimer { $0.set("min", true) }
        showScreen = false
    }

    func open() {
        setTimer { $0.set("min", false) }
        showScreen = true
    }

    // MARK: countdown

    var countdownLeft: Double? {
        guard let cd = timer?["cd"]?.object else { return nil }
        return cd.num("at") + cd.num("min") * 60_000 - elapsed
    }

    func setCountdown(_ minutes: Int) {
        let e = elapsed
        setTimer { t in
            t["cd"] = .object(["min": .number(Double(minutes)), "at": .number(e), "fired": .bool(false)])
            if t.optNum("startedAt") == nil { t.set("startedAt", Millis.now) }
        }
        awake(true)
        countdownNotify()
        syncLock()
    }

    func countdownOff() {
        setTimer { $0["cd"] = .null }
        Notify.cancel("cd")
    }

    private func countdownNotify() {
        Notify.cancel("cd")
        guard running, let left = countdownLeft, left > 1000, timer?["cd"]?.object?.bool("fired") != true else { return }
        let m = Int(timer?["cd"]?.object?.num("min") ?? 0)
        Notify.schedule(["id": "cd", "in": left / 1000, "title": "انتهى العد التنازلي", "body": "\(m) دقيقة من القراءة"])
    }

    // MARK: the clock

    private func startTicking() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    private func step() {
        guard timer != nil else { tick?.invalidate(); tick = nil; return }
        now = Date()
        if let left = countdownLeft, left <= 0, timer?["cd"]?.object?.bool("fired") == false {
            let m = Int(timer?["cd"]?.object?.num("min") ?? 0)
            setTimer { t in var cd = t.obj("cd"); cd.set("fired", true); t["cd"] = .object(cd) }
            Haptics.play("success")
            AudioServicesChime.play()
            ToastCenter.shared.show("انتهى العد التنازلي (\(m) دقيقة)")
        }
    }

    /// The keep-awake setting changed: apply it to the running session.
    func refreshAwake() { awake(timer != nil) }

    /// Everything about a session stops without saving (restoring a backup, starting from zero).
    func clear() { stopAll() }

    private func awake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on && Library.shared.state.settings.raw.bool("wake", true)
    }

    /// The session on the lock screen and in the Dynamic Island.
    func syncLock() {
        guard let t = timer, let b = book else { LiveSession.end(); return }
        let startedAt = t.optNum("startedAt")
        LiveSession.handle(["op": "set", "title": b.title, "author": b.author, "pos": b.posLabel, "audio": b.isAudio,
                            "start": (startedAt ?? Millis.now) - t.num("acc"), "elapsed": Int(elapsed / 1000), "paused": startedAt == nil])
    }

    // MARK: sounds

    func toggleSound() {
        soundOn.toggle()
        if soundOn { Ambient.shared.set(["kind": Library.shared.state.settings.raw.str("sound", "rain"), "vol": volume]) } else { Ambient.shared.stop() }
    }

    func nextSound(_ step: Int) {
        let cur = Library.shared.state.settings.raw.str("sound", "rain")
        let i = Self.sounds.firstIndex { $0.0 == cur } ?? 0
        let n = Self.sounds[(i + step + Self.sounds.count) % Self.sounds.count].0
        LibraryFilters.set("sound", .string(n))
        if soundOn { Ambient.shared.set(["kind": n, "vol": volume]) }
    }

    func setVolume(_ v: Double) { volume = v; Ambient.shared.setVolume(Float(v)) }

    // MARK: ending

    /// The suggested place at the end: where you were (audio: where the elapsed time at your speed takes you).
    func suggestedEnd() -> (vi: Int, pos: Double) {
        guard let t = timer, let b = book else { return (0, 0) }
        let vi = t.int("vi")
        var pos = t.num("pos")
        if b.unit.time {
            pos = (t.num("pos") + elapsed / 60_000 * (b.speed > 0 ? b.speed : 1)).rounded()
            if b.volumes.indices.contains(vi), let tot = b.volumes[vi].total { pos = min(pos, tot) }
        } else {
            pos = b.pos
            return (b.vi, pos)
        }
        return (vi, pos)
    }

    func beginEnd() {
        if running { pause() }
        ending = true
    }

    /// Units between two places, across volumes (unitsBetween).
    static func unitsBetween(_ b: Book, _ v0: Int, _ p0: Double, _ v1: Int, _ p1: Double) -> Double {
        if v1 < v0 || (v1 == v0 && p1 <= p0) { return 0 }
        if v1 == v0 { return p1 - p0 }
        let vols = b.volumes
        var s = (vols.indices.contains(v0) ? (vols[v0].total ?? p0) : p0) - p0
        if v0 + 1 < v1 { for i in (v0 + 1)..<v1 where vols.indices.contains(i) { s += vols[i].total ?? 0 } }
        return s + p1
    }

    func save(vi: Int, pos: Double) -> String? {
        guard let t = timer, let b = book else { return nil }
        let v = min(max(0, vi), max(0, b.volumes.count - 1))
        let p = max(0, pos.rounded())
        if let tot = b.volumes[v].total, p > tot {
            return b.unit.time ? "الوقت أكبر من مدة الكتاب (\(Words.hm(tot)))." : "الرقم أكبر من عدد \(b.unit.plu) (\(Int(tot)))."
        }
        let ms = elapsed
        let start = t.optNum("sessionStart") ?? (Millis.now - ms)
        let s = Session(["id": .string(uid()), "bookId": .string(b.id), "start": .number(start), "minutes": .number((ms / 6000).rounded() / 10),
                         "units": .number(Self.unitsBetween(b, t.int("vi"), t.num("pos"), v, p)), "unit": .string(b.unit.rawValue),
                         "vi": .number(Double(v)), "from": .number(t.num("pos")), "to": .number(p), "read": .number(Double(b.readNo))])
        Notify.cancel("cd")
        let prevVi = b.vi, prevStatus = b.status
        Library.shared.change { st in
            st.sessions.append(s)
            if let i = st.index(of: b.id) { st.books[i].vi = v; st.books[i].pos = p; st.books[i].opened = Millis.now }
            st.lastBook = b.id
            st.timer = nil
        }
        stopAll()
        ProgressRules.after(b.id, prevVi: prevVi, prevStatus: prevStatus)
        Reminder.sync()
        Haptics.play("success")
        if Library.shared.state.book(b.id)?.status != .done { ToastCenter.shared.show("تم حفظ الجلسة") }
        return nil
    }

    func discard() {
        Library.shared.change { $0.timer = nil }
        stopAll()
        ToastCenter.shared.show("ما انحفظت الجلسة")
    }

    private func stopAll() {
        Ambient.shared.stop()
        soundOn = false
        awake(false)
        Notify.cancel("cd")
        LiveSession.end()
        tick?.invalidate(); tick = nil
        ending = false
        showScreen = false
    }
}

/// Two soft tones when a countdown ends.
enum AudioServicesChime {
    static func play() { AudioServicesPlaySystemSound(1113) }
}


/// The session screen: the book, the clock, quick notes, sounds, a countdown, pause and end.
struct SessionScreen: View {
    @ObservedObject private var s = SessionModel.shared
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    /// a quick note during the session opens over the session itself
    @State private var note: ItemRef?

    var body: some View {
        ZStack {
            Color(L.stage).ignoresSafeArea()
            if let b = s.book {
                if lib.state.settings.raw.bool("sessCover"), let img = lib.image(b.cover) {
                    Image(uiImage: img).resizable().scaledToFill().blur(radius: 30).overlay(Color.black.opacity(0.62)).ignoresSafeArea()
                }
                content(b)
            }
        }
        .foregroundStyle(Color(L.stageInk))
        .sheet(isPresented: $s.ending) { EndSessionSheet().environment(\.look, L).environment(\.layoutDirection, .rightToLeft) }
        .sheet(item: $note) { r in ItemForm(ref: r).environment(\.look, L).environment(\.layoutDirection, .rightToLeft) }
    }

    private func content(_ b: Book) -> some View {
        VStack(spacing: 16) {
            HStack {
                Button { s.minimize() } label: { Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("تصغير")
                Spacer()
                Text(b.verbs.sess).font(JFont.display(18, .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            VStack(spacing: 6) {
                Text(b.verbs.now).font(JFont.body(13)).opacity(0.75)
                Text(b.posLabel).font(JFont.body(13.5)).opacity(0.8)
                Text(b.title).font(JFont.display(24, .bold)).multilineTextAlignment(.center).lineLimit(2)
                if !b.author.isEmpty { Text("بقلم " + b.author).font(JFont.body(14)).opacity(0.8) }
            }
            .frame(maxWidth: .infinity).padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.06)))
            VStack(spacing: 4) {
                Text(clock(s.elapsed)).font(.system(size: 64, weight: .medium, design: .rounded)).monospacedDigit().environment(\.layoutDirection, .leftToRight)
                Text(s.running ? "جارية" : "متوقفة مؤقتًا").font(JFont.body(14, .medium)).foregroundStyle(s.running ? Color(L.accent) : Color(L.stageInk).opacity(0.7))
                if let left = s.countdownLeft {
                    Text(left > 0 ? "متبقي " + mmss(left) : "انتهى العد التنازلي").font(JFont.body(13)).opacity(0.8)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                quick("quote.opening", "اقتباس", "quote", b)
                quick("lightbulb", "فكرة", "thought", b)
                quick("person", "شخصية", "char", b)
                quick("character.book.closed", "كلمة", "word", b)
            }
            tools
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button { s.running ? s.pause() : s.resume() } label: {
                    Label(s.running ? "إيقاف مؤقت" : "استئناف", systemImage: s.running ? "pause.fill" : "play.fill").font(JFont.body(16, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 56).background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                Button { s.beginEnd() } label: {
                    Label("إنهاء", systemImage: "stop.fill").font(JFont.body(16, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 56).background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: "#d4493c")))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var tools: some View {
        VStack(spacing: 12) {
            HStack {
                Text("أصوات خلفية").font(JFont.body(13)).opacity(0.8)
                Spacer()
                Text(SessionModel.sounds.first { $0.0 == lib.state.settings.raw.str("sound", "rain") }?.1 ?? "").font(JFont.body(13))
            }
            HStack(spacing: 14) {
                round("backward.fill", "السابق") { s.nextSound(-1) }
                round(s.soundOn ? "pause.fill" : "play.fill", s.soundOn ? "إيقاف الصوت" : "تشغيل الصوت") { s.toggleSound() }
                round("forward.fill", "التالي") { s.nextSound(1) }
                Slider(value: Binding(get: { s.volume }, set: { s.setVolume($0) }), in: 0...1, step: 0.05).tint(Color(L.accent))
            }
            .environment(\.layoutDirection, .leftToRight)
            HStack {
                Text("عدّ تنازلي").font(JFont.body(13)).opacity(0.8)
                Spacer()
                if s.timer?["cd"]?.object != nil { Button("إلغاء") { s.countdownOff() }.font(JFont.body(13, .semibold)).foregroundStyle(Color(L.accent)) }
            }
            HStack(spacing: 8) {
                ForEach([15, 25, 45, 60], id: \.self) { m in
                    let on = Int(s.timer?["cd"]?.object?.num("min") ?? 0) == m
                    Button { s.setCountdown(m) } label: {
                        Text("\(m) د").font(JFont.body(14, on ? .semibold : .regular)).frame(maxWidth: .infinity, minHeight: 34)
                            .background(Capsule().fill(on ? Color(L.accent) : Color.clear))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func round(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 42, height: 42).background(Circle().fill(Color.white.opacity(0.1))) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func quick(_ icon: String, _ title: String, _ kind: String, _ b: Book) -> some View {
        Button { note = ItemRef(book: b.id, kind: kind, item: nil) } label: {
            Label(title, systemImage: icon).font(JFont.body(15, .medium)).frame(maxWidth: .infinity, minHeight: 56)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func clock(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    private func mmss(_ ms: Double) -> String {
        let s = max(0, Int(ms / 1000))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// «إنهاء الجلسة»: where you reached, what that comes to, save or not.
struct EndSessionSheet: View {
    @ObservedObject private var s = SessionModel.shared
    @Environment(\.look) private var L
    @State private var vi = 0
    @State private var pos: Double = 0
    @State private var err = ""
    @State private var loaded = false

    var body: some View {
        if let b = s.book, let t = s.timer {
            JSheet(title: "إنهاء الجلسة", subtitle: b.title + " · " + Words.fmtMin(s.elapsed / 60_000)) {
                if b.series {
                    Picker("المجلد", selection: $vi) {
                        ForEach(b.volumes.indices, id: \.self) { i in Text("المجلد \(i + 1)" + (b.volumes[i].title.isEmpty ? "" : " · " + b.volumes[i].title)).tag(i) }
                    }
                    .pickerStyle(.menu)
                }
                PositionField(unitTime: b.unit.time, value: $pos, total: b.volumes.indices.contains(vi) ? b.volumes[vi].total : nil)
                if b.unit.time {
                    Text("اقترحت لك الموضع من مدة الجلسة وسرعة الاستماع (×\(b.speed == b.speed.rounded() ? String(Int(b.speed)) : String(b.speed))). عدّله إذا يختلف.")
                        .font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
                }
                Text(preview(b, t)).font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
                if !err.isEmpty { Text(err).font(JFont.body(14)).foregroundStyle(Color(L.danger)) }
                Button { if let e = s.save(vi: vi, pos: pos) { err = e } } label: { Text("حفظ الجلسة").frame(maxWidth: .infinity) }
                    .buttonStyle(JButtonStyle(look: L, primary: true))
                Button { s.discard() } label: { Text("لا تحفظ الجلسة").frame(maxWidth: .infinity) }.buttonStyle(.plain).foregroundStyle(Color(L.ink2))
            }
            .presentationDetents([.medium, .large])
            .onAppear { if !loaded { loaded = true; let x = s.suggestedEnd(); vi = x.vi; pos = x.pos } }
        }
    }

    private func preview(_ b: Book, _ t: JSONObject) -> String {
        let n = SessionModel.unitsBetween(b, t.int("vi"), t.num("pos"), vi, pos)
        let ms = s.elapsed
        if b.unit.time { return "استمعت إلى " + Words.fmtMin(n) + " من الكتاب" }
        let sp = ms >= 60_000 && n > 0 ? n / (ms / 3_600_000) : nil
        return (b.isAudio ? "استمعت إلى " : "قرأت ") + Words.cnt(n, b.unit.forms) + (sp.map { " · " + Words.n0($0) + " " + b.unit.pl + " في الساعة" } ?? "")
    }
}

/// The running session as a small chip above the tab bar while it is minimised.
struct SessionChip: View {
    @ObservedObject private var s = SessionModel.shared
    @Environment(\.look) private var L

    var body: some View {
        if s.timer != nil && !s.showScreen {
            Button { s.open() } label: {
                HStack(spacing: 8) {
                    Circle().fill(s.running ? Color(L.accent) : Color(L.ink2)).frame(width: 8, height: 8)
                    Text(s.book?.title ?? "").font(JFont.body(13.5, .medium)).lineLimit(1)
                    Text(clock).font(JFont.body(13.5, .semibold)).monospacedDigit().environment(\.layoutDirection, .leftToRight)
                }
                .foregroundStyle(Color(L.ink))
                .padding(.horizontal, 14).frame(height: 38)
                .background(Capsule().fill(Color(L.surface)))
                .overlay(Capsule().strokeBorder(Color(L.line), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("الجلسة الجارية")
        }
    }

    private var clock: String {
        let t = Int(s.elapsed / 1000)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}
