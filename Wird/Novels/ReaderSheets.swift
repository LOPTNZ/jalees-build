import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The reader's panels follow Apple Books (dark glass sheets). Everything here changes the open page at once.

private let arabicLatn = Lang.locale

// MARK: - السمات والإعدادات

struct ThemesSheet: View {
    @ObservedObject var settings: ReaderSettings
    var novelID: Int = 0
    var close: () -> Void
    /// the sheet grows to full height when a page is pushed over the panel
    var expand: () -> Void = {}
    @State private var brightness = Double(UIScreen.main.brightness)
    @State private var path: [String] = []

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    /// also the menu's «طريقة القراءة» (ReaderViewController.pageStyles)
    static let modes: [(id: String, anim: String?, name: String, icon: String)] = [
        ("chapter", nil, "تمرير لكل فصل", "scroll"), ("continuous", nil, "تمرير متصل", "arrow.down.to.line.compact"),
        ("paged", "curl", "تقليب: طي", "book"), ("paged", "slide", "تقليب: سحب", "book.pages"), ("paged", "fade", "تقليب: تلاشي", "circle.lefthalf.filled")
    ]

    private var modeIcon: String {
        let p = settings.prefs
        return ThemesSheet.modes.first { $0.id == p.mode && ($0.anim == nil || $0.anim == p.anim) }?.icon ?? "scroll"
    }

    var body: some View {
        NavigationStack(path: $path) {
            panel
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { k in
                    if k == "customize" {
                        CustomizeSheet(settings: settings, close: close, embedded: true)
                    } else {
                        ReadingSheet(settings: settings, novelID: novelID, close: close, embedded: true)
                    }
                }
        }
        .environment(\.layoutDirection, Lang.direction)
        .preferredColorScheme(.dark)
    }

