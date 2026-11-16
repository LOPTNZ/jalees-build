import SwiftUI
import AVFoundation

/// «القراءة الصوتية» in the settings: the Gemini key (the user's own, free from Google AI Studio, kept only on the
/// phone), which reading to use, Gemini's voice with a sample to hear, and the audio kept on the phone.
struct ReadAloudSettings: View {
    @Environment(\.look) private var L
    @State private var entries = GeminiVoice.entries
    @State private var key = ""
    @State private var newLabel = ""
    @State private var engine = GeminiVoice.engine
    @State private var voice = GeminiVoice.voice
    @State private var showKey = false
    @State private var trying = false
    @State private var cache = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            note("Gemini يقرأ الروايات بالفصحى وبإعراب صحيح وبأصوات طبيعية، أدق بكثير من أصوات الجوال. مجاني بحدّ يومي، ولما يخلص الحد يكمّل صوت الجوال بعد ما يشكّل Gemini النص.")
            VStack(alignment: .leading, spacing: 8) {
                JLabel(text: "مفاتيح Gemini")
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in keyRow(i, e) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Group {
                            if showKey { TextField("AIza…", text: $key) } else { SecureField("AIza…", text: $key) }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                        .multilineTextAlignment(.leading)
                        .font(JFont.body(16)).foregroundStyle(Color(L.ink))
                        .accessibilityLabel(entries.isEmpty ? "مفتاح Gemini" : "مفتاح إضافي")
                        Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                            .buttonStyle(.plain).foregroundStyle(Color(L.ink2))
                            .accessibilityLabel(showKey ? "أخفِ المفتاح" : "أظهر المفتاح")
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .padding(.horizontal, 14).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                    HStack(spacing: 8) {
                        TextField("اسم للمفتاح (اختياري)", text: $newLabel)
                            .font(JFont.body(15)).foregroundStyle(Color(L.ink))
                            .padding(.horizontal, 14).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                        Button { addKey() } label: { Label("أضف المفتاح", systemImage: "plus") }
                            .buttonStyle(JButtonStyle(look: L, small: true))
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if !entries.isEmpty {
                note("يقرأ بالمفتاح الأول، ولما يخلص حده اليومي ينتقل للي بعده، وبعد ما يتجدد الحد (منتصف الليل بتوقيت كاليفورنيا) يرجع للأول. كل مفتاح يظهر هنا يشتغل أو خالص لليوم.")
            }
            note("الحد اليومي يحدده Google ويغيّره، وما ينشره بأرقام ثابتة. المبلّغ عنه للنماذج الصوتية المجانية بين 10 و100 طلب في اليوم لكل نموذج، والفصل الواحد يحتاج نحو 8 إلى 10 طلبات، يعني من فصل إلى عشرة فصول في اليوم لكل مفتاح تقريبًا. وإذا كانت المفاتيح من نفس مشروع Google تشترك في حدّ واحد.")
            note("تنبيه: شروط Google تمنع التحايل على حدود الاستخدام، فاستخدم مفاتيح حساباتك ومشاريعك أنت.")
            if entries.isEmpty {
                note("تسويه مجانًا: افتح صفحة المفاتيح بحساب Google، اضغط Create API key، انسخه والصقه هنا. يبقى في جوالك بس، وما يدخل في النسخة الاحتياطية.")
                Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                    Label("افتح صفحة المفاتيح", systemImage: "key")
                }
                .buttonStyle(JButtonStyle(look: L, small: true))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    JLabel(text: "القارئ")
                    JSeg(options: [(GeminiVoice.Engine.gemini, "Gemini"), (.tashkeel, "تشكيل + الجوال"), (.phone, "صوت الجوال")],
                         value: Binding(get: { engine }, set: { engine = $0; GeminiVoice.engine = $0 }))
                }
                if engine == .gemini {
                    VStack(alignment: .leading, spacing: 6) {
                        JLabel(text: "صوت Gemini")
                        HStack(spacing: 10) {
                            Menu {
                                Picker("صوت Gemini", selection: Binding(get: { voice }, set: { voice = $0; GeminiVoice.voice = $0 })) {
                                    Section("رجالية") {
                                        ForEach(GeminiVoice.voices.filter { $0.male }, id: \.id) { v in Text(v.id + " · " + v.tone).tag(v.id) }
                                    }
                                    Section("نسائية") {
                                        ForEach(GeminiVoice.voices.filter { !$0.male }, id: \.id) { v in Text(v.id + " · " + v.tone).tag(v.id) }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(voice).font(JFont.body(15, .semibold))
                                    Text(GeminiVoice.voices.first { $0.id == voice }?.tone ?? "").font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(Color(L.ink))
                                .padding(.horizontal, 14).frame(height: 40)
                                .background(Capsule().fill(Color(L.surface2)))
                            }
                            Button { trySample() } label: {
                                HStack(spacing: 6) {
                                    if trying { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                                    Text("جرّب")
                                }
                            }
                            .buttonStyle(JButtonStyle(look: L, small: true)).disabled(trying)
                        }
                    }
                }
                if engine == .gemini && !GeminiVoice.speechLeft {
                    note("خلص حد Gemini الصوتي لليوم، ويرجع الساعة \(resetTime). لين ذاك الوقت يقرأ صوت الجوال مع تشكيل Gemini.")
                }
            }
            if cache > 0 {
                HStack {
                    Text("الصوت المحفوظ في جوالك: \(megabytes(cache))").font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                    Spacer()
                    Button("امسحه") { GeminiVoice.clearCache(); cache = 0 }.buttonStyle(JButtonStyle(look: L, small: true))
                }
            }
        }
        .onAppear { cache = GeminiVoice.cacheSize(); entries = GeminiVoice.entries; engine = GeminiVoice.engine; voice = GeminiVoice.voice }
    }

    private func reload() {
        entries = GeminiVoice.entries
        engine = GeminiVoice.engine
    }

    private func addKey() {
        if GeminiVoice.addKey(key, label: newLabel) { key = ""; newLabel = "" }
        else { ToastCenter.shared.show("هذا المفتاح مضاف من قبل") }
        reload()
    }

    /// one key: its place, name (or number), the ends of it, whether it works, and the buttons to move or remove it
    private func keyRow(_ i: Int, _ e: GeminiVoice.KeyEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.label.isEmpty ? "مفتاح \(i + 1)" : e.label).font(JFont.body(15, .semibold)).foregroundStyle(Color(L.ink))
                Text(GeminiKeyRotation.mask(e.key)).font(JFont.body(13)).foregroundStyle(Color(L.ink2))
                    .environment(\.layoutDirection, .leftToRight)
                Text(stateText(GeminiVoice.state(of: e.id))).font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
            }
            Spacer(minLength: 4)
            Button { GeminiVoice.moveKey(e.id, by: -1); reload() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).foregroundStyle(Color(L.ink2)).disabled(i == 0).opacity(i == 0 ? 0.3 : 1)
                .accessibilityLabel("قدّمه")
            Button { GeminiVoice.moveKey(e.id, by: 1); reload() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).foregroundStyle(Color(L.ink2)).disabled(i == entries.count - 1).opacity(i == entries.count - 1 ? 0.3 : 1)
                .accessibilityLabel("أخّره")
            Button { GeminiVoice.removeKey(e.id); reload() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Color(L.ink2))
                .accessibilityLabel("احذف المفتاح")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface2)))
    }

    private func stateText(_ s: GeminiVoice.KeyState) -> String {
        switch s {
        case .working: return "يشتغل"
        case .rejected: return "Google رفضه، تأكد منه"
        case .out(let since, let until): return "خالص لليوم من الساعة \(clock(since))، يرجع الساعة \(clock(until))"
        }
    }

    private func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = "h:mm a"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private var resetTime: String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = "h:mm a"
        return f.string(from: Date(timeIntervalSince1970: GeminiVoice.nextReset()))
    }

    private func megabytes(_ n: Int) -> String {
        let mb = Double(n) / 1_000_000
        return mb < 1 ? "أقل من 1 م.ب" : "\(Int(mb.rounded())) م.ب"
    }

    private func note(_ t: String) -> some View {
        Text(t).font(JFont.body(15 * 0.86)).foregroundStyle(Color(L.ink2)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }

    private func trySample() {
        trying = true
        Task { @MainActor in
            do {
                let url = try await GeminiVoice.sample()
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
                try? AVAudioSession.sharedInstance().setActive(true)
                SamplePlayer.player = try AVAudioPlayer(contentsOf: url)
                SamplePlayer.player?.play()
                cache = GeminiVoice.cacheSize()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
            trying = false
        }
    }
}

/// Keeps the sample playing after the button's work is done.
@MainActor
private enum SamplePlayer {
    static var player: AVAudioPlayer?
}
