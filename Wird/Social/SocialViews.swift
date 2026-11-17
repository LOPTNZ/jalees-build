import SwiftUI
import PhotosUI
import UIKit

// «الأصدقاء»: the screens. They live as the third part of «إنجازاتي» (ProgressTab: الأهداف · الإحصائيات · الأصدقاء),
// so a profile and a friends' feed sit with the reader's own numbers. Sheets open from there; a book's page has one
// switch (SocialBookRow) to keep a book from friends. Everything else happens by itself (SocialStore).

enum SocialShare {
    /// the iPhone share sheet for the invite link
    @MainActor static func link(_ url: URL) {
        guard let h = NovelBridge.host else { return }
        let vc = UIActivityViewController(activityItems: ["تعال نقرأ مع بعض في جليس", url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = h.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: h.view.bounds.midX, y: h.view.bounds.maxY - 80, width: 1, height: 1)
        NovelBridge.top(h).present(vc, animated: true)
    }
}

private enum SocialSheet: Identifiable {
    case edit, settings, add, quote
    case profile(String)
    var id: String {
        switch self {
        case .edit: return "edit"
        case .settings: return "settings"
        case .add: return "add"
        case .quote: return "quote"
        case .profile(let u): return "p:" + u
        }
    }
}

private func ago(_ ms: Double) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: Lang.english ? "en" : "ar-u-nu-latn")
    f.unitsStyle = .short
    return f.localizedString(for: Millis.date(ms), relativeTo: Date())
}

private func hueOf(_ s: String) -> Double {
    var h = 7
    for u in s.unicodeScalars { h = (h &* 31 &+ Int(u.value)) % 360 }
    return Double(h) / 360
}

// MARK: - small pieces

