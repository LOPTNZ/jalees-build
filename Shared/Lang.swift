import Foundation
import SwiftUI

/// The English interface (v2 «واجهة إنجليزية كاملة»). The app is written in Arabic; when English is chosen, every
/// piece of interface text is looked up in en.json at the moment it is shown, so nothing stored changes (books, notes,
/// novel and site names stay as they are). A key with {} matches any text in that place (what the code put there,
/// like a number or a name), and the English puts it back where its {} (or {1}, {2}…) is.
enum Lang {
    private static let lock = NSLock()
    private static var on: Bool = readChoice()
    private static var cache: [String: String] = [:]
    private static var table: [String: String] = [:]
    private static var patterns: [(NSRegularExpression, String)] = []
    private static var loaded = false

    static var english: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }

    /// The choice lives in the shared container, so the widgets and the share sheet follow it.
    private static var choiceFile: URL? { SharedGroup.container?.appendingPathComponent("lang.txt") }

    private static func readChoice() -> Bool {
        if let f = choiceFile, let s = try? String(contentsOf: f, encoding: .utf8) { return s.trimmingCharacters(in: .whitespacesAndNewlines) == "en" }
        return UserDefaults.standard.string(forKey: "jalees.lang") == "en"
    }

    static func set(english: Bool) {
        let v = english ? "en" : "ar"
        UserDefaults.standard.set(v, forKey: "jalees.lang")
        // the system's own pieces (pickers, the share sheet) follow from the next launch
        UserDefaults.standard.set([v], forKey: "AppleLanguages")
        if let f = choiceFile { try? v.write(to: f, atomically: true, encoding: .utf8) }
        lock.lock()
        on = english
        cache = [:]
        lock.unlock()
    }

    /// Re-reads the choice (an extension starting, or the app coming back after the widget changed nothing).
    static func refresh() {
        let v = readChoice()
        lock.lock()
        if v != on { on = v; cache = [:] }
        lock.unlock()
    }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let u = Bundle.main.url(forResource: "en", withExtension: "json"),
              let d = try? Data(contentsOf: u),
              let t = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return }
        table = t.filter { !$0.value.isEmpty }
        // the keys with {} in them, longest first (the most particular one wins)
        for (k, v) in table.sorted(by: { $0.key.count > $1.key.count }) where k.contains("{}") {
            let parts = k.components(separatedBy: "{}").map { NSRegularExpression.escapedPattern(for: $0) }
            if let re = try? NSRegularExpression(pattern: "^" + parts.joined(separator: "(.+?)") + "$", options: [.dotMatchesLineSeparators]) {
                patterns.append((re, v))
            }
        }
    }

    /// The interface text in the chosen language.
    static func tr(_ s: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard on, !s.isEmpty, s.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) else { return s }
        if let c = cache[s] { return c }
        load()
        let out = look(s, depth: 0) ?? s
        if cache.count > 4_000 { cache = [:] }
        cache[s] = out
        return out
    }

    private static func look(_ s: String, depth: Int) -> String? {
        if let v = table[s] { return v }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != s, let v = table[t] { return s.replacingOccurrences(of: t, with: v) }
        guard depth < 3 else { return nil }
        let ns = s as NSString
        for (re, en) in patterns {
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            var parts: [String] = []
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                let p = r.location == NSNotFound ? "" : ns.substring(with: r)
                // what was put in may be interface text too («صفحات» in «{} في الساعة»)
                parts.append(look(p, depth: depth + 1) ?? p)
            }
            return fill(en, parts)
        }
        return nil
    }

    private static func fill(_ en: String, _ parts: [String]) -> String {
        var out = en
        // numbered places first ({2} before {1} so the English can change the order), then plain {} in turn
        for (i, p) in parts.enumerated().reversed() where out.contains("{\(i + 1)}") {
            out = out.replacingOccurrences(of: "{\(i + 1)}", with: p)
        }
        var i = 0
        while let r = out.range(of: "{}") {
            out.replaceSubrange(r, with: i < parts.count ? parts[i] : "")
            i += 1
        }
        return out
    }

    /// Which way the interface reads.
    static var direction: LayoutDirection { english ? .leftToRight : .rightToLeft }
    /// Dates and numbers: always Western digits, the Gregorian calendar.
    static var locale: Locale { Locale(identifier: english ? "en_US" : "ar@numbers=latn") }
}

extension String {
    /// This interface text in the chosen language.
    var tr: String { Lang.tr(self) }
}

// SwiftUI's views that take a title: a String title goes through Lang.tr. (A non-generic String overload is chosen
// over SwiftUI's own for both string variables and literals.)

extension Text {
    init(_ s: String) { self.init(verbatim: Lang.tr(s)) }
}

extension Button where Label == Text {
    init(_ title: String, action: @escaping () -> Void) { self.init(action: action) { Text(title) } }
    init(_ title: String, role: ButtonRole?, action: @escaping () -> Void) { self.init(role: role, action: action) { Text(title) } }
}

extension SwiftUI.Label where Title == Text, Icon == Image {
    init(_ title: String, systemImage: String) { self.init { Text(title) } icon: { Image(systemName: systemImage) } }
}

extension Toggle where Label == Text {
    init(_ title: String, isOn: Binding<Bool>) { self.init(isOn: isOn) { Text(title) } }
}

extension TextField where Label == Text {
    init(_ title: String, text: Binding<String>) { self.init(text: text, prompt: Text(title)) { Text(title) } }
    init(_ title: String, text: Binding<String>, axis: Axis) { self.init(text: text, prompt: Text(title), axis: axis) { Text(title) } }
}

extension SecureField where Label == Text {
    init(_ title: String, text: Binding<String>) { self.init(text: text, prompt: Text(title)) { Text(title) } }
}

extension Section where Parent == Text, Content: View, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(content: content, header: { Text(title) }) }
}

extension Picker where Label == Text {
    init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(title) }
    }
}

extension View {
    func navigationTitle(_ title: String) -> some View { navigationTitle(Text(title)) }

    func alert<A: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A) -> some View {
        alert(Text(title), isPresented: isPresented, actions: actions)
    }

    func alert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View {
        alert(Text(title), isPresented: isPresented, actions: actions, message: message)
    }

    func confirmationDialog<A: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: () -> A) -> some View {
        confirmationDialog(Text(title), isPresented: isPresented, titleVisibility: titleVisibility, actions: actions)
    }

    func confirmationDialog<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View {
        confirmationDialog(Text(title), isPresented: isPresented, titleVisibility: titleVisibility, actions: actions, message: message)
    }

    func accessibilityLabel(_ s: String) -> some View { accessibilityLabel(Text(s)) }
    func accessibilityHint(_ s: String) -> some View { accessibilityHint(Text(s)) }
}