    private var panel: some View {
        VStack(spacing: 14) {
            HStack {
                Text("السمات والإعدادات").font(.system(size: 19, weight: .bold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("إغلاق")
            }

            HStack(spacing: 10) {
                Menu {
                    ForEach(ThemesSheet.modes.indices, id: \.self) { i in
                        let m = ThemesSheet.modes[i]
                        let on = settings.prefs.mode == m.id && (m.anim == nil || settings.prefs.anim == m.anim)
                        Button {
                            settings.prefs.mode = m.id
                            if let a = m.anim { settings.prefs.anim = a }
                        } label: {
                            Label(m.name, systemImage: on ? "checkmark" : m.icon)
                        }
                    }
                } label: {
                    Image(systemName: modeIcon).font(.system(size: 16, weight: .semibold)).frame(width: 54, height: 42)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .accessibilityLabel("طريقة القراءة")

                HStack(spacing: 0) {
                    Button { settings.edit { $0.size -= 1 } } label: {
                        Text("ع").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .accessibilityLabel("تصغير الخط")
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 20)
                    Button { settings.edit { $0.size += 1 } } label: {
                        Text("ع").font(.system(size: 23, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .accessibilityLabel("تكبير الخط")
                }
                .background(Color.white.opacity(0.12), in: Capsule())

                Text("\(Int(settings.current.size))").font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .frame(width: 48, height: 42).background(Color.white.opacity(0.12), in: Capsule())
                    .accessibilityLabel("حجم الخط \(Int(settings.current.size))")
            }

            HStack(spacing: 12) {
                Image(systemName: "sun.min.fill").font(.system(size: 14))
                Slider(value: $brightness, in: 0.02...1).tint(.white)
                    .onChange(of: brightness) { v in UIScreen.main.brightness = CGFloat(v) }
                Image(systemName: "sun.max.fill").font(.system(size: 17))
            }
            .foregroundStyle(Color.white.opacity(0.8))

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(settings.themes) { t in
                    Button { settings.select(t.id) } label: { ThemeTile(theme: t, on: t.id == settings.currentID) }.buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Button { path.append("customize"); expand() } label: {
                    Label("تخصيص السمة", systemImage: "paintbrush").font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46).background(Color.white.opacity(0.12), in: Capsule())
                }
                Button { path.append("reading"); expand() } label: {
                    Label("إعدادات القراءة", systemImage: "gearshape").font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46).background(Color.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, arabicLatn)
        .preferredColorScheme(.dark)
    }
}

private struct ThemeTile: View {
    let theme: ReaderTheme
    let on: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text("عع").font(.system(size: 22, weight: theme.bold ? .bold : .medium))
            Text(theme.name).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color(UIColor(hex: theme.fg)))
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(Color(UIColor(hex: theme.bg)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Color.white : Color.white.opacity(0.16), lineWidth: on ? 2.5 : 1))
        .overlay(alignment: .topLeading) {
            if theme.edited { Text("*").font(.system(size: 15, weight: .bold)).foregroundStyle(Color(UIColor(hex: theme.fg)).opacity(0.7)).padding(.leading, 9).padding(.top, 4) }
        }
        .accessibilityLabel(theme.name)
    }
}

// MARK: - تخصيص

/// Every look value belongs to the theme that is on; the reading behaviour is the same for all themes.
struct CustomizeSheet: View {
    @ObservedObject var settings: ReaderSettings
    var close: () -> Void
    /// pushed inside the themes panel's stack (back to it), or a sheet of its own
    var embedded = false
    @State private var importing = false
    @State private var askGoogle = false
    @State private var googleName = ""
    @State private var busy = false
    @State private var note: String?

    private func value(_ get: @escaping (ReaderTheme) -> Double, _ set: @escaping (inout ReaderTheme, Double) -> Void) -> Binding<Double> {
        Binding(get: { get(settings.current) }, set: { v in settings.edit { set(&$0, v) } })
    }
    private func flag(_ get: @escaping (ReaderTheme) -> Bool, _ set: @escaping (inout ReaderTheme, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { get(settings.current) }, set: { v in settings.edit { set(&$0, v) } })
    }
    private func text(_ get: @escaping (ReaderTheme) -> String, _ set: @escaping (inout ReaderTheme, String) -> Void) -> Binding<String> {
        Binding(get: { get(settings.current) }, set: { v in settings.edit { set(&$0, v) } })
    }
    private var modeBinding: Binding<String> {
        Binding(get: { settings.prefs.mode == "paged" ? "paged-" + settings.prefs.anim : settings.prefs.mode },
                set: { v in
                    if v.hasPrefix("paged-") { settings.prefs.mode = "paged"; settings.prefs.anim = String(v.dropFirst(6)) } else { settings.prefs.mode = v }
                })
    }

    var body: some View {
        MaybeStack(on: !embedded) {
            Form {
                Section("النص") {
                    Picker("الخط", selection: text({ $0.font }, { $0.font = $1 })) {
                        ForEach(settings.allFonts.indices, id: \.self) { i in Text(settings.allFonts[i].name).tag(settings.allFonts[i].id) }
                    }
                    Picker("خط الإنجليزي", selection: text({ $0.latin }, { $0.latin = $1 })) {
                        Text("نفس خط العربي").tag("same")
                        ForEach(settings.allFonts.indices, id: \.self) { i in Text(settings.allFonts[i].name).tag(settings.allFonts[i].id) }
                    }
                    Toggle("نص غامق", isOn: flag({ $0.bold }, { $0.bold = $1 }))
                    SliderRow(title: "حجم الخط", text: "\(Int(settings.current.size))", value: value({ $0.size }, { $0.size = $1 }), range: 12...48, step: 1)
                    Menu {
                        Button { importing = true } label: { Label("من ملف (ttf أو otf)", systemImage: "doc") }
                        Button { askGoogle = true } label: { Label("من Google Fonts بالاسم", systemImage: "globe") }
                    } label: {
                        HStack { Text("أضف خط"); Spacer(); if busy { ProgressView() } else { Image(systemName: "plus.circle") } }
                    }
                    ForEach(settings.fonts) { f in
                        HStack { Text(f.family); Spacer(); Text("مضاف").foregroundStyle(.secondary).font(.footnote) }
                            .swipeActions { Button("حذف", role: .destructive) { settings.removeFont(f) } }
                    }
                }
                Section("التخطيط") {
                    Picker("المحاذاة", selection: text({ $0.align }, { $0.align = $1 })) {
                        Text("يمين").tag("start"); Text("وسط").tag("center"); Text("يسار").tag("end"); Text("ضبط").tag("justify")
                    }
                    .pickerStyle(.segmented)
                    SliderRow(title: "تباعد الأسطر", text: String(format: "%.2f", settings.current.line), value: value({ $0.line }, { $0.line = $1 }), range: 1...2.6, step: 0.05)
                    SliderRow(title: "تباعد الأحرف", text: "\(Int(settings.current.letter))٪", value: value({ $0.letter }, { $0.letter = $1 }), range: -5...20, step: 1)
                    Toggle("التباعد بالعربي بالكشيدة (عــيـن)", isOn: flag({ $0.kashida }, { $0.kashida = $1 }))
                    SliderRow(title: "تباعد الكلمات", text: "\(Int(settings.current.word))٪", value: value({ $0.word }, { $0.word = $1 }), range: -20...80, step: 5)
                    SliderRow(title: "الهوامش", text: "\(Int(settings.current.margin))٪", value: value({ $0.margin }, { $0.margin = $1 }), range: -18...40, step: 1)
                }
                Section {
                    Button("إعادة تعيين السمة", role: .destructive) { settings.resetCurrent() }
                }
            }
            .navigationTitle("تخصيص «\(settings.current.name)»")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم", action: close) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.font]) { r in
                if case .success(let url) = r { addFile(url) }
            }
            .alert("خط من Google Fonts", isPresented: $askGoogle) {
                TextField("اسم الخط، مثل Noto Naskh Arabic", text: $googleName).autocorrectionDisabled()
                Button("أضف") { addGoogle() }
                Button("إلغاء", role: .cancel) {}
            } message: { Text("اكتب اسم الخط كما هو في fonts.google.com") }
            .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) { Button("تمام", role: .cancel) {} }
        }
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, arabicLatn)
        .preferredColorScheme(.dark)
    }

    private func addFile(_ url: URL) {
        busy = true
        Task { @MainActor in
            do {
                let f = try FontStore.addFile(url)
                settings.addFont(f)
                settings.edit { $0.font = f.id }
                note = "انضاف خط «\(f.family)» وصار خط هذه السمة"
            } catch { note = error.localizedDescription }
            busy = false
        }
    }

    private func addGoogle() {
        let name = googleName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        busy = true
        Task { @MainActor in
            do {
                let f = try await FontStore.addGoogle(name)
                settings.addFont(f)
                settings.edit { $0.font = f.id }
                note = "انضاف خط «\(f.family)» وصار خط هذه السمة"
            } catch { note = error.localizedDescription }
            busy = false
        }
    }
}

private struct SliderRow: View {
    let title: String
    let text: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(text).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: $value, in: range, step: step)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(text)
    }
}

