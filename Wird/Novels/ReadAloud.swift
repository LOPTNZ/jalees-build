import UIKit
import AVFoundation
import MediaPlayer

/// القراءة الصوتية (answers-round2 س59, and «قارئ دقيق للعربية»). Gemini reads the chapter a few paragraphs at a time,
/// in fusha with its case endings (GeminiVoice.swift); when its free allowance is out for the day the phone's voice
/// reads Gemini's fully diacritized text, and without a key or a connection the phone's voice reads the text as it is.
/// The sentence being read is highlighted and kept in view; it goes on to the next chapter by itself; headphones, the
/// lock screen and Control Center control it; a sleep timer stops it; voice and speed are yours to choose.
@MainActor
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = ReadAloud()

    struct Piece { let para: Int; let s: Int; let e: Int; let text: String }

    /// A few whole paragraphs read in one go by Gemini. Chunks are cut the same way from the chapter's start every
    /// time, so the kept audio is found again wherever reading starts; the first carries the chapter's name.
    struct Chunk {
        let lo: Int, hi: Int
        let lead: String
        let text: String
        /// where each piece starts in the chunk's audio, as a share of it (by its letters, with room for the pauses)
        let starts: [Double]
        let leadShare: Double
    }

    /// How a chunk is read: Gemini's audio, or the phone's voice saying these words for each piece.
    enum Rendition { case audio(URL), speech([String], diacritized: Bool) }

    private(set) weak var reader: ReaderViewController?
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var playerChunk = -1
    private var tick: Timer?
    private(set) var active = false
    private(set) var playing = false
    /// Gemini is making the audio of the passage about to be read
    private(set) var waiting = false
    /// what is reading now, for the bar's caption
    private(set) var now: GeminiVoice.Engine = .phone
    private var chapterIndex = 0
    private var chapterLine = ""
    private var pieces: [Piece] = []
    private var chunks: [Chunk] = []
    private var at = 0
    private var renditions: [Int: Task<Rendition, Never>] = [:]
    private var ready: [Int: Rendition] = [:]
    private var utts: [ObjectIdentifier: Int] = [:]
    private var speechTexts: [String] = []
    private var speechChunk = -1
    private var token = 0
    /// chunks made for another chapter, engine or voice don't count
    private var gen = 0
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var told = Set<String>()
    private var sleepTimer: Timer?
    private(set) var sleepEnd: Date?
    private(set) var sleepAtChapterEnd = false
    private var commandsReady = false
    var onChange: (() -> Void)?
    /// simulator checks (-JaleesSilent): the speech engine there can stall the app, so sentences are "said" in silence
    /// at a reading pace, and the player, the highlight and going on to the next sentence are what gets checked
    private let silent = ProcessInfo.processInfo.arguments.contains("-JaleesSilent")

    // MARK: settings (kept in the novels' database, like the reader's other choices)

    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    var speed: Double {
        get { Double(DB.shared.get("tts.speed") ?? "") ?? 1 }
        set {
            DB.shared.set("tts.speed", String(newValue))
            if let p = player { p.rate = Float(newValue) } else if playing { skipSame() }
            onChange?()
        }
    }
    /// the chosen phone voice for each language family ("ar", "en", …); empty means the phone's best voice for it
    func voiceID(for lang: String) -> String { DB.shared.get("tts.voice." + lang) ?? "" }
    func setVoice(_ id: String, for lang: String) { DB.shared.set("tts.voice." + lang, id); if playing && player == nil { skipSame() }; onChange?() }

    func setEngine(_ e: GeminiVoice.Engine) { GeminiVoice.engine = e; restartChunks() }
    func setGeminiVoice(_ v: String) { GeminiVoice.voice = v; restartChunks() }

    /// Voices for a language family, the better ones first.
    static func voices(_ lang: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    private func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let lang = Self.isArabic(text) ? "ar" : "en"
        let id = voiceID(for: lang)
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return Self.voices(lang).first ?? AVSpeechSynthesisVoice(language: lang == "ar" ? "ar-SA" : "en-US")
    }

    static func isArabic(_ s: String) -> Bool { s.range(of: "[\\u0600-\\u06FF]", options: .regularExpression) != nil }

    override init() {
        super.init()
        synth.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    }

    // MARK: starting and stopping

    /// Reads from a paragraph of a chapter (by its place in the reader's list).
    func start(_ r: ReaderViewController, chapter i: Int, para: Int) {
        if reader !== r { stopSounds() }
        reader = r
        active = true
        told = []
        setupCommands()
        if !silent {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        load(i, from: para)
    }

    func stop() {
        stopSounds()
        active = false
        playing = false
        waiting = false
        endBackground()
        sleepTimer?.invalidate(); sleepTimer = nil; sleepEnd = nil; sleepAtChapterEnd = false
        reader?.call("JR.ttsClear()")
        reader?.readAloudChanged()
        reader = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onChange?()
    }

    /// Silence, and forget what was about to be said (the audio being made goes on and is kept for later).
    private func stopSounds() {
        token += 1
        utts = [:]
        speechChunk = -1
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        player?.stop(); player = nil; playerChunk = -1
        tick?.invalidate(); tick = nil
    }

    func toggle() { playing ? pause() : resume() }

    func pause() {
        guard active else { return }
        if let p = player { p.pause(); tick?.invalidate(); tick = nil }
        if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
        playing = false
        updateNowPlaying()
        onChange?()
    }

    func resume() {
        guard active else { return }
        playing = true
        if let p = player { p.play(); startTick() } else if synth.isPaused { synth.continueSpeaking() } else { playCurrent() }
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
        if i == chapterIndex, let j = pieces.firstIndex(where: { $0.para >= para }) { jump(to: j) } else { load(i, from: para) }
    }

    private func jump(to j: Int) {
        stopSounds()
        at = j
        playing = true
        playCurrent()
        onChange?()
    }

    /// After a change of engine or Gemini voice: what was made for the old one is set aside.
    private func restartChunks() {
        gen += 1
        renditions = [:]
        ready = [:]
        if active { jump(to: at) }
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

    private func load(_ i: Int, from para: Int) {
        guard let r = reader, r.chapters.indices.contains(i) else { stop(); return }
        stopSounds()
        let mine = token
        chapterIndex = i
        let ch = r.chapters[i]
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let t = try await Novels.shared.text(ch, source: r.novel.source)
                guard mine == self.token, self.active else { return }
                self.pieces = Self.split(Replacer.apply(t.paras, novel: r.novel.id))
                self.chapterLine = ch.line
                self.chunks = Self.chunks(self.pieces, lead: ch.line)
                self.gen += 1
                self.renditions = [:]
                self.ready = [:]
                self.at = self.pieces.firstIndex { $0.para >= para } ?? 0
                self.playing = true
                self.updateNowPlaying()
                self.playCurrent()
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
        if sleepAtChapterEnd { stopSounds(); sleepNow(); return }
        let i = chapterIndex + 1
        guard r.chapters.indices.contains(i) else {
            stopSounds()
            playing = false
            r.toast("وصلت لآخر فصل منشور")
            onChange?()
            return
        }
        r.followReadAloud(to: i)
        load(i, from: 0)
    }

    // MARK: chunks

    /// Whole paragraphs together up to about 1,400 letters (a minute or two of listening); a longer paragraph is cut
    /// between its sentences.
    static func chunks(_ pieces: [Piece], lead: String) -> [Chunk] {
        var out: [Chunk] = []
        var lo = 0
        func weight(_ i: Int) -> Double {
            let p = pieces[i]
            var w = Double(p.text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }.count)
            w += 4 // the pause after a sentence
            if i + 1 == pieces.count || pieces[i + 1].para != p.para { w += 6 }
            return w
        }
        func make(_ lo: Int, _ hi: Int) {
            let first = out.isEmpty
            let ld = first ? lead : ""
            var text = ld.isEmpty ? "" : ld + ".\n\n"
            for i in lo..<hi {
                if i > lo { text += pieces[i].para == pieces[i - 1].para ? " " : "\n\n" }
                text += pieces[i].text
            }
            let leadW = ld.isEmpty ? 0 : Double(ld.count) + 10
            let ws = (lo..<hi).map(weight)
            let total = max(1, leadW + ws.reduce(0, +))
            var starts: [Double] = []
            var acc = leadW
            for w in ws { starts.append(acc / total); acc += w }
            out.append(Chunk(lo: lo, hi: hi, lead: ld, text: text, starts: starts, leadShare: leadW / total))
        }
        var size = 0
        var i = 0
        while i < pieces.count {
            let len = pieces[i].text.count
            let newPara = i > lo && pieces[i].para != pieces[i - 1].para
            if i > lo && ((newPara && size >= 1_400) || size + len > 2_600) {
                make(lo, i); lo = i; size = 0
            }
            size += len + 1
            i += 1
        }
        if lo < pieces.count { make(lo, pieces.count) }
        return out
    }

    private func chunkIndex(of piece: Int) -> Int { chunks.firstIndex { piece >= $0.lo && piece < $0.hi } ?? 0 }

    /// The chunk's rendition, asked for once.
    private func rendition(_ c: Int) -> Task<Rendition, Never> {
        if let t = renditions[c] { return t }
        let ch = chunks[c]
        let texts = pieces[ch.lo..<ch.hi].map(\.text)
        let g = gen
        let t = Task { @MainActor [weak self] () -> Rendition in
            let r = await Self.render(ch.text, texts: texts) { self?.tell($0) }
            if let self = self, self.gen == g { self.ready[c] = r }
            return r
        }
        renditions[c] = t
        return t
    }

    /// Gemini's audio, else Gemini's diacritics for the phone's voice, else the text as it is.
    static func render(_ text: String, texts: [String], tell: @escaping (String) -> Void) async -> Rendition {
        var engine = GeminiVoice.engine
        if GeminiVoice.badKey { engine = .phone }
        if engine == .gemini {
            do { return .audio(try await GeminiVoice.audio(text)) } catch {
                switch error as? GeminiVoice.Failure {
                case .badKey?: tell(GeminiVoice.Failure.badKey.localizedDescription); return .speech(texts, diacritized: false)
                case .exhausted?: tell("خلص حد Gemini المجاني لليوم، أكمل بصوت الجوال مع تشكيل Gemini")
                case .offline?: tell("ما فيه اتصال، أكمل بصوت الجوال"); return .speech(texts, diacritized: false)
                default: break
                }
            }
            engine = .tashkeel
        }
        if engine == .tashkeel && isArabic(text) {
            if let d = try? await GeminiVoice.diacritize(texts) { return .speech(d, diacritized: true) }
            tell("ما قدرت أشكّل النص، أكمل بصوت الجوال")
        }
        return .speech(texts, diacritized: false)
    }

    /// A word on why the reading changed, once per kind while reading.
    private func tell(_ s: String) {
        guard active, !told.contains(s) else { return }
        told.insert(s)
        reader?.toast(s)
    }

    /// The next two chunks are made while this one is heard; at the chapter's end, the next chapter's first.
    private func prefetch(after c: Int) {
        guard GeminiVoice.engine != .phone else { return }
        for k in [c + 1, c + 2] where chunks.indices.contains(k) { _ = rendition(k) }
        guard c + 2 >= chunks.count, let r = reader, r.chapters.indices.contains(chapterIndex + 1) else { return }
        let next = r.chapters[chapterIndex + 1]
        let source = r.novel.source, novel = r.novel.id
        Task { @MainActor in
            guard let t = try? await Novels.shared.text(next, source: source) else { return }
            let ps = Self.split(Replacer.apply(t.paras, novel: novel))
            guard let first = Self.chunks(ps, lead: next.line).first else { return }
            _ = await Self.render(first.text, texts: ps[first.lo..<first.hi].map(\.text)) { _ in }
        }
    }

    // MARK: playing

    private func playCurrent() {
        guard active, playing else { return }
        guard pieces.indices.contains(at), !chunks.isEmpty else { nextChapter(); return }
        let c = chunkIndex(of: at)
        let mine = token
        let task = rendition(c)
        prefetch(after: c)
        if let r = ready[c] { begin(c, r); return }
        waiting = true
        // locked, nothing plays while Gemini makes the audio: ask iOS for the time to finish it
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "read-aloud") { [weak self] in self?.endBackground() }
        }
        onChange?()
        Task { @MainActor [weak self] in
            let r = await task.value
            guard let self = self, mine == self.token, self.active, self.playing else { return }
            self.waiting = false
            self.begin(c, r)
            self.onChange?()
        }
    }

    private func endBackground() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    private func begin(_ c: Int, _ r: Rendition) {
        waiting = false
        defer { endBackground() }
        let ch = chunks[c]
        switch r {
        case .audio(let url):
            guard let p = try? AVAudioPlayer(contentsOf: url) else {
                try? FileManager.default.removeItem(at: url)
                begin(c, .speech(pieces[ch.lo..<ch.hi].map(\.text), diacritized: false))
                return
            }
            now = .gemini
            p.delegate = self
            p.enableRate = true
            p.rate = Float(speed)
            p.prepareToPlay()
            // from the chapter's very start the name is heard first; elsewhere from the piece's place in the audio
            let share = at == ch.lo && c == 0 ? 0 : ch.starts[at - ch.lo]
            p.currentTime = max(0, share * p.duration - 0.15)
            player = p
            playerChunk = c
            p.play()
            startTick()
            mark()
        case .speech(let texts, let diacritized):
            now = diacritized ? .tashkeel : .phone
            speechTexts = texts
            speechChunk = c
            if c == 0 && at == 0 && !chapterLine.isEmpty {
                let u = utterance(chapterLine)
                u.postUtteranceDelay = 0.4
                utts[ObjectIdentifier(u)] = -1
                say(u)
            }
            speakPiece()
        }
        onChange?()
    }

    private func speakPiece() {
        guard active, speechChunk >= 0, chunks.indices.contains(speechChunk) else { return }
        let ch = chunks[speechChunk]
        guard at >= ch.lo && at < ch.hi else { speechChunk = -1; playCurrent(); return }
        let u = utterance(speechTexts[at - ch.lo])
        // a breath between paragraphs, a shorter one between sentences
        let lastOfPara = !pieces.indices.contains(at + 1) || pieces[at + 1].para != pieces[at].para
        u.postUtteranceDelay = lastOfPara ? 0.28 : 0.06
        utts[ObjectIdentifier(u)] = at
        say(u)
    }

    private func say(_ u: AVSpeechUtterance) {
        guard silent else { synth.speak(u); return }
        let id = ObjectIdentifier(u), seconds = max(0.6, Double(u.speechString.count) / 15 / speed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.spoke(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.playing else { return }
            self.said(id)
        }
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice(for: text)
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
        return u
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.spoke(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.said(id) }
    }

    private func spoke(_ id: ObjectIdentifier) {
        guard let k = utts[id], k >= 0, k == at else { return }
        mark()
    }

    private func said(_ id: ObjectIdentifier) {
        guard active, playing, let k = utts.removeValue(forKey: id) else { return }
        if k < 0 { return } // the chapter's name; its first sentence is already queued
        guard k == at else { return }
        at += 1
        if at >= pieces.count { nextChapter() } else { speakPiece() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(p)
        Task { @MainActor in
            guard let cur = self.player, ObjectIdentifier(cur) == id, self.chunks.indices.contains(self.playerChunk) else { return }
            self.at = self.chunks[self.playerChunk].hi
            self.player = nil
            self.playerChunk = -1
            self.tick?.invalidate(); self.tick = nil
            if self.at >= self.pieces.count { self.nextChapter() } else { self.playCurrent() }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(p)
        Task { @MainActor in
            guard let cur = self.player, ObjectIdentifier(cur) == id else { return }
            self.player = nil
            self.tick?.invalidate(); self.tick = nil
            let c = self.playerChunk
            self.playerChunk = -1
            guard self.chunks.indices.contains(c) else { return }
            let ch = self.chunks[c]
            self.begin(c, .speech(self.pieces[ch.lo..<ch.hi].map(\.text), diacritized: false))
        }
    }

    /// While Gemini's audio plays, the highlight follows it: each sentence gets its share of the time.
    private func startTick() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.follow() }
        }
    }

    private func follow() {
        guard let p = player, chunks.indices.contains(playerChunk) else { return }
        let ch = chunks[playerChunk]
        let share = p.duration > 0 ? p.currentTime / p.duration : 0
        var k = ch.lo
        for (j, s) in ch.starts.enumerated() where share + 0.004 >= s { k = ch.lo + j }
        if k != at { at = k; mark() }
    }

    /// The page marks the sentence being read.
    private func mark() {
        guard active, pieces.indices.contains(at), let r = reader, r.chapters.indices.contains(chapterIndex) else { return }
        let p = pieces[at]
        r.readAloudActivity()
        if r.viewIfLoaded?.window != nil {
            r.call("JR.ttsMark(id, p, s, e)", ["id": r.chapters[chapterIndex].id, "p": p.para, "s": p.s, "e": p.e])
        }
    }

    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let o = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
        Task { @MainActor in
            if type == .began { self.pause() }
            else if let o = o, AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume) { self.resume() }
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
/// reading (Gemini or the phone), the voice, the speed and the sleep timer. Glass, like the reader's other controls.
final class ReadAloudBar: UIVisualEffectView {
    private let play = UIButton(type: .system)
    private let options = UIButton(type: .system)
    private let caption = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

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
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.isUserInteractionEnabled = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        play.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: play.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: play.centerYAnchor)])
        options.setImage(UIImage(systemName: "ellipsis.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        options.tintColor = .white
        options.accessibilityLabel = "خيارات القراءة الصوتية".tr
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
            stack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            row.leftAnchor.constraint(equalTo: stack.leftAnchor), row.rightAnchor.constraint(equalTo: stack.rightAnchor),
            row.heightAnchor.constraint(equalToConstant: 44)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    func refresh() {
        let a = ReadAloud.shared
        let busy = a.waiting && a.playing
        play.setImage(busy ? nil : UIImage(systemName: a.playing ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)), for: .normal)
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        play.accessibilityLabel = busy ? "يجهّز الصوت" : (a.playing ? "إيقاف مؤقت" : "تشغيل")
        var bits: [String] = []
        if busy { bits.append("Gemini يجهّز الصوت…") }
        else if a.active && GeminiVoice.engine != .phone {
            switch a.now {
            case .gemini: bits.append("Gemini · " + GeminiVoice.voice)
            case .tashkeel: bits.append("صوت الجوال · تشكيل Gemini")
            case .phone: bits.append("صوت الجوال")
            }
        }
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
        let speeds = UIMenu(title: "السرعة".tr, image: UIImage(systemName: "speedometer"), options: .singleSelection, children: ReadAloud.speeds.map { s in
            UIAction(title: Self.speedLabel(s), state: a.speed == s ? .on : .off) { _ in a.speed = s }
        })
        func voiceMenu(_ lang: String, _ title: String) -> UIMenu {
            let cur = a.voiceID(for: lang)
            var items: [UIMenuElement] = [UIAction(title: "الأفضل في الجوال".tr, state: cur.isEmpty ? .on : .off) { _ in a.setVoice("", for: lang) }]
            items += ReadAloud.voices(lang).prefix(24).map { v in
                let q = v.quality == .premium ? " · ممتاز" : (v.quality == .enhanced ? " · محسّن" : "")
                return UIAction(title: v.name + q, subtitle: v.language, state: cur == v.identifier ? .on : .off) { _ in a.setVoice(v.identifier, for: lang) }
            }
            return UIMenu(title: title, image: UIImage(systemName: "person.wave.2"), options: .singleSelection, children: items)
        }
        let sleep = UIMenu(title: "مؤقت النوم".tr, image: UIImage(systemName: "moon.zzz"), options: .singleSelection, children: [
            UIAction(title: "بدون".tr, state: a.sleepEnd == nil && !a.sleepAtChapterEnd ? .on : .off) { _ in a.sleep(minutes: nil) },
            UIAction(title: "آخر الفصل".tr, state: a.sleepAtChapterEnd ? .on : .off) { _ in a.sleep(minutes: 0) }
        ] + [15, 30, 45, 60].map { m in UIAction(title: "\(m) دقيقة".tr) { _ in a.sleep(minutes: m) } })

        var top: [UIMenuElement] = []
        if GeminiVoice.hasKey {
            let eng = GeminiVoice.engine
            top.append(UIMenu(title: "القارئ".tr, subtitle: eng.title, image: UIImage(systemName: "waveform"), options: .singleSelection,
                              children: GeminiVoice.Engine.allCases.map { e in
                                  UIAction(title: e.title, state: eng == e ? .on : .off) { _ in a.setEngine(e) }
                              }))
            if eng == .gemini {
                let cur = GeminiVoice.voice
                func group(_ male: Bool) -> UIMenu {
                    UIMenu(title: male ? "رجالية" : "نسائية", options: .displayInline, children: GeminiVoice.voices.filter { $0.male == male }.map { v in
                        UIAction(title: v.id, subtitle: v.tone, state: cur == v.id ? .on : .off) { _ in a.setGeminiVoice(v.id) }
                    })
                }
                top.append(UIMenu(title: "صوت Gemini".tr, subtitle: cur, image: UIImage(systemName: "person.wave.2.fill"), options: .singleSelection, children: [group(true), group(false)]))
            }
        } else {
            top.append(UIAction(title: "لقراءة عربية دقيقة: أضف مفتاح Gemini المجاني من الإعدادات ← القراءة الصوتية".tr, image: UIImage(systemName: "sparkles"), attributes: .disabled) { _ in })
        }
        let phone = UIMenu(title: "صوت الجوال".tr, image: UIImage(systemName: "iphone"), children: [
            voiceMenu("ar", "الصوت العربي"), voiceMenu("en", "الصوت الإنجليزي"),
            UIMenu(title: "", options: .displayInline, children: [
                UIAction(title: "أصوات أحسن: الإعدادات ← تسهيلات الاستخدام ← المحتوى المنطوق ← الأصوات".tr, attributes: .disabled) { _ in }
            ])
        ])
        return UIMenu(title: "", children: [UIMenu(title: "", options: .displayInline, children: top), speeds, phone, sleep])
    }
}

extension ReadAloud {
    /// After a change of voice or speed: the sentence being read starts again with it.
    func skipSame() { jump(to: at) }
}
