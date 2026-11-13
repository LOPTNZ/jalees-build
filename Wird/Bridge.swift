import UIKit
import WebKit

/// window.webkit.messageHandlers.wird.postMessage({cmd, a}) → Promise with the reply.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var host: WebViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let reply: (Any?) -> Void = { v in DispatchQueue.main.async { replyHandler(v, nil) } }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "bad message")
            return
        }
        let a = body["a"]
        let o = a as? [String: Any] ?? [:]

        switch cmd {
        case "state":
            if let s = a as? String { Store.shared.saveState(s) }
            reply(true)
        case "imgPut":
            if let id = o["id"] as? String, let u = o["url"] as? String { Store.shared.putImage(id, dataURL: u) }
            reply(true)
        case "imgHas":
            reply(Store.shared.hasImage(a as? String ?? ""))
        case "imgDel":
            if let id = a as? String { Store.shared.deleteImage(id) }
            reply(true)
        case "fetch":
            Net.fetch(o) { reply($0) }
        case "ocr":
            OCR.run(o) { reply($0) }
        case "scan":
            if let h = host { h.scan(multi: o["multi"] as? Bool ?? false) { reply($0) } } else { reply(nil) }
        case "pdf":
            if let h = host { h.makePDF(o) { reply(["done": $0]) } } else { reply(["done": false]) }
        case "browse":
            if let h = host { h.browse(o) { reply($0) } } else { reply(nil) }
        case "share":
            if let h = host { h.share(a) { reply(["done": $0]) } } else { reply(["done": false]) }
        case "haptic":
            Haptics.play(a as? String)
            reply(nil)
        case "awake":
            UIApplication.shared.isIdleTimerDisabled = (a as? Bool) ?? false
            reply(nil)
        case "sound":
            Ambient.shared.set(a as? [String: Any])
            reply(nil)
        case "soundVol":
            Ambient.shared.setVolume(Float((a as? Double) ?? 0.6))
            reply(nil)
        case "notify":
            Notify.schedule(o)
            reply(nil)
        case "notifyCancel":
            Notify.cancel(a as? String ?? "")
            reply(nil)
        case "remind":
            Notify.remind(o) { reply(["granted": $0]) }
        case "widget":
            WidgetSync.write(o)
            reply(nil)
        case "la":
            LiveSession.handle(o)
            reply(nil)
        case "bar":
            host?.setBar(light: (a as? String) == "light")
            reply(nil)
        case "theme":
            host?.setTheme(a as? String)
            reply(nil)
        case "novel":
            let h = host
            Task { @MainActor in NovelBridge.handle(o, host: h) { reply($0) } }
        default:
            replyHandler(nil, "unknown command \(cmd)")
        }
    }
}