// MARK: - إعدادات القراءة (the same for every theme)

extension Notification.Name {
    /// «قفل الاتجاه الرأسي» changed in the reading settings: the open reader turns (or stops turning) with the phone
    static let readerLockChanged = Notification.Name("jalees.readerLockChanged")
}

/// Grouped by what they are about (reader 2.3): how pages move, what the page shows, the reading tools, the text,
/// and the chapters saved ahead. What used to hide behind «إعدادات متقدمة» sits in its own group.
struct ReadingSheet: View {
    @ObservedObject var settings: ReaderSettings
    let novelID: Int
    var close: () -> Void
    var embedded = false
    @State private var locked = DB.shared.get("reader.lock") == "1"

    private var modeBinding: Binding<String> {
        Binding(get: { settings.prefs.mode == "paged" ? "paged-" + settings.prefs.anim : settings.prefs.mode },
                set: { v in
                    if v.hasPrefix("paged-") { settings.prefs.mode = "paged"; settings.prefs.anim = String(v.dropFirst(6)) } else { settings.prefs.mode = v }
                })
    }

    private var lockBinding: Binding<Bool> {
        Binding(get: { locked }, set: { v in
            locked = v
            DB.shared.set("reader.lock", v ? "1" : nil)
            NotificationCenter.default.post(name: .readerLockChanged, object: nil)
        })
    }

