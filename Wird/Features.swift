import UIKit
import AVFoundation
import Vision
import UserNotifications
import WidgetKit
import ActivityKit

// MARK: - network (book search, covers). HTTPS only.

enum Net {
    static func fetch(_ o: [String: Any], done: @escaping ([String: Any]) -> Void) {
        let raw = o["url"] as? String ?? ""
        let fixed = URL(string: raw) == nil ? (raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(.urlPathAllowed)) ?? raw) : raw
        guard let url = URL(string: fixed), url.scheme?.lowercased() == "https" else {
            done(["ok": false, "status": 0])
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 25)
        // book sites answer a normal browser best; Open Library and Google prefer an app that names itself
        let ua = (o["ua"] as? String) == "app" ? "Wird/1.0 (iPhone; reading tracker)" : BookBrowser.safariUA
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("ar,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            var r: [String: Any] = ["ok": err == nil && (200..<300).contains(code), "status": code]
            if let d = data {
                if (o["as"] as? String) == "dataurl" {
                    let mime = http?.mimeType ?? "image/jpeg"
                    r["dataurl"] = "data:\(mime);base64," + d.base64EncodedString()
                } else {
                    r["text"] = String(data: d, encoding: .utf8) ?? ""
                }
            }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }
}

// MARK: - text from a photo, on the device

enum OCR {
    static func run(_ o: [String: Any], done: @escaping ([String: Any]) -> Void) {
        guard let s = o["url"] as? String, let comma = s.firstIndex(of: ","),
              let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
              let cg = UIImage(data: data)?.cgImage else {
            done(["text": ""])
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            var arabic = false
            if let langs = try? req.supportedRecognitionLanguages() {
                let ar = langs.filter { $0.hasPrefix("ar") }
                arabic = !ar.isEmpty
                req.recognitionLanguages = ar + ["en-US"]
            }
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            // top to bottom; a large vertical gap starts a new paragraph, otherwise lines join with a space
            let lines: [(CGRect, String)] = (req.results ?? []).compactMap { (ob: VNRecognizedTextObservation) -> (CGRect, String)? in
                guard let t = ob.topCandidates(1).first?.string else { return nil }
                return (ob.boundingBox, t)
            }.sorted { $0.0.midY > $1.0.midY }
            var text = ""
            var prev: CGRect?
            for (box, t) in lines {
                if let p = prev { text += (p.minY - box.maxY) > box.height * 0.9 ? "\n" : " " }
                text += t
                prev = box
            }
            // each line with its height and position, so a cover's title (the biggest text) can be picked out
            let info: [[String: Any]] = lines.map { ["t": $0.1, "h": Double($0.0.height), "y": Double($0.0.midY)] }
            DispatchQueue.main.async { done(["text": text, "arabic": arabic, "lines": info]) }
        }
    }
}

// MARK: - haptics

enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let note = UINotificationFeedbackGenerator()

    static func play(_ kind: String?) {
        switch kind ?? "" {
        case "soft": soft.impactOccurred()
        case "success": note.notificationOccurred(.success)
        case "warn": note.notificationOccurred(.warning)
        default: selection.selectionChanged()
        }
    }
}

// MARK: - ambient sounds: gapless loops that keep playing with the screen locked

final class Ambient {
    static let shared = Ambient()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var volume: Float = 0.6

    func set(_ o: [String: Any]?) {
        guard let o = o, let kind = o["kind"] as? String else {
            stop()
            return
        }
        if let v = o["vol"] as? Double { volume = Float(v) }
        play(kind)
    }

    func setVolume(_ v: Float) {
        volume = v
        player.volume = v
    }

