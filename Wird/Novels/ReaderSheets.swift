import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The reader's panels follow Apple Books (dark glass sheets). Everything here changes the open page at once.

private let arabicLatn = Lang.locale

// MARK: - السمات والإعدادات

struct ThemesSheet: View {
    @ObservedObject var settings: ReaderSettings
    var close: () -> Void
    var customize: () -> Void
    var reading: () -> Void
    @State private var brightness = Double(UIScreen.main.brightness)

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    private static let modes: [(id: String, anim: String?, name: String, icon: String)] = [
        ("chapter", nil, "تمرير لكل فصل", "scroll"), ("continuous", nil, "تمرير متصل", "arrow.down.to.line.compact"),
        ("paged", "curl", "تقليب: طي", "book"), ("paged", "slide", "تقليب: سحب", "book.pages"), ("paged", "fade", "تقليب: تلاشي", "circle.lefthalf.filled")
    ]

    private var modeIcon: String {
        let p = settings.prefs
        return ThemesSheet.modes.first { $0.id == p.mode && ($0.anim == nil || $0.anim == p.anim) }?.icon ?? "scroll"
    }

    var body: some View {
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
                Button(action: customize) {
                    Label("تخصيص السمة", systemImage: "paintbrush").font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46).background(Color.white.opacity(0.12), in: Capsule())
                }
                Button(action: reading) {
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
        NavigationStack {
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

struct ReadingSheet: View {
    @ObservedObject var settings: ReaderSettings
    let novelID: Int
    var close: () -> Void

    private var modeBinding: Binding<String> {
        Binding(get: { settings.prefs.mode == "paged" ? "paged-" + settings.prefs.anim : settings.prefs.mode },
                set: { v in
                    if v.hasPrefix("paged-") { settings.prefs.mode = "paged"; settings.prefs.anim = String(v.dropFirst(6)) } else { settings.prefs.mode = v }
                })
    }

    var body: some View {
        NavigationStack {
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
                }
                Section("الصفحة") {
                    Toggle("التعليقات آخر الفصل", isOn: $settings.prefs.comments)
                    Toggle("أخفِ عنوان الفصل", isOn: $settings.prefs.hideHeading)
                    Picker("أسماء الشخصيات", selection: $settings.prefs.nameStyle) {
                        Text("لون خفيف").tag("tint"); Text("خط تحتها").tag("underline"); Text("غامقة").tag("bold"); Text("متوهّجة").tag("glow"); Text("بدون").tag("off")
                    }
                }
                Section("النص") {
                    NavigationLink("قواعد الاستبدال لهذه الرواية") { ReplaceRulesView(scope: String(novelID), title: "هذه الرواية") }
                    NavigationLink("قواعد الاستبدال لكل الروايات") { ReplaceRulesView(scope: "all", title: "كل الروايات") }
                }
                Section {
                    Toggle("إعدادات متقدمة", isOn: $settings.prefs.advanced)
                    if settings.prefs.advanced {
                        Stepper("فصول تتجهّز قدام: \(settings.prefs.ahead)", value: $settings.prefs.ahead, in: 0...10)
                        Picker("بالعرض", selection: $settings.prefs.landscapeColumns) { Text("عمود واحد").tag(1); Text("عمودين").tag(2) }
                        Toggle("أظهر شريطة الوقفة", isOn: $settings.prefs.showRibbon)
                        SliderRow(title: "سرعة التمرير التلقائي", text: "\(Int(settings.prefs.autoSpeed))", value: $settings.prefs.autoSpeed, range: 8...240, step: 4)
                    }
                } footer: {
                    if settings.prefs.advanced { Text("الفصول الجاية تنحفظ بهدوء وأنت تقرأ، عشان الانتقال لها يكون فوري وتقدر تقرأها بدون نت.") }
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

// MARK: - قواعد الاستبدال

struct ReplaceRulesView: View {
    let scope: String
    let title: String
    @State private var rules: [ReplaceRule] = []

    var body: some View {
        Form {
            Section {
                ForEach($rules) { $r in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField("الكلمة", text: $r.from); Image(systemName: "arrow.left").foregroundStyle(.secondary); TextField("تصير", text: $r.to) }
                        Toggle("ومشتقاتها (وال، بال، لل… والضمائر)", isOn: $r.forms).font(.footnote)
                    }
                }
                .onDelete { rules.remove(atOffsets: $0) }
                Button { rules.append(ReplaceRule()) } label: { Label("قاعدة جديدة", systemImage: "plus") }
            } footer: {
                Text("تتطبّق على النص وقت ما ينفتح الفصل، والفصل المحفوظ ما يتغيّر. الجمع المكسور (مثل آلهة) اكتبه قاعدة لحاله.")
            }
        }
        .navigationTitle("قواعد الاستبدال · " + title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { rules = Replacer.rules(scope) }
        .onDisappear { Replacer.save(rules, scope) }
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

// MARK: - الوقفات والتمييزات

struct MarksSheet: View {
    let title: String
    let labels: [String: String]
    var open: (Int, Int) -> Void
    var deleteMark: (String) -> Void
    var deleteBookmark: (String) -> Void
    @State private var marks: [[String: Any]]
    @State private var bookmarks: [[String: Any]]
    @State private var tab = 0
    @State private var color = ""
    @Environment(\.dismiss) private var dismiss

    init(title: String, marks: [[String: Any]], bookmarks: [[String: Any]], labels: [String: String],
         open: @escaping (Int, Int) -> Void, deleteMark: @escaping (String) -> Void, deleteBookmark: @escaping (String) -> Void) {
        self.title = title
        self.labels = labels
        self.open = open
        self.deleteMark = deleteMark
        self.deleteBookmark = deleteBookmark
        _marks = State(initialValue: marks)
        _bookmarks = State(initialValue: bookmarks)
    }

    private func name(_ c: String) -> String {
        let n = labels[c] ?? ""
        return n.isEmpty ? (MarkBar.colors.first { $0.id == c }?.plain ?? c) : n
    }

    private var shownMarks: [[String: Any]] { color.isEmpty ? marks : marks.filter { ($0["color"] as? String) == color } }
    private var usedColors: [MarkBar.Colour] { MarkBar.colors.filter { c in marks.contains { ($0["color"] as? String) == c.id } } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("", selection: $tab) { Text("التمييزات").tag(0); Text("الوقفات").tag(1) }.pickerStyle(.segmented).padding(.horizontal)
                if tab == 0 {
                    if usedColors.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chip("الكل", nil, color.isEmpty) { color = "" }
                                ForEach(usedColors, id: \.id) { c in chip(name(c.id), c.ui, color == c.id) { color = c.id } }
                            }
                            .padding(.horizontal)
                        }
                    }
                    if shownMarks.isEmpty {
                        empty("ما فيه تمييزات", "حدد نص وأنت تقرأ واختر «تظليل».")
                    } else {
                        List {
                            ForEach(shownMarks.indices, id: \.self) { i in
                                let m = shownMarks[i]
                                Button { open(NovelBridge.num(m["ch"]), NovelBridge.num(m["p"])) } label: { markRow(m) }
                                    .swipeActions {
                                        Button("حذف", role: .destructive) {
                                            let id = m["id"] as? String ?? ""
                                            deleteMark(id)
                                            marks.removeAll { ($0["id"] as? String) == id }
                                        }
                                    }
                            }
                        }
                        .listStyle(.plain)
                    }
                } else {
                    if bookmarks.isEmpty {
                        empty("لا توجد وقفات", "افتح القائمة وأنت تقرأ واضغط زر الوقفة، وترجع لها من هنا.")
                    } else {
                        List {
                            ForEach(bookmarks.indices, id: \.self) { i in
                                let b = bookmarks[i]
                                Button { open(NovelBridge.num(b["ch"]), NovelBridge.num(b["p"])) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text((b["chLabel"] as? String) ?? "").font(.system(size: 15, weight: .semibold))
                                        Text(date(b["at"])).font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                }
                                .swipeActions {
                                    Button("حذف", role: .destructive) {
                                        let id = b["id"] as? String ?? ""
                                        deleteBookmark(id)
                                        bookmarks.removeAll { ($0["id"] as? String) == id }
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, arabicLatn)
        .preferredColorScheme(.dark)
    }

    private func chip(_ t: String, _ c: UIColor?, _ on: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            HStack(spacing: 6) {
                if let c = c { Circle().fill(Color(c)).frame(width: 10, height: 10) }
                Text(t).font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(on ? Color.white.opacity(0.22) : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func markRow(_ m: [String: Any]) -> some View {
        let c = (m["color"] as? String) ?? "yellow"
        let ui = MarkBar.colors.first { $0.id == c }?.ui ?? .systemYellow
        let meta = [name(c), (m["chLabel"] as? String) ?? "", date(m["at"])].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(ui)).frame(width: 4)
            VStack(alignment: .leading, spacing: 5) {
                Text((m["text"] as? String) ?? "").font(.system(size: 15)).lineLimit(4)
                if let n = m["note"] as? String, !n.isEmpty { Text(n).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3) }
                Text(meta).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func empty(_ t: String, _ d: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 60)
            Text(t).font(.system(size: 17, weight: .semibold))
            Text(d).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
        }
    }

    private func date(_ v: Any?) -> String {
        let ms = (v as? Double) ?? Double(NovelBridge.num(v))
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        if Calendar.current.isDateInToday(d) { return "اليوم" }
        let f = DateFormatter()
        f.locale = arabicLatn
        f.dateFormat = "d MMMM"
        return f.string(from: d)
    }
}

// MARK: - بحث في الرواية

struct SearchSheet: View {
    let novel: Novel
    let chapters: [ChapterRow]
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
            .navigationTitle("بحث في الرواية")
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

struct NoteSheet: View {
    let text: String
    var save: (String) -> Void
    @State private var note: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(text: String, note: String, save: @escaping (String) -> Void) {
        self.text = text
        self.save = save
        _note = State(initialValue: note)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("«\(text)»").font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(4)
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
        .preferredColorScheme(.dark)
    }
}

// MARK: - للدفتر: اقتباس، خاطرة، كلمة، شخصية

struct NotebookSheet: View {
    let kind: String
    let characters: [[String: Any]]
    var save: ([String: Any]) -> Void
    @State private var text: String
    @State private var passage: String
    @State private var speaker = ""
    @State private var otherName = ""
    @State private var fav = false
    @State private var word: String
    @State private var meaning = ""
    @State private var translation = ""
    @State private var example: String
    @State private var lookingUp = false
    @State private var role = ""
    @State private var desc = ""
    @Environment(\.dismiss) private var dismiss

    init(kind: String, text: String, sentence: String, characters: [[String: Any]], save: @escaping ([String: Any]) -> Void) {
        self.kind = kind
        self.characters = characters
        self.save = save
        _text = State(initialValue: kind == "thought" ? "" : text)
        _passage = State(initialValue: kind == "thought" ? text : "")
        _word = State(initialValue: text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
        _example = State(initialValue: sentence)
    }

    private var title: String { ["quote": "اقتباس", "thought": "خاطرة", "word": "كلمة", "char": "شخصية"][kind] ?? "" }
    private var canSave: Bool { kind == "word" ? !word.isEmpty : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if kind == "quote" {
                    Section("الاقتباس") { TextEditor(text: $text).frame(minHeight: 110) }
                    Section("القائل") {
                        Picker("من قاله؟", selection: $speaker) {
                            Text("بدون").tag("")
                            ForEach(characters.indices, id: \.self) { i in
                                Text((characters[i]["name"] as? String) ?? "").tag((characters[i]["id"] as? String) ?? "")
                            }
                            Text("اسم آخر").tag("__o")
                        }
                        if speaker == "__o" { TextField("اسم القائل", text: $otherName) }
                    }
                    Section { Toggle("من المفضّلة", isOn: $fav) }
                } else if kind == "thought" {
                    Section("خاطرتك") { TextEditor(text: $text).frame(minHeight: 120) }
                    Section("النص اللي ألهمك") { TextEditor(text: $passage).frame(minHeight: 80).foregroundStyle(.secondary) }
                } else if kind == "word" {
                    Section("الكلمة") {
                        TextField("الكلمة", text: $word)
                        HStack {
                            TextField("المعنى", text: $meaning, axis: .vertical)
                            if lookingUp { ProgressView() }
                        }
                        TextField("الترجمة", text: $translation, axis: .vertical)
                        Button { DeviceDictionary.show(word) } label: { Label("افتح في معجم الجهاز", systemImage: "character.book.closed") }
                    }
                    Section("مثال من النص") { TextEditor(text: $example).frame(minHeight: 70) }
                } else {
                    Section("الشخصية") {
                        TextField("الاسم", text: $text)
                        Picker("نوعها", selection: $role) { Text("غير محدد").tag(""); Text("رئيسية").tag("main"); Text("ثانوية").tag("secondary") }
                        TextField("وصف قصير", text: $desc, axis: .vertical)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("حفظ") { commit() }.disabled(!canSave) }
            }
            .task { if kind == "word" { await lookup() } }
        }
        .environment(\.layoutDirection, Lang.direction)
        .environment(\.locale, arabicLatn)
        .preferredColorScheme(.dark)
    }

    private func lookup() async {
        guard !word.isEmpty else { return }
        lookingUp = true
        let r = await WordLookup.find(word)
        if meaning.isEmpty { meaning = r.meaning }
        if translation.isEmpty { translation = r.translation }
        lookingUp = false
    }

    private func commit() {
        var o: [String: Any] = [:]
        if kind == "quote" {
            o["text"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            o["fav"] = fav
            if speaker == "__o" { o["speakerId"] = "__o"; o["speakerName"] = otherName } else { o["speakerId"] = speaker }
        } else if kind == "thought" {
            o["text"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            o["passage"] = passage
        } else if kind == "word" {
            o["word"] = word
            o["meaning"] = meaning
            o["tr"] = translation
            o["ex"] = example
            o["lang"] = WordLookup.language(of: word)
        } else {
            o["name"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            o["role"] = role
            o["desc"] = desc
        }
        save(o)
        dismiss()
    }
}