    var body: some View {
        MaybeStack(on: !embedded) {
            Form {
                Section("طريقة القراءة") {
                    Picker("الروايات", selection: modeBinding) {
                        Text("تمرير متصل").tag("continuous"); Text("تمرير لكل فصل").tag("chapter")
                        Text("تقليب: طي").tag("paged-curl"); Text("تقليب: سحب").tag("paged-slide"); Text("تقليب: تلاشي").tag("paged-fade")
                    }
                    Picker("الكتب (EPUB)", selection: $settings.prefs.epubMode) {
                        Text("تمرير متصل").tag("continuous"); Text("تمرير لكل قسم").tag("chapter"); Text("تقليب").tag("paged")
                    }
                    Toggle("السحب يمين ويسار يغيّر الفصل", isOn: $settings.prefs.swipeChapters)
                    Picker("بالعرض", selection: $settings.prefs.landscapeColumns) { Text("عمود واحد").tag(1); Text("عمودين").tag(2) }
                    Toggle("قفل الاتجاه الرأسي", isOn: lockBinding)
                }
                Section("الصفحة") {
                    Toggle("التعليقات آخر الفصل", isOn: $settings.prefs.comments)
                    Toggle("أخفِ عنوان الفصل", isOn: $settings.prefs.hideHeading)
                    Picker("أسماء الشخصيات", selection: $settings.prefs.nameStyle) {
                        Text("لون خفيف").tag("tint"); Text("خط تحتها").tag("underline"); Text("غامقة").tag("bold"); Text("متوهّجة").tag("glow"); Text("بدون").tag("off")
                    }
                    Toggle("أظهر شريطة الوقفة", isOn: $settings.prefs.showRibbon)
                }
                Section {
                    SliderRow(title: "سرعة التمرير التلقائي", text: "\(Int(settings.prefs.autoSpeed))", value: $settings.prefs.autoSpeed, range: 8...240, step: 4)
                } header: { Text("أدوات القراءة") } footer: { Text("دليل السطر والتمرير التلقائي في قائمة القارئ؛ دليل السطر له زر تحت لتعتيمه وارتفاعه.") }
                Section {
                    // back to these settings, or «تم» to the page
                    NavigationLink {
                        MenuEditorView(epub: Novels.shared.list.first(where: { $0.id == novelID })?.source == "epub", close: close, embedded: true)
                    } label: { Label("خصّص القائمة", systemImage: "slider.horizontal.3") }
                } header: { Text("قائمة القارئ") } footer: {
                    Text("رتّب صفوف القائمة وأزرارها و«المزيد» مثل ما تبي، أو أخفِ اللي ما تحتاجه.")
                }
                Section("النص") {
                    // back to these settings, or «تم» to the page (the rules are already on it)
                    NavigationLink {
                        ReplaceRulesView(scope: String(novelID), title: "هذه الرواية")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم", action: close) } }
                    } label: { Text("قواعد الاستبدال لهذه الرواية") }
                    NavigationLink {
                        ReplaceRulesView(scope: "all", title: "كل الروايات")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم", action: close) } }
                    } label: { Text("قواعد الاستبدال لكل الروايات") }
                }
                Section {
                    Stepper(value: $settings.prefs.ahead, in: 0...10) { Text("فصول تتجهّز قدام: \(settings.prefs.ahead)") }
                } header: { Text("التحميل المسبق") } footer: {
                    Text("الفصول الجاية تنحفظ بهدوء وأنت تقرأ، عشان الانتقال لها يكون فوري وتقدر تقرأها بدون نت.")
                }
            }
            .navigationTitle("إعدادات القراءة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم", action: close) } }
        }
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, arabicLatn)
        .preferredColorScheme(.dark)
    }
}

/// The replacement rules over the page, from the menu's «قواعد الاستبدال» or the selection's «استبدال الكلمة» (with
/// that word's rule already started).
struct RulesSheet: View {
    let novelID: Int
    var seed = ""
    var close: () -> Void

    var body: some View {
        NavigationStack {
            ReplaceRulesView(scope: String(novelID), title: "هذه الرواية", seed: seed)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("تم", action: close) }
                    ToolbarItem(placement: .cancellationAction) {
                        NavigationLink {
                            ReplaceRulesView(scope: "all", title: "كل الروايات")
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم", action: close) } }
                        } label: { Text("كل الروايات") }
                    }
                }
        }
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, arabicLatn)
        .preferredColorScheme(.dark)
    }
}

/// Its own navigation stack, or none when it is pushed inside another one.
struct MaybeStack<C: View>: View {
    let on: Bool
    @ViewBuilder let content: () -> C
    var body: some View {
        if on { NavigationStack { content() } } else { content() }
    }
}