/// A person's picture: their photo when they have one (fetched with the token), else a coloured letter.
struct SocialAvatar: View {
    let user: SocialUser
    var size: CGFloat = 44
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            if let i = img {
                Image(uiImage: i).resizable().scaledToFill()
            } else {
                Color(hue: hueOf(user.username), saturation: 0.35, brightness: 0.62)
                Text(String(user.name.first ?? user.username.first ?? "؟")).font(JFont.display(size * 0.45, .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: "\(user.username)|\(user.av)") { img = await SocialStore.shared.avatar(user) }
    }
}

/// A book drawn from its title when a friend's cover isn't known (covers are never uploaded).
private struct SocialCover: View {
    let book: SocialBookRef
    var width: CGFloat = 56
    var body: some View {
        let h = book.hue.map { $0 / 360 } ?? hueOf(book.title)
        ZStack {
            LinearGradient(colors: [Color(hue: h, saturation: 0.45, brightness: 0.6), Color(hue: h, saturation: 0.5, brightness: 0.4)], startPoint: .top, endPoint: .bottom)
            Text(book.title).font(JFont.display(width * 0.2, .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
                .lineLimit(4).minimumScaleFactor(0.6).padding(5)
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct SocialField: View {
    let label: String
    @Binding var text: String
    var secure = false
    var placeholder = ""
    var latin = false
    @Environment(\.look) private var L

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            JLabel(text: label)
            Group {
                if secure { SecureField(placeholder, text: $text) }
                else { TextField(placeholder, text: $text) }
            }
            .textInputAutocapitalization(latin ? .never : .sentences)
            .autocorrectionDisabled(latin)
            .keyboardType(latin ? .asciiCapable : .default)
            .font(JFont.body(16)).foregroundStyle(Color(L.ink))
            .padding(.horizontal, 12).frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface2)))
        }
    }
}

private struct StarsText: View {
    let r: Double
    @Environment(\.look) private var L
    var body: some View { Text(Words.stars(r)).font(JFont.body(14)).foregroundStyle(Color(L.star)) }
}

// MARK: - the page inside «إنجازاتي»

struct FriendsHome: View {
    @ObservedObject private var S = SocialStore.shared
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var part = "feed"
    @State private var sheet: SocialSheet?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if S.signedIn { signedIn } else { SocialSignIn() }
        }
        .sheet(item: $sheet) { s in
            sheetView(s).environment(\.look, L).environment(\.layoutDirection, Lang.direction)
        }
        .alert("ربط جليس بسيرفر الأصدقاء؟", isPresented: Binding(get: { S.pendingJoin != nil }, set: { if !$0 { S.pendingJoin = nil } })) {
            Button("اتصل") { if let l = S.pendingJoin { Task { await S.acceptJoin(l) } } }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("وصلتك دعوة صداقة من السيرفر \(URL(string: S.pendingJoin?.server ?? "")?.host ?? ""). لا توافق إلا إذا كنت تعرف من أرسلها.")
        }
        .task { await S.refreshAll() }
    }

    @ViewBuilder private func sheetView(_ s: SocialSheet) -> some View {
        switch s {
        case .edit: ProfileEditSheet()
        case .settings: SocialSettingsSheet()
        case .add: AddFriendSheet()
        case .quote: ShareQuoteSheet()
        case .profile(let u): FriendProfileSheet(username: u)
        }
    }

    // MARK: signed in

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(spacing: 10) {
                Button { Task { await invite() } } label: { Label("دعوة صديق", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(JButtonStyle(look: L, primary: true)).disabled(busy)
                Button { sheet = .add } label: { Label("أضف صديقًا", systemImage: "person.badge.plus").frame(maxWidth: .infinity) }
                    .buttonStyle(JButtonStyle(look: L))
            }
            if S.pending > 0 {
                Text("في الانتظار للإرسال: \(S.pending). يُرسل وحده عند توفر الاتصال.").font(JFont.body(13)).foregroundStyle(Color(L.ink2))
            }
            if !S.incoming.isEmpty { requests }
            JSeg(options: [("feed", "النشاط"), ("friends", "الأصدقاء")], value: $part)
            if part == "feed" { feed } else { friendsList }
        }
    }

    private var header: some View {
        let u = S.me?.user ?? SocialUser(["username": S.username, "name": S.username])
        return JPanel {
            HStack(spacing: 14) {
                SocialAvatar(user: u, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(u.name).font(JFont.display(21, .bold)).foregroundStyle(Color(L.ink)).lineLimit(1)
                    Text("@" + u.username).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
                }
                Spacer(minLength: 0)
                JCircle(look: L, symbol: "gearshape", label: "إعدادات الأصدقاء") { sheet = .settings }
            }
            if let b = S.me?.bio, !b.isEmpty { Text(b).font(JFont.body(15)).foregroundStyle(Color(L.ink)).lineSpacing(4) }
            let st = lib.state
            HStack(spacing: 8) {
                JMeta(look: L, text: "\(st.finishedThisYear) هذه السنة", symbol: "books.vertical")
                if st.streak.cur > 0 { JMeta(look: L, text: "\(st.streak.cur) يوم متتالي", symbol: "flame") }
            }
            HStack(spacing: 10) {
                Button { sheet = .edit } label: { Label("تعديل ملفي", systemImage: "pencil").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, small: true))
                Button { sheet = .profile(u.username) } label: { Label("صفحتي كما يراها أصدقائي", systemImage: "eye").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, small: true))
            }
            Button { sheet = .quote } label: { Label("شارك اقتباسًا مع أصدقائك", systemImage: "quote.opening").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, small: true))
        }
    }

    private func invite() async {
        busy = true
        defer { busy = false }
        do { SocialShare.link(try await S.inviteLink()) }
        catch let e as SocialError { ToastCenter.shared.show(e.message) } catch {}
    }

    private var requests: some View {
        JPanel {
            Text("طلبات الصداقة").font(JFont.display(17, .semibold)).foregroundStyle(Color(L.ink))
            ForEach(S.incoming) { u in
                HStack(spacing: 10) {
                    SocialAvatar(user: u, size: 38)
                    Button { sheet = .profile(u.username) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(u.name).font(JFont.body(15, .medium)).foregroundStyle(Color(L.ink))
                            Text("@" + u.username).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
                        }
                    }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button("قبول") { Task { try? await S.act("accept", u.username) } }.buttonStyle(JButtonStyle(look: L, primary: true, small: true))
                    Button("رفض") { Task { try? await S.act("decline", u.username) } }.buttonStyle(JButtonStyle(look: L, small: true))
                }
            }
        }
    }

    // MARK: the feed

    @ViewBuilder private var feed: some View {
        if S.feed.isEmpty {
            Text(S.friends.isEmpty ? "ما عندك أصدقاء بعد. أرسل دعوة لتشوفوا ما تقرؤون." : "ما فيه نشاط بعد. يظهر هنا ما يبدؤونه ويُنهونه ويقيّمونه.")
                .font(JFont.body(15)).foregroundStyle(Color(L.ink2)).padding(.vertical, 20)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(S.feed) { it in
                    FeedRow(item: it) { sheet = .profile(it.user.username) }
                        .onAppear { if it.id == S.feed.last?.id { Task { await S.loadMoreFeed() } } }
                }
            }
        }
    }

    private var friendsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if S.friends.isEmpty { Text("لا أصدقاء بعد.").font(JFont.body(15)).foregroundStyle(Color(L.ink2)).padding(.vertical, 20) }
            ForEach(S.friends) { u in
                Button { sheet = .profile(u.username) } label: {
                    HStack(spacing: 12) {
                        SocialAvatar(user: u, size: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(u.name).font(JFont.body(16, .medium)).foregroundStyle(Color(L.ink))
                            Text("@" + u.username).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(L.ink2))
                    }
                    .frame(minHeight: 60).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
            }
            if !S.outgoing.isEmpty {
                JLabel(text: "طلبات أرسلتها").padding(.top, 16)
                ForEach(S.outgoing) { u in
                    HStack {
                        SocialAvatar(user: u, size: 36)
                        Text("@" + u.username).font(JFont.body(15)).foregroundStyle(Color(L.ink))
                        Spacer()
                        Button("إلغاء") { Task { try? await S.act("cancel", u.username) } }.buttonStyle(JButtonStyle(look: L, small: true))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - a line of the feed

private struct FeedRow: View {
    let item: SocialFeedItem
    let open: () -> Void
    @Environment(\.look) private var L

    private var verb: String {
        switch item.type {
        case "started": return "بدأ قراءة"
        case "finished": return "أنهى"
        case "rated": return "قيّم"
        case "reviewed": return "كتب مراجعة عن"
        default: return "شارك اقتباسًا من"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: open) { SocialAvatar(user: item.user, size: 42) }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 5) {
                (Text(item.mine ? "أنت" : item.user.name).font(JFont.body(15, .semibold)) + Text(" " + verb + " ").font(JFont.body(15)) + Text("«" + item.book.title + "»").font(JFont.body(15, .semibold)))
                    .foregroundStyle(Color(L.ink)).fixedSize(horizontal: false, vertical: true)
                if item.rating > 0 && item.type != "quote" { StarsText(r: item.rating) }
                if !item.text.isEmpty {
                    Text(item.text).font(item.type == "quote" ? JFont.quote(16) : JFont.body(15)).foregroundStyle(Color(L.ink)).lineSpacing(4)
                        .spoiler(item.spoiler)
                }
                Text(ago(item.at)).font(JFont.body(12)).foregroundStyle(Color(L.ink2))
            }
            Spacer(minLength: 0)
            SocialCover(book: item.book, width: 40)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(L.line)).frame(height: 1) }
    }
}

// MARK: - sign up and in

private struct SocialSignIn: View {
    @ObservedObject private var S = SocialStore.shared
    @Environment(\.look) private var L
    @State private var mode = "in"
    @State private var server = ""
    @State private var username = ""
    @State private var name = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("الأصدقاء").font(JFont.display(22, .bold)).foregroundStyle(Color(L.ink))
            SettingsNote("شوف ما يقرأه أصدقاؤك وتقييماتهم، واعرض لهم ما تقرؤه أنت. لا يُرفع أي ملف: فقط عنوان الكتاب والمؤلف وحالته وتقييمك ومراجعتك وما تختار مشاركته، وكل كتاب تقدر تخفيه.")
            if !invite.isEmpty {
                Label("معك دعوة صديق: أنشئ حسابك وتصيرون أصدقاء مباشرة.", systemImage: "person.2").font(JFont.body(14.5, .medium)).foregroundStyle(Color(L.accentInk))
            }
            JSeg(options: [("in", "دخول"), ("up", "حساب جديد")], value: $mode)
            if SocialServer.defaultURL.isEmpty || server.isEmpty {
                SocialField(label: "عنوان سيرفر الأصدقاء", text: $server, placeholder: "https://jalees.example.com", latin: true)
            }
            SocialField(label: "اسم المستخدم", text: $username, placeholder: "abdullah", latin: true)
            if mode == "up" { SocialField(label: "الاسم الظاهر", text: $name, placeholder: "عبدالله") }
            SocialField(label: "كلمة السر", text: $password, secure: true, latin: true)
            if mode == "up" && invite.isEmpty { SocialField(label: "رمز الدعوة (إن كان عندك)", text: $invite, latin: true) }
            if !error.isEmpty { Text(error).font(JFont.body(14)).foregroundStyle(Color(L.danger)) }
            Button { Task { await go() } } label: { Text(busy ? "لحظة…" : (mode == "up" ? "إنشاء الحساب" : "دخول")).frame(maxWidth: .infinity) }
                .buttonStyle(JButtonStyle(look: L, primary: true)).disabled(busy || username.isEmpty || password.isEmpty)
        }
        .task(id: S.waitingInvite) {
            server = S.server
            if !S.waitingInvite.isEmpty { invite = S.waitingInvite; mode = "up" }
        }
        .onAppear { if server.isEmpty { server = S.server } }
    }

    private func go() async {
        busy = true; error = ""
        defer { busy = false }
        do {
            if mode == "up" { try await S.signUp(server: server, username: username, name: name, password: password, invite: invite) }
            else { try await S.signIn(server: server, username: username, password: password, invite: invite) }
            S.clearWaitingInvite()
            password = ""
        } catch let e as SocialError { error = e.message } catch { error = "تعذّر الطلب." }
    }
}

