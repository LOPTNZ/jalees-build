import SwiftUI
import AVFoundation

/// «القراءة الصوتية» in the settings: the Gemini key (the user's own, free from Google AI Studio, kept only on the
/// phone), which reading to use, Gemini's voice with a sample to hear, and the audio kept on the phone.
struct ReadAloudSettings: View {
    @Environment(\.look) private var L
    @State private var key = GeminiVoice.key
    @State private var engine = GeminiVoice.engine
    @State private var voice = GeminiVoice.voice
    @State private var showKey = false
    @State private var trying = false
    @State private var cache = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            note("Gemini يقرأ الروايات بالفصحى وبإعراب صحيح وبأصوات طبيعية، أدق بكثير من أصوات الجوال. مجاني بحدّ يومي، ولما يخلص الحد يكمّل صوت الجوال بعد ما يشكّل Gemini النص.")
            VStack(alignment: .leading, spacing: 6) {
                JLabel(text: "مفتاح Gemini")
                HStack(spacing: 8) {
                    Group {
                        if showKey { TextField("AIza…", text: $key) } else { SecureField("AIza…", text: $key) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                    .multilineTextAlignment(.leading)
                    .font(JFont.body(16)).foregroundStyle(Color(L.ink))
                    .accessibilityLabel("مفتاح Gemini")
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.plain).foregroundStyle(Color(L.ink2))
                        .accessibilityLabel(showKey ? "أخفِ المفتاح" : "أظهر المفتاح")
                }
                .environment(\.layoutDirection, .leftToRight)
                .padding(.horizontal, 14).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                .onChange(of: key) { v in
                    GeminiVoice.key = v
                    engine = GeminiVoice.engine
                }
            }
            if key.isEmpty {
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
        .onAppear { cache = GeminiVoice.cacheSize(); key = GeminiVoice.key; engine = GeminiVoice.engine; voice = GeminiVoice.voice }
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