// MARK: - قواعد الاستبدال

struct ReplaceRulesView: View {
    let scope: String
    let title: String
    /// a word selected in the reader («استبدال الكلمة»): its rule is started for it, the word into itself, so the
    /// text changes only when «تصير» is changed (left as it is, it is not kept)
    var seed = ""
    @State private var rules: [ReplaceRule] = []
    @State private var family: FamilyAsk?
    @State private var seeded: String?

    struct FamilyAsk: Identifiable { let id: String }

    var body: some View {
        Form {
            ForEach($rules) { $r in
                Section {
                    HStack {
                        TextField("الكلمة", text: $r.from)
                        Image(systemName: "arrow.left").foregroundStyle(.secondary)
                        TextField("تصير", text: $r.to)
                    }
                    Toggle("ومشتقاتها (وال، بال، فلل… والضمائر)", isOn: $r.forms).font(.footnote)
                    ForEach($r.more) { $f in
                        HStack {
                            TextField("كلمة من عائلتها", text: $f.from)
                            Image(systemName: "arrow.left").foregroundStyle(.secondary)
                            TextField(r.to.isEmpty ? "تصير" : r.to, text: $f.to)
                        }
                        .font(.subheadline)
                    }
                    .onDelete { $r.wrappedValue.more.remove(atOffsets: $0) }
                    HStack {
                        Button { $r.wrappedValue.more.append(.init()) } label: { Label("كلمة من نفس العائلة", systemImage: "plus") }.font(.footnote)
                        Spacer()
                        if Int(scope) != nil, !r.from.isEmpty {
                            Button { family = FamilyAsk(id: r.id) } label: { Label("دوّرها في الرواية", systemImage: "sparkle.magnifyingglass") }
                                .font(.footnote)
                        }
                    }
                    .buttonStyle(.borderless)
                    Toggle("مفعّلة", isOn: $r.on).font(.footnote)
                } footer: {
                    // after this pass (a row's binding must not outlive its rule)
                    Button("حذف القاعدة", role: .destructive) { let id = r.id; DispatchQueue.main.async { withAnimation { rules.removeAll { $0.id == id } } } }
                        .font(.footnote)
                }
            }
            Section {
                Button { rules.append(ReplaceRule()) } label: { Label("قاعدة جديدة", systemImage: "plus") }
            } footer: {
                Text("الهمزات وأشكال الألف والتشكيل ما تفرق (اميليا = إميليا). الكلمات اللي شكلها يختلف (آلهة، ألوهية) حطها في نفس القاعدة كلمة من نفس العائلة، و«دوّرها في الرواية» يلقاها لك. تتطبّق على الفصل المفتوح على طول.")
            }
        }
        .navigationTitle("قواعد الاستبدال · " + title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            rules = Replacer.rules(scope)
            let w = seed.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !w.isEmpty, seeded == nil, !rules.contains(where: { Replacer.plain($0.from) == Replacer.plain(w) }) {
                var r = ReplaceRule()
                r.from = w
                r.to = w
                rules.append(r)
                seeded = r.id
            }
        }
        .onDisappear {
            if let id = seeded, let r = rules.first(where: { $0.id == id }), r.to == r.from, r.more.isEmpty {
                Replacer.save(rules.filter { $0.id != id }, scope)
            }
        }
        // saved as it changes: the open chapter follows at once (the reader listens)
        .onChange(of: rules) { Replacer.save($0, scope) }
        .sheet(item: $family) { f in
            if let i = rules.firstIndex(where: { $0.id == f.id }), let n = Int(scope) {
                FamilyPicker(rule: $rules[i], novel: n)
            }
        }
    }
}

