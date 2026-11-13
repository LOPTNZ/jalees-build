import SwiftUI
import UIKit
import CoreText

/// Jalees's own look for native screens: the colours are read from the running web app (so the theme and accent the
/// owner picked carry over), the fonts are the app's (Reem Kufi for titles, IBM Plex Sans Arabic for text).
struct JLook: Equatable {
    var dark = true
    var bg = UIColor(hex: "#0e1614")
    var surface = UIColor(hex: "#16211e")
    var surface2 = UIColor(hex: "#1f2d29")
    var line = UIColor(hex: "#2c3d38")
    var ink = UIColor(hex: "#e5eeea")
    var ink2 = UIColor(hex: "#9db2ab")
    var primary = UIColor(hex: "#5cc2ae")
    var onPrimary = UIColor(hex: "#08201b")
    var danger = UIColor(hex: "#e5786d")
    var star = UIColor(hex: "#f2b84b")
    /// where the web tab bar starts (points from the top); 0 when there is none
    var navTop: CGFloat = 0

    init() {}

    init(_ o: [String: Any]) {
        func c(_ k: String, _ d: UIColor) -> UIColor { (o[k] as? String).flatMap(UIColor.css) ?? d }
        dark = (o["dark"] as? Bool) ?? true
        bg = c("bg", bg); surface = c("surface", surface); surface2 = c("surface2", surface2); line = c("line", line)
        ink = c("ink", ink); ink2 = c("ink2", ink2); primary = c("primary", primary); onPrimary = c("onPrimary", onPrimary)
        danger = c("danger", danger); star = c("star", star)
        navTop = CGFloat((o["navTop"] as? Double) ?? Double((o["navTop"] as? Int) ?? 0))
    }

    static func == (a: JLook, b: JLook) -> Bool {
        a.dark == b.dark && a.bg == b.bg && a.primary == b.primary && a.ink == b.ink && a.navTop == b.navTop
    }
}

extension UIColor {
    /// "#rrggbb", "#rgb", "rgb(r,g,b)" or "rgba(r,g,b,a)" as the web app writes them.
    static func css(_ s: String) -> UIColor? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") {
            var h = String(t.dropFirst())
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6 else { return nil }
            return UIColor(hex: h)
        }
        if t.hasPrefix("rgb") {
            let nums = t.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
                .split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            guard nums.count >= 3 else { return nil }
            return UIColor(red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: nums.count > 3 ? nums[3] : 1)
        }
        return nil
    }

    /// "165 38% 34%" (the web's hsl parts) as a colour.
    static func hslParts(_ s: String) -> UIColor? {
        let p = s.replacingOccurrences(of: "%", with: "").split(separator: " ").compactMap { Double($0) }
        guard p.count >= 3 else { return nil }
        let h = p[0] / 360, sat = p[1] / 100, l = p[2] / 100
        let v = l + sat * min(l, 1 - l)
        let sv = v == 0 ? 0 : 2 * (1 - l / v)
        return UIColor(hue: CGFloat(h), saturation: CGFloat(sv), brightness: CGFloat(v), alpha: 1)
    }
}

/// The app's fonts, registered once at launch from the bundle.
enum JFont {
    static func register() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
        for u in urls where !u.lastPathComponent.lowercased().hasPrefix("thmanyah") {
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
        }
    }

    /// Titles (Reem Kufi), like the web's --f-display.
    static func display(_ size: CGFloat, _ weight: UIFont.Weight = .semibold) -> Font {
        let d = UIFontDescriptor(fontAttributes: [.family: "Reem Kufi", .traits: [UIFontDescriptor.TraitKey.weight: weight]])
        let f = UIFont(descriptor: d, size: size)
        return f.familyName == "Reem Kufi" ? Font(f as CTFont) : .system(size: size, weight: Font.Weight(weight))
    }

    /// Body text (IBM Plex Sans Arabic), like the web's --f-body.
    static func body(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "IBMPlexSansArabic-Bold"
        case .semibold: name = "IBMPlexSansArabic-SemiBold"
        case .medium: name = "IBMPlexSansArabic-Medium"
        default: name = "IBMPlexSansArabic-Regular"
        }
        if let f = UIFont(name: name, size: size) { return Font(f as CTFont) }
        return .system(size: size, weight: Font.Weight(weight))
    }
}

extension Font.Weight {
    init(_ w: UIFont.Weight) {
        switch w {
        case .bold, .heavy, .black: self = .bold
        case .semibold: self = .semibold
        case .medium: self = .medium
        case .light, .thin, .ultraLight: self = .light
        default: self = .regular
        }
    }
}

// MARK: - pieces that look like the web app's

/// .btn / .btn.primary
struct JButtonStyle: ButtonStyle {
    let look: JLook
    var primary = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(JFont.body(small ? 14 : 16, .medium))
            .foregroundStyle(Color(primary ? look.onPrimary : look.ink))
            .padding(.horizontal, small ? 12 : 16)
            .frame(minHeight: small ? 36 : 48)
            .background(RoundedRectangle(cornerRadius: small ? 10 : 14, style: .continuous).fill(Color(primary ? look.primary : look.surface)))
            .overlay(RoundedRectangle(cornerRadius: small ? 10 : 14, style: .continuous).strokeBorder(Color(primary ? look.primary : look.line), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// .cbtn: a round icon button
struct JCircle: View {
    let look: JLook
    let symbol: String
    var on = false
    var size: CGFloat = 36
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(Color(on ? look.onPrimary : look.ink))
                .frame(width: size, height: size)
                .background(Circle().fill(Color(on ? look.primary : look.surface)))
                .overlay(Circle().strokeBorder(Color(on ? look.primary : look.line), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// .chip
struct JChip: View {
    let look: JLook
    let text: String
    var count: Int? = nil
    var dot: UIColor? = nil
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let d = dot { Circle().fill(Color(d)).frame(width: 9, height: 9) }
                Text(text).font(JFont.body(14, on ? .medium : .regular))
                if let c = count { Text("\(c)").font(JFont.body(13)).opacity(0.7).monospacedDigit() }
            }
            .foregroundStyle(Color(on ? look.onPrimary : look.ink))
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(on ? Color(look.primary) : Color.clear))
            .overlay(Capsule().strokeBorder(Color(on ? look.primary : look.line), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// .mchip
struct JMeta: View {
    let look: JLook
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let s = symbol { Image(systemName: s).font(.system(size: 11)) }
            Text(text).font(JFont.body(12.5))
        }
        .foregroundStyle(Color(look.ink))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(look.surface2)))
    }
}

/// A section heading like the web's h2 with an optional count.
struct JHeading: View {
    let look: JLook
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(JFont.display(20, .semibold)).foregroundStyle(Color(look.ink))
            if let c = count, c > 0 { Text("\(c)").font(JFont.body(14, .medium)).foregroundStyle(Color(look.ink2)).monospacedDigit() }
        }
    }
}

/// A simple flowing row of views (chips that wrap to the next line).
struct Flow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > w { x = 0; y += row + spacing; row = 0 }
            x += z.width + spacing
            row = max(row, z.height)
        }
        return CGSize(width: w, height: y + row)
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > b.width { x = 0; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: b.minX + x, y: b.minY + y), proposal: ProposedViewSize(z))
            x += z.width + spacing
            row = max(row, z.height)
        }
    }
}
