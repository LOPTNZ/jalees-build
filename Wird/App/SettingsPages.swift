import SwiftUI
import UIKit

// The pages the settings root opens. Each holds the controls of one topic, moved as they were.

// MARK: - shared pieces

/// Settings bindings into the library's raw settings (same behaviour the single page had).
@MainActor
enum SettingsBind {
    static func str(_ k: String, _ d: String) -> Binding<String> {
        Binding(get: { Library.shared.state.settings.raw.str(k, d) }, set: { v in Library.shared.change { $0.settings.raw.set(k, v) } })
    }

    static func flag(_ k: String, _ d: Bool) -> Binding<Bool> {
        Binding(get: { Library.shared.state.settings.raw.bool(k, d) }, set: { v in
            Library.shared.change { $0.settings.raw.set(k, v) }
            if k == "wake" { SessionModel.shared.refreshAwake() }
        })
    }
}

/// A page's frame: scrolling column at a reading width, the app's background, the inline title.
struct SettingsPage<C: View>: View {
    let title: String
    @ViewBuilder let content: () -> C
    @Environment(\.look) private var L

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) { content() }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 110)
                .readableColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(L.bg).ignoresSafeArea())
        .navigationTitle(Lang.tr(title))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsSection<C: View>: View {
    let title: String
    @ViewBuilder let content: () -> C
    @Environment(\.look) private var L

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(JFont.display(15 * 1.2)).foregroundStyle(Color(L.ink))
            content()
        }
    }
}

struct SettingsField<C: View>: View {
    let label: String
    @ViewBuilder let content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { JLabel(text: label); content() }
    }
}

