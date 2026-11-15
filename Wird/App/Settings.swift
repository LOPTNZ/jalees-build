import SwiftUI
import UIKit
import UniformTypeIdentifiers

// الإعدادات (inventory-3, section 1): a short list of topics, each a page (SettingsPages.swift). The data tools behind
// it (backup, restore, start from zero, the demo again, section 2.1–2.3) and the daily reminder are below.

struct SettingsView: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    /// the data page, pushed by the debug hook; the other rows are plain links
    @State private var dataOpen = false
    @State private var openReset = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Text("الإعدادات").font(JFont.display(28, .bold)).foregroundStyle(Color(L.ink))
                    HeaderSessionChip()
                    Spacer(minLength: 0)
                }
                .id("top")

                group {
                    row("paintbrush", "المظهر", themeName) { SettingsLookPage() }
                    row("globe", "اللغة · Language", LangState.shared.english ? "English" : "العربية") { SettingsLanguagePage() }
                }

                group {
                    row("books.vertical", "المكتبة", viewName) { SettingsLibraryPage() }
                    row("timer", "الجلسة والتذكير", remind.bool("on") ? "التذكير مفعّل" : "التذكير مطفأ") { SettingsSessionPage() }
                    row("headphones", "الروايات والقراءة الصوتية", nil) { SettingsNovelsPage() }
                }

                group {
                    row("lock", "الخصوصية", AppLock.shared.enabled ? "القفل مفعّل" : "القفل مطفأ") { SettingsPrivacyPage() }
                    row("server.rack", "السيرفر", nil) { SettingsServerPage() }
                    dataRow
                    row("slider.horizontal.3", "متقدمة", lib.state.settings.raw.bool("advanced") ? "مفعّلة" : nil) { SettingsAdvancedPage() }
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
            .readableColumn()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tabRetap)) { n in
            if (n.object as? String) == "settings" { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("top", anchor: .top) } }
        }
        }
        .statusBarBackdrop(Color(L.bg))
        .background(Color(L.bg).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: .settingsDebug)) { n in
            // the confirmation lives on the data page: open it first, it takes the request when it appears
            if (n.object as? String) == "reset" { openReset = true; dataOpen = true }
        }
    }

    static var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "" }

    // MARK: pieces

    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0) { c() }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(L.surface)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
    }

    private func row<D: View>(_ icon: String, _ title: String, _ sub: String?, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink { dest() } label: { rowLabel(icon, title, sub) }
            .buttonStyle(.plain)
    }

    /// the data page is a link we can also switch on from outside
    private var dataRow: some View {
        NavigationLink(isActive: $dataOpen) { SettingsDataPage(openReset: $openReset) } label: { rowLabel("externaldrive", "البيانات", nil) }
            .buttonStyle(.plain)
    }

    private func rowLabel(_ icon: String, _ title: String, _ sub: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(L.primary))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(L.accentSoft)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(JFont.body(16)).foregroundStyle(Color(L.ink))
                if let s = sub { Text(s).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2)) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(L.ink2))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    // MARK: one-line summaries

    private var themeName: String {
        switch lib.state.settings.raw.str("theme", "system") {
        case "light": return "فاتح"
        case "dark": return "داكن"
        default: return "حسب الجهاز"
        }
    }

    private var viewName: String {
        switch lib.state.settings.raw.str("view", "carousel") {
        case "shelf": return "رفوف"
        case "grid": return "شبكة"
        default: return "دائري"
        }
    }

    private var remind: JSONObject { lib.state.settings.raw.obj("remind") }
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
struct ResetSheet: View {
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