// MARK: - someone's page (a friend's, or mine as friends see it)

private struct FriendProfileSheet: View {
    let username: String
    @ObservedObject private var S = SocialStore.shared
    @Environment(\.look) private var L
    @Environment(\.dismiss) private var dismiss
    @State private var p: SocialProfile?
    @State private var failed = ""
    @State private var askBlock = false

    var body: some View {
        JSheet(title: p?.user.name ?? "@" + username) {
            if let p = p { content(p) }
            else if !failed.isEmpty { Text(failed).font(JFont.body(15)).foregroundStyle(Color(L.ink2)) }
            else { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
        }
        .task { await load() }
        .confirmationDialog("حظر @\(username)؟", isPresented: $askBlock, titleVisibility: .visible) {
            Button("حظر", role: .destructive) { Task { try? await S.act("block", username); dismiss() } }
            Button("إلغاء", role: .cancel) {}
        } message: { Text("لا يرى كلٌّ منكما الآخر، وتنتهي الصداقة.") }
    }

    private func load() async {
        do { p = try await S.profile(username) }
        catch let e as SocialError { failed = e.message } catch { failed = "تعذّر التحميل." }
    }

    private func act(_ what: String) { Task { try? await S.act(what, username); await load() } }

    @ViewBuilder private func content(_ p: SocialProfile) -> some View {
        HStack(spacing: 14) {
            SocialAvatar(user: p.user, size: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.user.name).font(JFont.display(22, .bold)).foregroundStyle(Color(L.ink))
                Text("@" + p.user.username).font(JFont.body(14)).foregroundStyle(Color(L.ink2))
            }
            Spacer(minLength: 0)
        }
        if !p.bio.isEmpty { Text(p.bio).font(JFont.body(15)).foregroundStyle(Color(L.ink)).lineSpacing(4) }
        relation(p)
        if !p.visible {
            Text("صفحة القراءة تظهر لأصدقاء هذا الحساب فقط.").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
        } else if p.hidden {
            Text("أوقف قراءته عن الأصدقاء.").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
        } else {
            reading(p)
        }
    }

