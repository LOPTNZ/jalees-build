import SwiftUI
import UIKit

/// Jalees's colours and type, from the web app's stylesheet (docs/plan/swift/inventory-3-settings-shell.md, 7):
/// a light and a dark set, the accent the owner picked (teal, indigo, plum, amber) and the text size (s, m, l).
enum Theme {
    /// [primary, bar-lo, on-primary] for light and for dark
    private static let accents: [String: (light: [String], dark: [String])] = [
        "teal": (["#1c5a50", "#8fb8af", "#f4faf8"], ["#5cc2ae", "#2f6b5f", "#08201b"]),
        "indigo": (["#33449a", "#a6afdc", "#f5f6fd"], ["#93a1f2", "#3c4785", "#0c0f2c"]),
        "plum": (["#7a2e5c", "#d3a0bd", "#fdf4f8"], ["#e48dbf", "#6f3557", "#2a0b1c"]),
        "amber": (["#8f520c", "#e3be86", "#fff8ee"], ["#f2b259", "#7a5426", "#2a1a05"])
    ]
    static let accentNames: [(String, String)] = [("teal", "زمردي"), ("indigo", "نيلي"), ("plum", "برقوقي"), ("amber", "كهرماني")]

    /// "system" follows the phone; "light" and "dark" are fixed.
    static func isDark(_ s: Settings, system: Bool) -> Bool {
        switch s.theme { case "light": return false; case "dark": return true; default: return system }
    }

    static func look(_ s: Settings, systemDark: Bool) -> JLook {
        let dark = isDark(s, system: systemDark)
        var l = JLook()
        l.dark = dark
        func c(_ x: String) -> UIColor { UIColor(hex: x) }
        if dark {
            l.bg = c("#0e1614"); l.surface = c("#16211e"); l.surface2 = c("#1f2d29"); l.line = c("#2c3d38")
            l.ink = c("#e5eeea"); l.ink2 = c("#9db2ab"); l.accent = c("#f0ae48"); l.accentInk = c("#f3c06f")
            l.accentSoft = c("#3a2c12"); l.danger = c("#ff8a80"); l.star = c("#f2b83a"); l.stage = c("#070c0b")
        } else {
            l.bg = c("#e9efec"); l.surface = c("#f8faf9"); l.surface2 = c("#dbe5e1"); l.line = c("#c6d4cf")
            l.ink = c("#13231f"); l.ink2 = c("#4b5f59"); l.accent = c("#d98b1c"); l.accentInk = c("#85500a")
            l.accentSoft = c("#f6e3c0"); l.danger = c("#b3261e"); l.star = c("#e0a526"); l.stage = c("#17211f")
        }
        l.stageInk = c("#eef3f1")
        let a = accents[s.accent] ?? accents["teal"]!
        let set = dark ? a.dark : a.light
        l.primary = c(set[0]); l.barLo = c(set[1]); l.onPrimary = c(set[2])
        l.fs = ["s": 14, "l": 16.5][s.fs] ?? 15
        return l
    }
}

extension JFont {
    /// Quotes, reviews and passages (Amiri), like the web's --f-quote.
    static func quote(_ size: CGFloat, bold: Bool = false) -> Font {
        if let f = UIFont(name: bold ? "Amiri-Bold" : "Amiri-Regular", size: size) { return Font(f as CTFont) }
        return .system(size: size, weight: bold ? .bold : .regular, design: .serif)
    }
}

/// The look, handed down to every screen.
private struct LookKey: EnvironmentKey { static let defaultValue = JLook() }
extension EnvironmentValues {
    var look: JLook {
        get { self[LookKey.self] }
        set { self[LookKey.self] = newValue }
    }
}