/// «دوّرها في الرواية»: the words of the same family in the novel's saved chapters, to tick into the rule.
private struct FamilyPicker: View {
    @Binding var rule: ReplaceRule
    let novel: Int
    @Environment(\.dismiss) private var dismiss
    @State private var found: [(word: String, count: Int)]?
    @State private var picked: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if let f = found {
                    if f.isEmpty {
                        Text("ما لقيت كلمات قريبة منها في فصولها المحفوظة.").foregroundStyle(.secondary).padding()
                    } else {
                        List(f, id: \.word) { w in
                            Button {
                                if picked.contains(w.word) { picked.remove(w.word) } else { picked.insert(w.word) }
                            } label: {
                                HStack {
                                    Image(systemName: picked.contains(w.word) ? "checkmark.circle.fill" : "circle")
                                    Text(w.word)
                                    Spacer()
                                    Text("\(w.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("عائلة «\(rule.from)»")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("أضف \(picked.count)") {
                        rule.more += picked.sorted().map { ReplaceRule.Form(from: $0, to: "") }
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
            .task {
                found = await Replacer.family(of: rule.from, novel: novel, skip: Set(rule.more.map(\.from)))
            }
        }
        .environment(\.layoutDirection, Lang.direction)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - المحتويات

/// The chapter list: opens at the chapter being read, and finds a chapter by its number or a word of its title.
struct ContentsSheet: View {
    let novel: Novel
    let chapters: [ChapterRow]
    let current: Int
    var pick: (Int) -> Void
    var close: () -> Void
    @State private var query = ""
    @State private var newestFirst = false

    private var shown: [ChapterRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var list = chapters
        if !q.isEmpty { list = list.filter { $0.num == q || $0.num.hasPrefix(q) || $0.title.localizedCaseInsensitiveContains(q) } }
        return newestFirst ? list.reversed() : list
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(shown) { ch in
                    Button { pick(ch.idx) } label: { ChapterLine(ch: ch, on: ch.idx == current) }
                        .listRowBackground(ch.idx == current ? Color.white.opacity(0.1) : Color.clear)
                        .id(ch.id)
                }
                .listStyle(.plain)
                .onAppear {
                    if chapters.indices.contains(current) {
                        let id = chapters[current].id
                        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "رقم الفصل أو كلمة من عنوانه")
            .navigationTitle(novel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق", action: close) }
                ToolbarItem(placement: .primaryAction) {
                    Button { newestFirst.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }
                        .accessibilityLabel(newestFirst ? "الأقدم أولاً" : "الأحدث أولاً")
                }
            }
        }
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, arabicLatn)
        .preferredColorScheme(.dark)
    }
}

struct ChapterLine: View {
    let ch: ChapterRow
    let on: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ch.label).font(.system(size: 15, weight: on ? .bold : .semibold))
                if ch.numbered, !ch.title.isEmpty { Text(ch.title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if ch.saved { Image(systemName: "arrow.down.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary).accessibilityLabel("محفوظ") }
            if ch.read { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).accessibilityLabel("مقروء") }
        }
        .foregroundStyle(ch.read && !on ? Color.primary.opacity(0.55) : Color.primary)
        .contentShape(Rectangle())
    }
}

// MARK: - دفتر الرواية: the book's notebook, inside the reader (دفتري 2.4: the same notebook as the tab's)

/// The book's notebook over the page: the same view, cards and actions as the book's page in دفتري
/// (BookNotebookBody), in Jalees's look. A passage moves the open reader to it, a heading opens its chapter, the forms
/// and cards open over the page, the + adds a bookmark or an entry at the chapter being read. It reads the library
/// itself, so a change anywhere (the notebook tab, a form over the page) shows here, and what is deleted here leaves
/// the page and the notebook at once.
struct ReaderNotebookSheet: View {
    let bookID: String
    let title: String
    let labels: [String: String]
    let bookmarkedHere: Bool
    private let link: NBReaderLink
    private let start: String
    @Environment(\.dismiss) private var dismiss

    init(bookID: String, title: String, chapters: [ChapterRow], labels: [String: String], bookmarkedHere: Bool, filter: String = "all",
         open: @escaping (Int, Int) -> Void, editNote: @escaping ([String: Any]) -> Void, editItem: @escaping (String, String) -> Void,
         openCharacter: @escaping (String) -> Void, add: @escaping (String) -> Void, toNotebook: @escaping () -> Void) {
        self.bookID = bookID
        self.title = title
        self.labels = labels
        self.bookmarkedHere = bookmarkedHere
        link = NBReaderLink(chapters: NBChapters(chapters), bookmarkedHere: bookmarkedHere, open: open, editNote: editNote, editItem: editItem,
                            openCharacter: openCharacter, add: add, toNotebook: toNotebook)
        start = filter
    }

    var body: some View {
        let look = Appearance.shared.look
        Group {
            if Library.shared.state.book(bookID) != nil {
                BookNotebookBody(bookID: bookID, start: start == "all" ? "" : start, reader: link, title: title, close: { dismiss() })
            } else {
                VStack(spacing: 8) {
                    Spacer(minLength: 60)
                    Text("افتح الرواية من مكتبتك").font(JFont.body(17, .semibold)).foregroundStyle(Color(look.ink))
                    Text("دفترها يكون مع كتابها في مكتبتك.").font(JFont.body(14)).foregroundStyle(Color(look.ink2))
                    Button("تم") { dismiss() }.buttonStyle(JButtonStyle(look: look, small: true)).padding(.top, 8)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .background(Color(look.bg).ignoresSafeArea())
            }
        }
        .environment(\.look, look)
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, arabicLatn)
        .preferredColorScheme(look.dark ? .dark : .light)
    }
}

// MARK: - بحث في الرواية

struct SearchSheet: View {
    let novel: Novel
    let chapters: [ChapterRow]
    /// «بحث في الرواية» or, in an EPUB, «بحث في الكتاب»
    var title = "بحث في الرواية"
    var open: (Int, String, Int) -> Void
    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var searching = false
    @State private var done = false
    @State private var recent: [String] = (DB.shared.get("reader.recentSearch") ?? "").split(separator: "\n").map(String.init)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    HStack(spacing: 10) { ProgressView(); Text("يجري البحث…").foregroundStyle(.secondary) }
                } else if done {
                    Section {
                        ForEach(results) { h in
                            Button { open(h.chapter, query, h.nth) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(h.label).font(.system(size: 14, weight: .semibold))
                                    (Text(h.before) + Text(h.match).bold().foregroundColor(.primary) + Text(h.after))
                                        .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }
                    } footer: {
                        Text((results.isEmpty ? "ما لقيت «\(query)»." : "لقيت \(results.count)\(results.count >= 300 ? "+" : "") نتيجة.") +
                             " البحث يشمل الفصول المحفوظة على جوالك (\(chapters.filter(\.saved).count) من \(chapters.count)).")
                    }
                } else if !recent.isEmpty {
                    Section {
                        ForEach(recent, id: \.self) { r in Button(r) { query = r; run() } }
                    } header: {
                        HStack { Text("عمليات البحث الأخيرة"); Spacer(); Button("مسح") { recent = []; DB.shared.set("reader.recentSearch", nil) }.font(.footnote) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "في هذه الرواية")
            .onSubmit(of: .search) { run() }
            .onChange(of: query) { _ in done = false }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, arabicLatn)
        .preferredColorScheme(.dark)
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        recent.removeAll { $0 == q }
        recent.insert(q, at: 0)
        recent = Array(recent.prefix(10))
        DB.shared.set("reader.recentSearch", recent.joined(separator: "\n"))
        searching = true
        let labels = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0.line) })
        let order = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0.idx) })
        let id = novel.id
        Task.detached {
            let hits = TextSearch.run(novel: id, query: q, labels: labels, order: order)
            await MainActor.run {
                results = hits
                searching = false
                done = true
            }
        }
    }
}

// MARK: - ملاحظة

/// A highlight's note: over the page (dark, like the reader), or from the notebook's «تظليلات» (in the app's look).
struct NoteSheet: View {
    let text: String
    var dark = true
    var save: (String) -> Void
    @State private var note: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(text: String, note: String, dark: Bool = true, save: @escaping (String) -> Void) {
        self.text = text
        self.dark = dark
        self.save = save
        _note = State(initialValue: note)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "«\(text)»").font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(4)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.yellow.opacity(0.7)).frame(width: 3) }
                TextEditor(text: $note).focused($focused).scrollContentBackground(.hidden).font(.system(size: 17))
                    .overlay(alignment: .topLeading) {
                        if note.isEmpty { Text("إضافة ملاحظة…").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                    }
            }
            .padding()
            .navigationTitle("ملاحظة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("حفظ") { save(note.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() } }
            }
            .onAppear { focused = true }
        }
        .environment(\.layoutDirection, Lang.direction)
        .preferredColorScheme(dark ? .dark : .light)
    }
}