    private func play(_ kind: String) {
        guard let url = Bundle.main.url(forResource: kind, withExtension: "m4a"),
              let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
        do { try file.read(into: buf) } catch { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if !attached {
            engine.attach(player)
            attached = true
        }
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: buf.format)
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.volume = volume
        player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - notifications: countdown end and the daily reminder

enum Notify {
    private static var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    static func authorize(_ done: @escaping (Bool) -> Void) {
        center.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: done(true)
            case .notDetermined: center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in done(ok) }
            default: done(false)
            }
        }
    }

    private static func content(_ title: String, _ body: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        return c
    }

    static func schedule(_ o: [String: Any]) {
        guard let id = o["id"] as? String, let secs = o["in"] as? Double, secs >= 1 else { return }
        authorize { ok in
            guard ok else { return }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
            let req = UNNotificationRequest(identifier: "wird." + id, content: content(o["title"] as? String ?? "جليس", o["body"] as? String ?? ""), trigger: trigger)
            center.add(req)
        }
    }

    static func cancel(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["wird." + id])
    }

    /// One notification per day for the next three weeks; today's is skipped once the daily goal is met.
    static func remind(_ o: [String: Any], done: @escaping (Bool) -> Void) {
        center.removePendingNotificationRequests(withIdentifiers: (0..<21).map { "wird.rem.\($0)" })
        guard (o["on"] as? Bool) == true else {
            done(true)
            return
        }
        let parts = (o["time"] as? String ?? "21:00").split(separator: ":").compactMap { Int($0) }
        let hour = parts.first ?? 21, minute = parts.count > 1 ? parts[1] : 0
        let skipToday = (o["skipToday"] as? Bool) ?? false
        let title = o["title"] as? String ?? "جليس"
        let body = o["body"] as? String ?? ""
        authorize { ok in
            guard ok else {
                done(false)
                return
            }
            let cal = Calendar.greg
            let now = Date()
            for d in 0..<21 {
                guard let day = cal.date(byAdding: .day, value: d, to: now) else { continue }
                var comps = cal.dateComponents([.year, .month, .day], from: day)
                comps.hour = hour
                comps.minute = minute
                guard let fire = cal.date(from: comps), fire > now else { continue }
                if d == 0 && skipToday { continue }
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                center.add(UNNotificationRequest(identifier: "wird.rem.\(d)", content: content(title, body), trigger: trigger))
            }
            done(true)
        }
    }
}

// MARK: - home & lock screen widgets read a snapshot from the shared App Group

enum WidgetSync {
    private static var lastCover: String?
    private static var reloadPending = false

    static func write(_ o: [String: Any]) {
        guard let dir = SharedGroup.container else { return }
        if let d = try? JSONSerialization.data(withJSONObject: o) {
            try? d.write(to: dir.appendingPathComponent("widget.json"), options: .atomic)
        }
        let coverFile = dir.appendingPathComponent("cover.jpg")
        let cover = (o["book"] as? [String: Any])?["cover"] as? String ?? ""
        if cover.isEmpty {
            try? FileManager.default.removeItem(at: coverFile)
            lastCover = nil
        } else if cover != lastCover || !FileManager.default.fileExists(atPath: coverFile.path), let img = Store.shared.image(cover) {
            let h: CGFloat = 330
            let w = h * img.size.width / max(1, img.size.height)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let thumb = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in
                img.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            try? thumb.jpegData(compressionQuality: 0.85)?.write(to: coverFile, options: .atomic)
            lastCover = cover
        }
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            reloadPending = false
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

// MARK: - the running session on the lock screen (Live Activity)

enum LiveSession {
    static func handle(_ o: [String: Any]) {
        guard let op = o["op"] as? String else { return }
        if op == "end" {
            end()
            return
        }
        let start = (o["start"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let state = WirdSessionAttributes.ContentState(
            start: start,
            elapsed: (o["elapsed"] as? NSNumber)?.intValue ?? 0,
            paused: (o["paused"] as? Bool) ?? false,
            pos: o["pos"] as? String ?? "")
        let title = o["title"] as? String ?? ""
        let current = Activity<WirdSessionAttributes>.activities
        if let act = current.first, act.attributes.title == title {
            Task { await act.update(using: state) }
            return
        }
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = WirdSessionAttributes(title: title, author: o["author"] as? String ?? "", audio: (o["audio"] as? Bool) ?? false)
        _ = try? Activity<WirdSessionAttributes>.request(attributes: attrs, contentState: state, pushType: nil)
    }

    static func end() {
        for act in Activity<WirdSessionAttributes>.activities {
            Task { await act.end(using: nil, dismissalPolicy: .immediate) }
        }
    }
}
