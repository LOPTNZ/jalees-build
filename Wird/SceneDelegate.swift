import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let vc = RootController()
        window.rootViewController = vc
        window.backgroundColor = UIColor(named: "LaunchBG")
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in
            NovelBridge.host = vc
            _ = Library.shared
            if let url = connectionOptions.urlContexts.first?.url { open(url) }
            DebugRoute.run()
        }
    }

    // widget taps: wird://open?book=<id>; EPUB files opened in Jalees from the Files app
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        Task { @MainActor in open(url) }
    }

    @MainActor private func open(_ url: URL) {
        if url.isFileURL { NovelBridge.importEpub(url) } else { DeepLink.open(url) }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        Task { @MainActor in Library.shared.saveNow() }
    }
}

/// Links into the app (the widgets, as the web's wirdOpen): wird://session (the running session),
/// wird://open?book=<id> (the library with that book in the middle), wird://open?quote=<book>:<quote> (that quote
/// in the notebook), wird://open?tab=<tab>.
@MainActor
enum DeepLink {
    static func open(_ url: URL) {
        var q: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        let r = Router.shared
        Present.shared.modal = nil
        if url.host == "session" || q["session"] != nil {
            if SessionModel.shared.timer != nil { SessionModel.shared.open() }
            return
        }
        if let b = q["book"], Library.shared.state.book(b) != nil {
            r.paths[.library] = []
            if r.tab != .library { r.select(.library) }
            CarouselCenter.shared.id = b
            return
        }
        if q["quote"] != nil || q["tab"] == "notebook" {
            let p = (q["quote"] ?? "").split(separator: ":").map(String.init)
            r.paths[.notebook] = []
            if r.tab != .notebook { r.select(.notebook) }
            NotebookNav.shared.show(book: nil, kind: "quotes")
            if p.count == 2, let b = Library.shared.state.book(p[0]), b.items(.quote).contains(where: { $0.id == p[1] }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Flows.note(b.id, kind: "edit:quote:" + p[1]) }
            }
            return
        }
        if let t = q["tab"].flatMap(Router.Tab.init(rawValue:)), r.tab != t { r.select(t) }
    }
}