struct SettingsNote: View {
    let text: String
    @Environment(\.look) private var L
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(JFont.body(15 * 0.86)).foregroundStyle(Color(L.ink2)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - المظهر

struct SettingsLookPage: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L

    var body: some View {
        SettingsPage(title: "المظهر") {
            SettingsSection(title: "المظهر") {
                SettingsField(label: "الوضع") { JSeg(options: [("system", "حسب الجهاز"), ("light", "فاتح"), ("dark", "داكن")], value: SettingsBind.str("theme", "system")) }
                SettingsField(label: "اللون الأساسي") { swatches }
                SettingsField(label: "حجم الخط") { JSeg(options: [("s", "صغير"), ("m", "متوسط"), ("l", "كبير")], value: SettingsBind.str("fs", "m")) }
            }
        }
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
}

// MARK: - اللغة

struct SettingsLanguagePage: View {
    @ObservedObject private var lib = Library.shared

    var body: some View {
        SettingsPage(title: "اللغة · Language") {
            SettingsSection(title: "اللغة · Language") {
                JSeg(options: [(false, "العربية"), (true, "English")],
                     value: Binding(get: { LangState.shared.english }, set: { v in
                         LangState.shared.set(english: v)
                         lib.objectWillChange.send()
                     }))
                SettingsNote("أسماء الكتب والروايات والمواقع وما كتبته أنت تبقى كما هي.")
            }
        }
    }
}

// MARK: - المكتبة

struct SettingsLibraryPage: View {
    @Environment(\.look) private var L
    @State private var shelfStyle = false

    var body: some View {
        SettingsPage(title: "المكتبة") {
            SettingsSection(title: "المكتبة") {
                SettingsField(label: "العرض الافتراضي") { JSeg(options: [("carousel", "دائري"), ("shelf", "رفوف"), ("grid", "شبكة")], value: SettingsBind.str("view", "carousel")) }
                SettingsField(label: "شكل الدوران") { JSeg(options: [("stack", "مكدّس"), ("flow", "أغلفة مائلة")], value: SettingsBind.str("carStyle", "stack")) }
                Button { shelfStyle = true } label: { Label("شكل الرف والإضاءة", systemImage: "paintpalette") }
                    .buttonStyle(JButtonStyle(look: L, small: true))
            }
        }
        .sheet(isPresented: $shelfStyle) { ShelfStyleSheet().environment(\.look, L).environment(\.layoutDirection, Lang.direction) }
    }
}

// MARK: - الجلسة والتذكير

struct SettingsSessionPage: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L

    var body: some View {
        SettingsPage(title: "الجلسة والتذكير") {
            SettingsSection(title: "الجلسة") {
                SettingsField(label: "الصوت الافتراضي") { JSeg(options: SessionModel.sounds, value: SettingsBind.str("sound", "rain")) }
                VStack(spacing: 0) {
                    JSwitchRow(title: "غلاف الكتاب خلفية للجلسة", on: SettingsBind.flag("sessCover", false))
                    JSwitchRow(title: "إبقاء الشاشة مضاءة أثناء الجلسة", on: SettingsBind.flag("wake", true))
                }
            }

            SettingsSection(title: "التذكير اليومي") {
                JSwitchRow(title: "ذكّرني بالقراءة", sub: "إشعار في الوقت اللي تختاره، وما يجيك إذا حققت هدفك ذاك اليوم", on: remindOn)
                if remind.bool("on") {
                    HStack {
                        JLabel(text: "الوقت")
                        Spacer()
                        DatePicker("", selection: remindTime, displayedComponents: .hourAndMinute).labelsHidden()
                            .environment(\.locale, Lang.locale)
                    }
                }
            }
        }
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
}

// MARK: - الروايات والقراءة الصوتية

struct SettingsNovelsPage: View {
    var body: some View {
        SettingsPage(title: "الروايات والقراءة الصوتية") {
            SettingsSection(title: "الروايات") {
                SettingsNote("التنبيه لكل رواية من جرس صفحتها: مع كل فصل، أو لما يتجمع عدد تختاره.")
            }
            SettingsSection(title: "القراءة الصوتية") {
                ReadAloudSettings()
            }
        }
    }
}

// MARK: - الخصوصية والحرق

struct SettingsPrivacyPage: View {
    @ObservedObject private var lib = Library.shared

    var body: some View {
        SettingsPage(title: "الخصوصية") {
            SettingsSection(title: "الخصوصية") {
                JSwitchRow(title: "قفل جليس بـ " + AppLock.method, sub: "يتغطى أول ما تطلع منه، ويفتح بوجهك أو رمز الجوال",
                           on: Binding(get: { AppLock.shared.enabled }, set: { AppLock.shared.turnOn($0); lib.objectWillChange.send() }))
                if AppLock.shared.enabled {
                    SettingsField(label: "يتقفل") {
                        JSeg(options: [(0.0, "فورًا"), (60.0, "بعد دقيقة"), (300.0, "بعد 5 دقائق")],
                             value: Binding(get: { AppLock.shared.grace }, set: { AppLock.shared.grace = $0; lib.objectWillChange.send() }))
                    }
                }
            }

            SettingsSection(title: "الكلمات والشخصيات") {
                JSwitchRow(title: "إخفاء الحرق", sub: "موت الشخصية، والاقتباسات والأفكار والمراجعات اللي علّمتها «فيها حرق»، تظهر مغطّاة حتى تضغط عليها", on: SettingsBind.flag("spoilers", true))
            }
        }
    }
}

// MARK: - السيرفر

struct SettingsServerPage: View {
    var body: some View {
        SettingsPage(title: "السيرفر") {
            ServerSettings()
        }
    }
}

// MARK: - البيانات

struct SettingsDataPage: View {
    /// set by the debug hook on the root: open the reset confirmation
    @Binding var openReset: Bool
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var askReset = false
    @State private var exporting = false

    var body: some View {
        SettingsPage(title: "البيانات") {
            SettingsSection(title: "البيانات") {
                SettingsNote("بياناتك محفوظة في جوالك داخل التطبيق. صدّر نسخة احتياطية لتطبيق «الملفات» أول بأول، عشان لو حذفت التطبيق ترجعها.")
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
        }
        .sheet(isPresented: $askReset) { ResetSheet().environment(\.look, L).environment(\.layoutDirection, Lang.direction).presentationDetents([.medium]) }
        // the page may be pushed by the hook (onAppear) or already open (onChange)
        .onAppear { takeResetRequest() }
        .onChange(of: openReset) { _ in takeResetRequest() }
    }

    private func takeResetRequest() {
        guard openReset else { return }
        openReset = false
        askReset = true
    }

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

// MARK: - متقدمة

struct SettingsAdvancedPage: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L

    var body: some View {
        SettingsPage(title: "متقدمة") {
            // «متقدمة» (the third round of answers): what most never need, shown when asked for
            SettingsSection(title: "متقدمة") {
                JSwitchRow(title: "أظهر الإعدادات المتقدمة", sub: "أبعاد الكتب، مفتاح Google Books، طريقة مراجعة الكلمات، والفحص بالخلفية", on: SettingsBind.flag("advanced", false))
                if lib.state.settings.raw.bool("advanced") {
                    SettingsField(label: "تعديل أبعاد الكتاب") {
                        JSeg(options: [("handles", "سحب المقابض"), ("sliders", "أشرطة تمرير")], value: SettingsBind.str("dimMode", "handles"))
                        SettingsNote("القياسات بالسنتيمتر متاحة في الحالتين.")
                    }
                    SettingsField(label: "طريقة المراجعة") {
                        JSeg(options: [("simple", "عادية"), ("srs", "تكرار متباعد")], value: SettingsBind.str("review", "srs"))
                        SettingsNote(lib.state.settings.raw.str("review", "srs") == "srs"
                             ? "كل كلمة ترجع لك بعد مدة تطول كلما عرفتها، وتقصر كلما صعبت عليك."
                             : "تمر على كل الكلمات بترتيب عشوائي وتعلّم اللي عرفتها.")
                    }
                    VStack(spacing: 0) {
                        JSwitchRow(title: "أفحص الفصول الجديدة بالخلفية", sub: "iOS يحدد الوقت، مرة بالساعة بالأكثر. لو حسيت إنه ياكل بطارية طفّه، ويبقى الفحص لما تفتح جليس أو تسحب قائمة التحديثات", on: Binding(get: { NewChapters.background }, set: { NewChapters.background = $0; lib.objectWillChange.send() }))
                        JSwitchRow(title: "عدد الفصول الجديدة على أيقونة جليس", on: Binding(get: { NewChapters.badge }, set: { NewChapters.badge = $0; lib.objectWillChange.send() }))
                    }
                    SettingsField(label: "مفتاح Google Books (اختياري)") {
                        TextField("AIza…", text: SettingsBind.str("gbKey", ""))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                            .multilineTextAlignment(.leading)
                            .environment(\.layoutDirection, .leftToRight)
                            .font(JFont.body(16)).foregroundStyle(Color(L.ink))
                            .padding(.horizontal, 14).frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                    }
                    SettingsNote("البحث يشتغل بدونه من Goodreads وأبجد وOpen Library. Google Books بدون مفتاح يرفض أغلب الطلبات لأن حدّه المجاني المشترك يخلص بسرعة. لو تبي نتائجه، سوّ مفتاحًا مجانيًا لـ «Books API» من Google Cloud والصقه هنا.")
                }
            }
        }
    }
}