    @ViewBuilder private func relation(_ p: SocialProfile) -> some View {
        switch p.relation {
        case "none": Button { act("request") } label: { Label("أضف صديقًا", systemImage: "person.badge.plus").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
        case "outgoing": Button { act("cancel") } label: { Text("إلغاء الطلب").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
        case "incoming":
            HStack {
                Button { act("accept") } label: { Text("قبول").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, primary: true))
                Button { act("decline") } label: { Text("رفض").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
            }
        case "friend":
            HStack {
                Button { act("remove") } label: { Text("إزالة من الأصدقاء").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, small: true))
                Button { askBlock = true } label: { Text("حظر").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L, small: true))
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private func reading(_ p: SocialProfile) -> some View {
        if let s = p.stats {
            JPanel {
                HStack {
                    stat(s["booksYear"] ?? 0, "هذه السنة")
                    stat(s["streak"] ?? 0, "يوم متتالي")
                    stat((s["minutes"] ?? 0) / 60, "ساعة قراءة")
                    stat(s["pages"] ?? 0, "صفحة")
                }
            }
        }
        if !p.favs.isEmpty { shelf("المفضّلة", p.favs) }
        if !p.reading.isEmpty { shelf("يقرأ الآن", p.reading) }
        if !p.finished.isEmpty { shelf("أنهاها", p.finished) }
        if p.ratings.contains(where: { $0 > 0 }) { histogram(p.ratings) }
        if !p.reviews.isEmpty {
            Text("المراجعات").font(JFont.display(18, .semibold)).foregroundStyle(Color(L.ink))
            ForEach(p.reviews) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("«" + r.title + "»").font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink)); Spacer(); if r.rating > 0 { StarsText(r: r.rating) } }
                    Text(r.text).font(JFont.body(15)).foregroundStyle(Color(L.ink)).lineSpacing(4).spoiler(r.spoiler)
                }
                .padding(.vertical, 6)
            }
        }
        ForEach(p.lists.indices, id: \.self) { i in
            VStack(alignment: .leading, spacing: 4) {
                Text(p.lists[i].name).font(JFont.display(16, .semibold)).foregroundStyle(Color(L.ink))
                Text(p.lists[i].books.map(\.title).joined(separator: " · ")).font(JFont.body(14)).foregroundStyle(Color(L.ink2)).lineSpacing(3)
            }
        }
        if !p.activity.isEmpty {
            Text("آخر النشاط").font(JFont.display(18, .semibold)).foregroundStyle(Color(L.ink))
            ForEach(p.activity) { a in FeedRow(item: a) {} }
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(JFont.display(20, .bold)).foregroundStyle(Color(L.ink)).monospacedDigit()
            Text(label).font(JFont.body(11.5)).foregroundStyle(Color(L.ink2)).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }

    private func shelf(_ title: String, _ books: [SocialBookRef]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(JFont.display(18, .semibold)).foregroundStyle(Color(L.ink))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(books) { b in
                        VStack(alignment: .leading, spacing: 4) {
                            SocialCover(book: b, width: 76)
                            if b.rating > 0 { StarsText(r: b.rating) }
                        }
                    }
                }
            }
        }
    }

    private func histogram(_ r: [Int]) -> some View {
        let top = Double(max(1, r.max() ?? 1))
        return VStack(alignment: .leading, spacing: 8) {
            Text("توزيع التقييمات").font(JFont.display(18, .semibold)).foregroundStyle(Color(L.ink))
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(r.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(Color(L.primary)).frame(height: max(3, 56 * Double(r[i]) / top)).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 58, alignment: .bottom)
            HStack { Text("½★").font(JFont.body(12)); Spacer(); Text("5★").font(JFont.body(12)) }.foregroundStyle(Color(L.ink2))
        }
    }
}

