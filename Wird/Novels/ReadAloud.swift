import UIKit
import AVFoundation
import MediaPlayer

/// القراءة الصوتية (answers-round2 س59): the phone's voices read the chapter sentence by sentence. The sentence being
/// read is highlighted and kept in view; it goes on to the next chapter by itself; headphones, the lock screen and
/// Control Center control it; a sleep timer stops it; voice and speed are yours to choose.
@MainActor
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()

    struct Piece { let para: Int; let s: Int; let e: Int; let text: String }

    private(set) weak var reader: ReaderViewController?
    private let synth = AVSpeechSynthesizer()
    private(set) var active = false
    private(set) var playing = false
    private var chapterIndex = 0
    private var pieces: [Piece] = []
    private var at = 0
    private var announce: String?
    private var token = 0
    private var sleepTimer: Timer?
    private(set) var sleepEnd: Date?
    private(set) var sleepAtChapterEnd = false
    private var commandsReady = false
    var onChange: (() -> Void)?

    // MARK: settings (kept in the novels' database, like the reader's other choices)

    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    var speed: Double {
        get { Double(DB.shared.get("tts.speed") ?? "") ?? 1 }
        set { DB.shared.set("tts.speed", String(newValue)); onChange?() }
    }
    /// the chosen voice for each language family ("ar", "en", …); empty means the phone's best voice for it
    func voiceID(for lang: String) -> String { DB.shared.get("tts.voice." + lang) ?? "" }
    func setVoice(_ id: String, for lang: String) { DB.shared.set("tts.voice." + lang, id); onChange?() }

    /// Voices for a language family, the better ones first.
    static func voices(_ lang: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    private func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let lang = text.range(of: "[\\u0600-\\u06FF]", options: .regularExpression) != nil ? "ar" : "en"
        let id = voiceID(for: lang)
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return Self.voices(lang).first ?? AVSpeechSynthesisVoice(language: lang == "ar" ? "ar-SA" : "en-US")
    }

    override init() {
        super.init()
        synth.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    }

    // MARK: starting and stopping

    /// Reads from a paragraph of a chapter (by its place in the reader's list).
    func start(_ r: ReaderViewController, chapter i: Int, para: Int) {
        if reader !== r { stopSpeaking() }
        reader = r
        active = true
        setupCommands()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        load(i, from: para, announce: false)
    }

    func stop() {
        stopSpeaking()
        active = false
        playing = false
        sleepTimer?.invalidate(); sleepTimer = nil; sleepEnd = nil; sleepAtChapterEnd = false
        reader?.call("JR.ttsClear()")
        reader?.readAloudChanged()
        reader = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onChange?()
    }

    private func stopSpeaking() {
        token += 1
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }

    func toggle() { playing ? pause() : resume() }

    func pause() {
        guard active else { return }
        if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
        playing = false
        updateNowPlaying()
        onChange?()
    }

    func resume() {
        guard active else { return }
        if synth.isPaused { synth.continueSpeaking() } else { speakCurrent() }
        playing = true
        updateNowPlaying()
        onChange?()
    }

    /// The next or previous paragraph.
    func skip(_ dir: Int) {
        guard active, !pieces.isEmpty else { return }
        let cur = pieces[min(at, pieces.count - 1)].para
        if dir > 0 {
            if let j = pieces.firstIndex(where: { $0.para > cur }) { jump(to: j) } else { nextChapter() }
        } else {
            // back to the start of this paragraph, or the one before if already there
            let first = pieces.firstIndex { $0.para == cur } ?? 0
            if at > first + 1 { jump(to: first) } else if let j = pieces.lastIndex(where: { $0.para < cur }) {
                let p = pieces[j].para
                jump(to: pieces.firstIndex { $0.para == p } ?? j)
            } else { jump(to: 0) }
        }
    }

    /// A tap on a paragraph while reading aloud: go on from it.
    func jump(chapterID: Int, para: Int) {
        guard let r = reader, let i = r.chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        if i == chapterIndex, let j = pieces.firstIndex(where: { $0.para >= para }) { jump(to: j) } else { load(i, from: para, announce: false) }
    }

    private func jump(to j: Int) {
        stopSpeaking()
        at = j
        playing = true
        speakCurrent()
        onChange?()
    }

    // MARK: the sleep timer

    func sleep(minutes: Int?) {
        sleepTimer?.invalidate(); sleepTimer = nil; sleepEnd = nil
        sleepAtChapterEnd = minutes == 0
        if let m = minutes, m > 0 {
            sleepEnd = Date().addingTimeInterval(Double(m) * 60)
            sleepTimer = Timer.scheduledTimer(withTimeInterval: Double(m) * 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.sleepNow() }
            }
        }
        onChange?()
    }

    private func sleepNow() {
        pause()
        sleepTimer = nil; sleepEnd = nil; sleepAtChapterEnd = false
        onChange?()
    }

    // MARK: chapters

    private func load(_ i: Int, from para: Int, announce: Bool) {
        guard let r = reader, r.chapters.indices.contains(i) else { stop(); return }
        stopSpeaking()
        let mine = token
        chapterIndex = i
        let ch = r.chapters[i]
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let t = try await Novels.shared.text(ch, source: r.novel.source)
                guard mine == self.token, self.active else { return }
                self.pieces = Self.split(Replacer.apply(t.paras, novel: r.novel.id))
                self.at = self.pieces.firstIndex { $0.para >= para } ?? 0
                self.announce = announce ? ch.label : nil
                self.playing = true
                self.updateNowPlaying()
                self.speakCurrent()
                self.onChange?()
                // the chapters after this one get ready while the phone is awake (reading may go on locked)
                Novels.shared.prepare(after: i, in: r.chapters, source: r.novel.source, count: max(3, r.settings.prefs.ahead))
            } catch {
                guard mine == self.token else { return }
                r.toast("ما انفتح الفصل للقراءة الصوتية")
                self.stop()
            }
        }
    }

    private func nextChapter() {
        guard let r = reader else { return }
        r.markReadForReadAloud(chapterIndex)
        if sleepAtChapterEnd { sleepNow(); return }
        let i = chapterIndex + 1
        guard r.chapters.indices.contains(i) else {
            playing = false
            r.toast("وصلت لآخر فصل منشور")
            onChange?()
            return
        }
        r.followReadAloud(to: i)
        load(i, from: 0, announce: true)
    }

    // MARK: speaking

    private func speakCurrent() {
        guard active else { return }
        if let a = announce {
            announce = nil
            let u = utterance(a)
            u.postUtteranceDelay = 0.4
            synth.speak(u)
            return
        }
        guard pieces.indices.contains(at) else { nextChapter(); return }
        let p = pieces[at]
        let u = utterance(p.text)
        // a breath between paragraphs, a shorter one between sentences
        let lastOfPara = !pieces.indices.contains(at + 1) || pieces[at + 1].para != p.para
        u.postUtteranceDelay = lastOfPara ? 0.28 : 0.06
        synth.speak(u)
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice(for: text)
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
        return u
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in self.started(text) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in self.finished(text) }
    }

    private func started(_ text: String) {
        guard active, pieces.indices.contains(at), pieces[at].text == text, let r = reader, r.chapters.indices.contains(chapterIndex) else { return }
        let p = pieces[at]
        r.readAloudActivity()
        if r.viewIfLoaded?.window != nil {
            r.call("JR.ttsMark(id, p, s, e)", ["id": r.chapters[chapterIndex].id, "p": p.para, "s": p.s, "e": p.e])
        }
    }

    private func finished(_ text: String) {
        guard active, playing else { return }
        // a sentence ends: the next; the chapter's name (said when a new chapter starts) ends: its first sentence
        if pieces.indices.contains(at), pieces[at].text == text { at += 1 }
        if at >= pieces.count { nextChapter() } else { speakCurrent() }
    }

    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            if type == .began { self.pause() }
            else if let o = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt, AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume) { self.resume() }
        }
    }

    // MARK: sentences

    /// A chapter's paragraphs cut into sentences, with their places in the page's plain text (no tatweel), so the page
    /// can mark exactly what is being read. Long sentences are cut again at commas.
    static func split(_ paras: [String]) -> [Piece] {
        var out: [Piece] = []
        let sentence = try! NSRegularExpression(pattern: "[^.!?؟…\\n]+[.!?؟…]*[\"»”'’)\\]]*", options: [])
        let comma = try! NSRegularExpression(pattern: "[^،,؛;:]+[،,؛;:]*", options: [])
        for (i, raw) in paras.enumerated() {
            if raw.hasPrefix("\u{FFFC}img:") { continue }
            let plain = raw.replacingOccurrences(of: "ـ", with: "") as NSString
            for m in sentence.matches(in: plain as String, range: NSRange(location: 0, length: plain.length)) {
                var parts = [m.range]
                if m.range.length > 260 {
                    parts = comma.matches(in: plain as String, range: m.range).map(\.range)
                }
                for r in parts {
                    var s = r.location, e = r.location + r.length
                    while s < e, let c = Unicode.Scalar(plain.character(at: s)), CharacterSet.whitespacesAndNewlines.contains(c) { s += 1 }
                    while e > s, let c = Unicode.Scalar(plain.character(at: e - 1)), CharacterSet.whitespacesAndNewlines.contains(c) { e -= 1 }
                    let text = plain.substring(with: NSRange(location: s, length: e - s))
                    // a piece with no letters at all (a row of stars, a lone dash) is not read
                    if e > s, text.rangeOfCharacter(from: .letters) != nil { out.append(Piece(para: i, s: s, e: e, text: text)) }
                }
            }
        }
        return out
    }

    // MARK: lock screen and headphones

    private func setupCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(1) }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-1) }; return .success }
    }

    private func updateNowPlaying() {
        guard let r = reader, r.chapters.indices.contains(chapterIndex) else { return }
        let ch = r.chapters[chapterIndex]
        var info: [String: Any] = [MPMediaItemPropertyTitle: ch.line, MPMediaItemPropertyArtist: r.novel.title,
                                   MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        if let id = r.bookID, let cover = Library.shared.image(Library.shared.state.book(id)?.cover) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// The player while reading aloud: close, back a paragraph, play or pause, forward a paragraph, and a menu for the
/// speed, the voice and the sleep timer. Glass, like the reader's other controls.
final class ReadAloudBar: UIVisualEffectView {
    private let play = UIButton(type: .system)
    private let options = UIButton(type: .system)
    private let caption = UILabel()

    init() {
        super.init(effect: Glass.effect())
        clipsToBounds = true
        layer.cornerRadius = 28
        func button(_ symbol: String, _ label: String, _ size: CGFloat = 18, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.accessibilityLabel = label
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            return b
        }
        let close = button("xmark", "إيقاف القراءة الصوتية", 15) { ReadAloud.shared.stop() }
        let back = button("backward.fill", "الفقرة السابقة") { ReadAloud.shared.skip(-1) }
        let fwd = button("forward.fill", "الفقرة التالية") { ReadAloud.shared.skip(1) }
        play.tintColor = .white
        play.addAction(UIAction { _ in ReadAloud.shared.toggle() }, for: .touchUpInside)
        play.widthAnchor.constraint(equalToConstant: 48).isActive = true
        options.setImage(UIImage(systemName: "ellipsis.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        options.tintColor = .white
        options.accessibilityLabel = "خيارات القراءة الصوتية"
        options.showsMenuAsPrimaryAction = true
        options.widthAnchor.constraint(equalToConstant: 44).isActive = true
        caption.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        caption.textColor = UIColor.white.withAlphaComponent(0.7)
        let row = UIStackView(arrangedSubviews: [close, back, play, fwd, options])
        row.axis = .horizontal
        row.distribution = .equalSpacing
        row.alignment = .center
        // the bar reads right to left like the rest of the reader: back on the right, forward on the left
        row.semanticContentAttribute = .forceRightToLeft
        let stack = UIStackView(arrangedSubviews: [row, caption])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 10),
            stack.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            row.leftAnchor.constraint(equalTo: stack.leftAnchor), row.rightAnchor.constraint(equalTo: stack.rightAnchor),
            row.heightAnchor.constraint(equalToConstant: 44)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    func refresh() {
        let a = ReadAloud.shared
        play.setImage(UIImage(systemName: a.playing ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)), for: .normal)
        play.accessibilityLabel = a.playing ? "إيقاف مؤقت" : "تشغيل"
        var bits: [String] = []
        if a.speed != 1 { bits.append(Self.speedLabel(a.speed)) }
        if let end = a.sleepEnd { bits.append("نوم بعد \(max(1, Int(end.timeIntervalSinceNow / 60 + 0.5))) د") }
        if a.sleepAtChapterEnd { bits.append("نوم آخر الفصل") }
        caption.text = bits.joined(separator: " · ")
        caption.isHidden = bits.isEmpty
        options.menu = menu()
    }

    static func speedLabel(_ s: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.maximumFractionDigits = 2
        return (f.string(from: NSNumber(value: s)) ?? "1") + "×"
    }

    private func menu() -> UIMenu {
        let a = ReadAloud.shared
        let speeds = UIMenu(title: "السرعة", image: UIImage(systemName: "speedometer"), options: .singleSelection, children: ReadAloud.speeds.map { s in
            UIAction(title: Self.speedLabel(s), state: a.speed == s ? .on : .off) { _ in a.speed = s; if a.playing { a.skipSame() } }
        })
        func voiceMenu(_ lang: String, _ title: String) -> UIMenu {
            let cur = a.voiceID(for: lang)
            var items: [UIMenuElement] = [UIAction(title: "الأفضل في الجوال", state: cur.isEmpty ? .on : .off) { _ in a.setVoice("", for: lang) }]
            items += ReadAloud.voices(lang).prefix(24).map { v in
                let q = v.quality == .premium ? " · ممتاز" : (v.quality == .enhanced ? " · محسّن" : "")
                return UIAction(title: v.name + q, subtitle: v.language, state: cur == v.identifier ? .on : .off) { _ in a.setVoice(v.identifier, for: lang); if a.playing { a.skipSame() } }
            }
            return UIMenu(title: title, image: UIImage(systemName: "person.wave.2"), options: .singleSelection, children: items)
        }
        let sleep = UIMenu(title: "مؤقت النوم", image: UIImage(systemName: "moon.zzz"), options: .singleSelection, children: [
            UIAction(title: "بدون", state: a.sleepEnd == nil && !a.sleepAtChapterEnd ? .on : .off) { _ in a.sleep(minutes: nil) },
            UIAction(title: "آخر الفصل", state: a.sleepAtChapterEnd ? .on : .off) { _ in a.sleep(minutes: 0) }
        ] + [15, 30, 45, 60].map { m in UIAction(title: "\(m) دقيقة") { _ in a.sleep(minutes: m) } })
        let note = UIAction(title: "أصوات أحسن: الإعدادات ← تسهيلات الاستخدام ← المحتوى المنطوق ← الأصوات", attributes: .disabled) { _ in }
        return UIMenu(title: "", children: [speeds, voiceMenu("ar", "الصوت العربي"), voiceMenu("en", "الصوت الإنجليزي"), sleep, UIMenu(title: "", options: .displayInline, children: [note])])
    }
}

extension ReadAloud {
    /// After a change of voice or speed: the sentence being read starts again with it.
    func skipSame() { jump(to: at) }
}
