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

/// Links into the app (the widgets): wird://open?book=<id>, wird://open?tab=<tab>.
@MainActor
enum DeepLink {
    static func open(_ url: URL) {
        var q: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        let r = Router.shared
        if let t = q["tab"].flatMap(Router.Tab.init(rawValue:)) { r.select(t) }
        if let b = q["book"], let book = Library.shared.state.book(b) {
            r.select(.library)
            r.paths[.library] = []
            if let n = book.novel { r.openNovel(n.novelID, book: book.id) } else { r.push(.book(book.id), in: .library) }
        }
    }
}