// MARK: - add a friend

private struct AddFriendSheet: View {
    @ObservedObject private var S = SocialStore.shared
    @Environment(\.look) private var L
    @State private var username = ""
    @State private var code = ""
    @State private var note = ""

    var body: some View {
        JSheet(title: "أضف صديقًا") {
            SocialField(label: "اسم المستخدم", text: $username, placeholder: "friend_name", latin: true)
            Button("أرسل الطلب") {
                Task {
                    do { try await S.request(username); note = "أُرسل الطلب إلى @\(username)"; username = "" }
                    catch let e as SocialError { note = e.message } catch {}
                }
            }.buttonStyle(JButtonStyle(look: L, primary: true)).disabled(username.isEmpty)
            Divider()
            SocialField(label: "أو رمز دعوة وصلك", text: $code, latin: true)
            Button("استخدم الرمز") {
                Task {
                    do { let f = try await S.redeem(code); note = "صرت صديق \(f.name)"; code = "" }
                    catch let e as SocialError { note = e.message } catch {}
                }
            }.buttonStyle(JButtonStyle(look: L)).disabled(code.isEmpty)
            if !note.isEmpty { Text(note).font(JFont.body(14.5)).foregroundStyle(Color(L.ink2)) }
        }
    }
}

// MARK: - my profile

