import SwiftUI
import UIKit
import UniformTypeIdentifiers

// الإعدادات (inventory-3, section 1) and the data tools behind it: backup, restore, start from zero, the demo again
// (section 2.1–2.3), and the daily reminder.

struct SettingsView: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var shelfStyle = false
    @State private var askReset = false
    @State private var exporting = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 12) {
                    Text("الإعدادات").font(JFont.display(28, .bold)).foregroundStyle(Color(L.ink))
                    HeaderSessionChip()
                    Spacer(minLength: 0)
                }
                .id("top")

                section("المظهر") {
                    field("الوضع") { JSeg(options: [("system", "حسب الجهاز"), ("light", "فاتح"), ("dark", "داكن")], value: str("theme", "system")) }
                    field("اللون الأساسي") { swatches }
                    field("حجم الخط") { JSeg(options: [("s", "صغير"), ("m", "متوسط"), ("l", "كبير")], value: str("fs", "m")) }
                }

                section("المكتبة") {
                    field("العرض الافتراضي") { JSeg(options: [("carousel", "دائري"), ("shelf", "رفوف"), ("grid", "شبكة")], value: str("view", "carousel")) }
                    field("شكل الدوران") { JSeg(options: [("stack", "مكدّس"), ("flow", "أغلفة مائلة")], value: str("carStyle", "stack")) }
                    field("تعديل أبعاد الكتاب") {
                        JSeg(options: [("handles", "سحب المقابض"), ("sliders", "أشرطة تمرير")], value: str("dimMode", "handles"))
                        note("القياسات بالسنتيمتر متاحة في الحالتين.")
                    }
                    Button { shelfStyle = true } label: { Label("شكل الرف والإضاءة", systemImage: "paintpalette") }
                        .buttonStyle(JButtonStyle(look: L, small: true))
                }

                section("الجلسة") {
                    field("الصوت الافتراضي") { JSeg(options: SessionModel.sounds, value: str("sound", "rain")) }
                    VStack(spacing: 0) {
                        JSwitchRow(title: "غلاف الكتاب خلفية للجلسة", on: flag("sessCover", false))
                        JSwitchRow(title: "إبقاء الشاشة مضاءة أثناء الجلسة", on: flag("wake", true))
                    }
                }

                section("التذكير اليومي") {
                    JSwitchRow(title: "ذكّرني بالقراءة", sub: "إشعار في الوقت اللي تختاره، وما يجيك إذا حققت هدفك ذاك اليوم", on: remindOn)
                    if remind.bool("on") {
                        HStack {
                            JLabel(text: "الوقت")
                            Spacer()
                            DatePicker("", selection: remindTime, displayedComponents: .hourAndMinute).labelsHidden()
                                .environment(\.locale, Locale(identifier: "ar@numbers=latn"))
                        }
                    }
                }

                section("البحث عن الكتب") {
                    field("مفتاح Google Books (اختياري)") {
                        TextField("AIza…", text: str("gbKey", ""))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                            .multilineTextAlignment(.leading)
                            .environment(\.layoutDirection, .leftToRight)
                            .font(JFont.body(16)).foregroundStyle(Color(L.ink))
                            .padding(.horizontal, 14).frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                    }
                    note("البحث يشتغل بدونه من Goodreads وأبجد وOpen Library. Google Books بدون مفتاح يرفض أغلب الطلبات لأن حدّه المجاني المشترك يخلص بسرعة. لو تبي نتائجه، سوّ مفتاحًا مجانيًا لـ «Books API» من Google Cloud والصقه هنا.")
                }

                section("الكلمات والشخصيات") {
                    field("طريقة المراجعة") {
                        JSeg(options: [("simple", "عادية"), ("srs", "تكرار متباعد")], value: str("review", "srs"))
                        note(lib.state.settings.raw.str("review", "srs") == "srs"
                             ? "كل كلمة ترجع لك بعد مدة تطول كلما عرفتها، وتقصر كلما صعبت عليك."
                             : "تمر على كل الكلمات بترتيب عشوائي وتعلّم اللي عرفتها.")
                    }
                    JSwitchRow(title: "إخفاء الحرق في الشخصيات", sub: "موت الشخصية يظهر مغطّى حتى تضغط عليه", on: flag("spoilers", true))
                }

                section("البيانات") {
                    note("بياناتك محفوظة في جوالك داخل التطبيق. صدّر نسخة احتياطية لتطبيق «الملفات» أول بأول، عشان لو حذفت التطبيق ترجعها.")
                    HStack(spacing: 10) {
                        Button { exportBackup() } label: {
                            Label(exporting ? "جاري التجهيز…" : "تصدير نسخة احتياطية", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(JButtonStyle(look: L)).disabled(exporting)
                        Button("استعادة نسخة") { Flows.importBackup() }.buttonStyle(JButtonStyle(look: L))
                    }
                    if lib.state.demo {
                        Text("الكتب الحالية تجريبية. إذا جهزت تبدأ بكتبك، امسحها بزر «ابدأ من الصفر».")
                            .font(JFont.body(15 * 0.93)).foregroundStyle(Color(L.ink))
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.accentSoft)))
                    } else if Library.edition != "clean" {
                        Button("إرجاع البيانات التجريبية") { Backup.reseed() }.buttonStyle(JButtonStyle(look: L, small: true))
                    }
                    Button { askReset = true } label: {
                        Label("ابدأ من الصفر", systemImage: "trash")
                            .font(JFont.body(15, .medium)).foregroundStyle(Color(L.danger))
                            .padding(.horizontal, 16).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.danger).opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.danger).opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 4) {
                    Text("جَليس " + Self.version).font(JFont.body(15 * 0.86)).foregroundStyle(Color(L.ink2))
                    Text("أعزُّ مكانٍ في الدُّنى سرجُ سابحٍ ... وخيرُ جليسٍ في الزمانِ كتابُ")
                        .font(JFont.quote(15 * 0.9)).foregroundStyle(Color(L.ink2)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            .padding(.horizontal, 16).padding(.bottom, 110)
        }
        .scrollDismissesKeyboard(.interactively)
        .onReceive(NotificationCenter.default.publisher(for: .tabRetap)) { n in
            if (n.object as? String) == "settings" { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("top", anchor: .top) } }
        }
        }
        .statusBarBackdrop(Color(L.bg))
        .background(Color(L.bg).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $shelfStyle) { ShelfStyleSheet().environment(\.look, L).environment(\.layoutDirection, .rightToLeft) }
        .sheet(isPresented: $askReset) { ResetSheet().environment(\.look, L).environment(\.layoutDirection, .rightToLeft).presentationDetents([.medium]) }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDebug)) { n in
            if (n.object as? String) == "reset" { askReset = true }
        }
    }

    static var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "" }

    // MARK: pieces

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(JFont.display(15 * 1.2)).foregroundStyle(Color(L.ink))
            c()
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { JLabel(text: label); c() }
    }

    private func note(_ t: String) -> some View {
        Text(t).font(JFont.body(15 * 0.86)).foregroundStyle(Color(L.ink2)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }

    private var swatches: some View {
        HStack(spacing: 10) {
            ForEach(Theme.accentNames, id: \.0) { k, name in
                let on = lib.state.settings.accent == k
                Button { lib.change { $0.settings.accent = k }; Haptics.play("sel") } label: {
                    Circle().fill(Color(hex: Theme.accents[k]!.light[0])).frame(width: 36, height: 36)
                        .overlay(Circle().strokeBorder(Color(L.surface), lineWidth: on ? 3 : 0).padding(2))
                        .overlay(Circle().strokeBorder(on ? Color(L.ink) : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    // MARK: bindings into S.set

    private func str(_ k: String, _ d: String) -> Binding<String> {
        Binding(get: { lib.state.settings.raw.str(k, d) }, set: { v in lib.change { $0.settings.raw.set(k, v) } })
    }

    private func flag(_ k: String, _ d: Bool) -> Binding<Bool> {
        Binding(get: { lib.state.settings.raw.bool(k, d) }, set: { v in
            lib.change { $0.settings.raw.set(k, v) }
            if k == "wake" { SessionModel.shared.refreshAwake() }
        })
    }

    private var remind: JSONObject { lib.state.settings.raw.obj("remind") }

    private var remindOn: Binding<Bool> {
        Binding(get: { remind.bool("on") }, set: { v in
            lib.change { st in
                var r = st.settings.raw.obj("remind")
                r.set("on", v)
                if r["time"] == nil { r.set("time", "21:00") }
                st.settings.raw["remind"] = .object(r)
            }
            Reminder.sync(ask: v)
        })
    }

    private var remindTime: Binding<Date> {
        Binding(get: {
            let p = remind.str("time", "21:00").split(separator: ":").compactMap { Int($0) }
            return Calendar.greg.date(bySettingHour: p.first ?? 21, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.greg.dateComponents([.hour, .minute], from: d)
            lib.change { st in
                var r = st.settings.raw.obj("remind")
                r.set("time", String(format: "%02d:%02d", c.hour ?? 21, c.minute ?? 0))
                st.settings.raw["remind"] = .object(r)
            }
            Reminder.sync()
        })
    }

    // MARK: backup

    private func exportBackup() {
        exporting = true
        Task {
            let r = await Backup.export()
            exporting = false
            guard let file = r else { ToastCenter.shared.show("تعذّر حفظ الملف"); return }
            Share.data(file.0, name: file.1) { done in ToastCenter.shared.show(done ? "تم حفظ النسخة" : "تم الإلغاء") }
        }
    }
}

extension Notification.Name {
    /// debug routes: open the settings' sheets
    static let settingsDebug = Notification.Name("jalees.settingsDebug")
}

struct BackupFile: Identifiable {
    let id = UUID()
    let data: JSONObject
}

/// The file picker for a backup, opened from the settings, the library's + menu or the welcome page.
@MainActor
final class BackupImport: ObservableObject {
    static let shared = BackupImport()
    @Published var picking = false
}

/// استعادة نسخة: it replaces everything.
struct RestoreSheet: View {
    let file: BackupFile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    var body: some View {
        let n = file.data.obj("state").arr("books").count
        JSheet(title: "استعادة نسخة") {
            Text("النسخة فيها \(Words.cnt(Double(n), Words.books)) من \(Words.date(file.data.num("exported"), year: true)).")
                .font(JFont.body(15)).foregroundStyle(Color(L.ink))
            Text("بتحل محل كل بياناتك الحالية في التطبيق. إذا تبي تحتفظ فيها، صدّر نسخة أول.")
                .font(JFont.body(15 * 0.93)).foregroundStyle(Color(L.ink))
                .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.accentSoft)))
            Button { dismiss(); Backup.restore(file.data) } label: { Text("استعادة").frame(maxWidth: .infinity) }
                .buttonStyle(JButtonStyle(look: L, primary: true))
        }
    }
}

/// ابدأ من الصفر: books, sessions, notes and pictures go; settings and achievements stay.
private struct ResetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    var body: some View {
        JSheet(title: "ابدأ من الصفر") {
            Text("تنحذف كل الكتب والجلسات والملاحظات والصور. الإعدادات والإنجازات تبقى.").font(JFont.body(15)).foregroundStyle(Color(L.ink))
            Text("إذا تبي تحتفظ فيها، صدّر نسخة احتياطية أول.").font(JFont.body(15 * 0.86)).foregroundStyle(Color(L.ink2))
            Button { dismiss(); Backup.reset() } label: {
                Text("احذف كل شيء").font(JFont.body(16, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.danger)))
            }
            .buttonStyle(.plain)
            Button { dismiss() } label: { Text("تراجع").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
        }
    }
}

// MARK: - backup, restore, reset, reseed

@MainActor
enum Backup {
    /// The backup file, in the same shape as the web and Android apps: {app, v, exported, state, images, novels}.
    static func export() async -> (Data, String)? {
        let st = Library.shared.state
        var ids: [String] = []
        for b in st.books {
            for i in [b.cover, b.raw.optStr("spine")].compactMap({ $0 }) where !i.isEmpty { ids.append(i) }
            for c in b.chars { if let p = c.raw.optStr("photo"), !p.isEmpty { ids.append(p) } }
            for q in b.items(.quote) { if let p = q.raw.optStr("img"), !p.isEmpty { ids.append(p) } }
        }
        let stateObj = st.json
        let novels = Novels.shared.exportAll()
        return await Task.detached(priority: .userInitiated) { () -> (Data, String)? in
            var images: [String: Any] = [:]
            for id in Set(ids) {
                guard let d = Store.shared.imageData(id) else { continue }
                images[id] = "data:" + Store.mime(of: d) + ";base64," + d.base64EncodedString()
            }
            var out: [String: Any] = ["app": "jalees", "v": 3, "exported": Millis.now, "state": JSONValue.object(stateObj).any, "images": images]
            if !novels.isEmpty { out["novels"] = novels }
            guard let data = try? JSONSerialization.data(withJSONObject: out) else { return nil }
            return (data, "jalees-backup-\(Words.dkey(Millis.now)).json")
        }.value
    }

    /// A picked file: a Jalees (or Wird) backup goes to the confirmation; anything else is refused.
    static func open(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url), let o = JSONValue.parse(d)?.object,
              ["wird", "jalees"].contains(o.str("app")), o.obj("state")["books"]?.array != nil else {
            ToastCenter.shared.show("الملف ما هو نسخة احتياطية من وِرد")
            return
        }
        Present.shared.open(.restore(BackupFile(data: o)))
    }

    /// Replaces everything with the backup (pictures not in it stay on disk, as before).
    static func restore(_ data: JSONObject) {
        if let nv = data["novels"]?.array, !nv.isEmpty {
            Novels.shared.importAll(nv.compactMap { $0.any as? [String: Any] })
        }
        for (id, v) in data.obj("images") {
            if case .string(let s) = v, s.hasPrefix("data:") { Store.shared.putImage(id, dataURL: s) }
        }
        Library.shared.forgetImages()
        var s = Library.upgrade(data.obj("state"))
        s["timer"] = .null
        s["imgMig"] = .bool(true)
        SessionModel.shared.clear()
        Library.shared.change { $0 = AppState(s) }
        home()
        ToastCenter.shared.show("تمت الاستعادة")
        Reminder.sync()
        WidgetFeed.update()
    }

    static func reset() {
        let lib = Library.shared
        for b in lib.state.books {
            lib.deleteImage(b.cover)
            lib.deleteImage(b.raw.optStr("spine"))
            for c in b.chars { lib.deleteImage(c.raw.optStr("photo")) }
            for q in b.items(.quote) { lib.deleteImage(q.raw.optStr("img")) }
        }
        let old = lib.state
        SessionModel.shared.clear()
        lib.change { st in
            var o: JSONObject = ["v": .number(3), "demo": .bool(false), "books": .array([]), "sessions": .array([]),
                                 "shelf": .null, "timer": .null, "lastBook": .null, "achInit": .bool(true), "imgMig": .bool(true)]
            o["goals"] = old.rest["goals"] ?? .object(["daily": .number(30), "year": .number(12)])
            o["set"] = .object(old.settings.raw)
            o["ach"] = .object(old.ach)
            st = AppState(Library.upgrade(o))
        }
        home()
        ToastCenter.shared.show("بدأت من الصفر")
        Reminder.sync()
        WidgetFeed.update()
    }

    static func reseed() {
        let lib = Library.shared
        let keep = lib.state.settings.raw, ach = lib.state.ach
        var s = Library.upgrade(Library.seed())
        s["set"] = .object(keep)
        s["ach"] = .object(ach)
        s["achInit"] = .bool(true)
        lib.change { $0 = AppState(s) }
        ShelfStore.ensure(width: UIScreen.main.bounds.width)
        home()
        WidgetFeed.update()
    }

    /// Back to the library's first page, every tab's pages closed.
    private static func home() {
        Present.shared.modal = nil
        Router.shared.paths = [:]
        Router.shared.select(.library)
    }
}

// MARK: - the daily reminder

@MainActor
enum Reminder {
    /// One a day for three weeks, none today once today's goal is met. `ask`: the owner just turned it on.
    static func sync(ask: Bool = false) {
        let st = Library.shared.state
        let r = st.settings.raw.obj("remind")
        let b = st.lastBookId().flatMap { st.book($0) }
        let body = (b.map { $0.status == .reading ? "«\($0.title)» بانتظارك · " : "" } ?? "") + "هدفك \(st.goals.daily) دقيقة"
        Notify.remind(["on": r.bool("on"), "time": r.str("time", "21:00"), "skipToday": st.todayMin >= Double(st.goals.daily),
                       "title": "حان وقت القراءة", "body": body]) { granted in
            guard ask, !granted else { return }
            DispatchQueue.main.async { ToastCenter.shared.show("اسمح لجليس بالإشعارات من إعدادات الجوال") }
        }
    }
}

// MARK: - share sheet for files

extension Share {
    /// Writes the data to a temporary file and opens the share sheet (Save to Files, AirDrop…); done(true) when shared.
    @MainActor static func data(_ data: Data, name: String, done: @escaping @MainActor (Bool) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        guard (try? data.write(to: url, options: .atomic)) != nil, let h = NovelBridge.host else { done(false); return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in DispatchQueue.main.async { done(completed) } }
        vc.popoverPresentationController?.sourceView = h.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: h.view.bounds.midX, y: h.view.bounds.maxY - 80, width: 1, height: 1)
        NovelBridge.top(h).present(vc, animated: true)
    }
}