private struct ProfileEditSheet: View {
    @ObservedObject private var S = SocialStore.shared
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bio = ""
    @State private var favs: [(String, String)] = []
    @State private var picked: PhotosPickerItem?
    @State private var error = ""
    @State private var loaded = false

    var body: some View {
        JSheet(title: "ملفي", action: (label: "حفظ", run: { Task { await save() } })) {
            if let u = S.me?.user {
                HStack(spacing: 14) {
                    SocialAvatar(user: u, size: 72)
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $picked, matching: .images) { Label("صورة", systemImage: "photo") }.buttonStyle(JButtonStyle(look: L, small: true))
                        if u.av > 0 { Button("إزالة الصورة") { Task { await S.removeAvatar() } }.font(JFont.body(13.5)).foregroundStyle(Color(L.danger)) }
                    }
                }
            }
            SocialField(label: "الاسم الظاهر", text: $name)
            VStack(alignment: .leading, spacing: 6) {
                JLabel(text: "نبذة")
                TextField("", text: $bio, axis: .vertical).lineLimit(2...5).font(JFont.body(16)).foregroundStyle(Color(L.ink))
                    .padding(12).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface2)))
            }
            VStack(alignment: .leading, spacing: 8) {
                JLabel(text: "كتبي المفضلة (حتى 4)")
                ForEach(favs.indices, id: \.self) { i in
                    HStack {
                        Text(favs[i].0).font(JFont.body(15)).foregroundStyle(Color(L.ink)).lineLimit(1)
                        Spacer()
                        Button { favs.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(L.ink2)) }.buttonStyle(.plain)
                    }
                }
                if favs.count < 4 {
                    Menu {
                        ForEach(lib.state.books.filter { b in !b.title.isEmpty && !favs.contains { $0.0 == b.title } }.prefix(80)) { b in
                            Button(b.title) { favs.append((b.title, b.author)) }
                        }
                    } label: { Label("أضف من مكتبتي", systemImage: "plus") }.buttonStyle(JButtonStyle(look: L, small: true))
                }
            }
            if !error.isEmpty { Text(error).font(JFont.body(14)).foregroundStyle(Color(L.danger)) }
        }
        .onAppear {
            guard !loaded, let m = S.me else { return }
            loaded = true
            name = m.user.name; bio = m.bio; favs = m.favs.map { ($0.title, $0.author) }
        }
        .onChange(of: picked) { it in
            guard let it = it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    do { try await S.uploadAvatar(img) } catch let e as SocialError { error = e.message } catch {}
                }
            }
        }
    }

    private func save() async {
        do { try await S.saveProfile(name: name, bio: bio, favs: favs); dismiss() }
        catch let e as SocialError { error = e.message } catch {}
    }
}

// MARK: - settings

private struct SocialSettingsSheet: View {
    @ObservedObject private var S = SocialStore.shared
    @Environment(\.look) private var L
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new = ""
    @State private var note = ""
    @State private var askDelete = false
    @State private var delPass = ""

    var body: some View {
        JSheet(title: "إعدادات الأصدقاء") {
            SettingsNote("السيرفر: " + S.server)
            JSwitchRow(title: "شارك قراءتي", sub: "إن أوقفتها لا يُرسل شيء، ولا يرى أصدقاؤك قراءتك.",
                       on: Binding(get: { S.shareReading }, set: { S.setShare($0) }))
            JSwitchRow(title: "أرقامي (كتب السنة والسلسلة والدقائق)", on: Binding(get: { S.me?.shareStats ?? true }, set: { S.setShareStats($0) }))
            JSwitchRow(title: "قوائمي", sub: "قوائم المكتبة بدون الكتب الخاصة.", on: Binding(get: { S.shareLists }, set: { S.setShareLists($0) }))
            SettingsNote("كتاب واحد تخفيه من صفحته: «إخفاء عن الأصدقاء».")
            Divider()
            JLabel(text: "تغيير كلمة السر")
            SocialField(label: "الحالية", text: $old, secure: true, latin: true)
            SocialField(label: "الجديدة", text: $new, secure: true, latin: true)
            Button("غيّر") {
                Task {
                    do { try await S.changePassword(old: old, new: new); note = "تغيّرت كلمة السر"; old = ""; new = "" }
                    catch let e as SocialError { note = e.message } catch {}
                }
            }.buttonStyle(JButtonStyle(look: L, small: true)).disabled(old.isEmpty || new.isEmpty)
            if !note.isEmpty { Text(note).font(JFont.body(14)).foregroundStyle(Color(L.ink2)) }
            Divider()
            Button { Task { await S.signOut(); dismiss() } } label: { Text("تسجيل الخروج").frame(maxWidth: .infinity) }.buttonStyle(JButtonStyle(look: L))
            Button { askDelete = true } label: { Text("حذف حسابي وكل ما فيه من السيرفر").frame(maxWidth: .infinity).foregroundStyle(Color(L.danger)) }.buttonStyle(JButtonStyle(look: L))
        }
        .alert("حذف الحساب؟", isPresented: $askDelete) {
            SecureField("كلمة السر", text: $delPass)
            Button("حذف نهائي", role: .destructive) {
                Task {
                    do { try await S.deleteAccount(password: delPass); dismiss() }
                    catch let e as SocialError { note = e.message } catch {}
                    delPass = ""
                }
            }
            Button("إلغاء", role: .cancel) { delPass = "" }
        } message: { Text("يُحذف حسابك وكل ما أرسلته ولا يمكن التراجع. كتبك في جليس تبقى.") }
    }
}

// MARK: - a quote chosen to share

private struct ShareQuoteSheet: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @Environment(\.dismiss) private var dismiss
    @State private var bookID: String?

    var body: some View {
        let books = lib.state.books.filter { !$0.quotes.isEmpty && !$0.raw.bool("socialPrivate") }
        JSheet(title: "شارك اقتباسًا", subtitle: bookID.flatMap { lib.state.book($0)?.title }) {
            if let id = bookID, let b = lib.state.book(id) {
                Button { bookID = nil } label: { Label("كل الكتب", systemImage: "chevron.backward") }.font(JFont.body(14)).foregroundStyle(Color(L.primary))
                ForEach(b.quotes) { q in
                    Button {
                        SocialStore.shared.shareQuote(title: b.title, author: b.author, text: q.text)
                        ToastCenter.shared.show("شاركته مع أصدقائك")
                        dismiss()
                    } label: {
                        Text(q.text).font(JFont.quote(16)).foregroundStyle(Color(L.ink)).lineSpacing(4).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface2)))
                    }.buttonStyle(.plain)
                }
            } else if books.isEmpty {
                Text("ما عندك اقتباسات في كتب غير خاصة.").font(JFont.body(15)).foregroundStyle(Color(L.ink2))
            } else {
                ForEach(books) { b in JMenuRow(icon: "book", title: b.title, sub: b.author, count: b.quotes.count) { bookID = b.id } }
            }
        }
    }
}

// MARK: - on a book's page: keep this book from friends

struct SocialBookRow: View {
    let bookID: String
    @ObservedObject private var S = SocialStore.shared
    @ObservedObject private var lib = Library.shared

    var body: some View {
        if S.signedIn && S.shareReading {
            JSwitchRow(title: "إخفاء هذا الكتاب عن الأصدقاء", sub: "لا يظهر في ملفك ولا نشاطك ولا تقييمك له.",
                       on: Binding(get: { lib.state.book(bookID)?.raw.bool("socialPrivate") ?? false },
                                   set: { v in Library.shared.changeBook(bookID) { $0.raw.set("socialPrivate", v) } }))
        }
    }
}
