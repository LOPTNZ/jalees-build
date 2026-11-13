import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var web: WebViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let vc = WebViewController()
        if let url = connectionOptions.urlContexts.first?.url {
            if url.isFileURL { pendingFile = url } else { vc.pendingURL = url }
        }
        window.rootViewController = vc
        window.backgroundColor = UIColor(named: "LaunchBG")
        window.makeKeyAndVisible()
        self.window = window
        self.web = vc
        NovelBridge.host = vc
        DebugRoute.run(vc)
    }

    /// An EPUB handed over by the Files app before the library page was ready.
    private var pendingFile: URL?

    // widget taps: wird://open?book=<id>; EPUB files opened in Jalees from the Files app
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        if url.isFileURL { Task { @MainActor in NovelBridge.importEpub(url) } } else {
            // a widget opens a book in the library: the novels' screens step away first, so the book is seen
            Task { @MainActor in NovelBridge.toLibrary() }
            web?.handleDeepLink(url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        web?.resumed()
        if let f = pendingFile {
            pendingFile = nil
            Task { @MainActor in
                await DebugRoute.waitForLibrary()
                NovelBridge.importEpub(f)
            }
        }
    }
}
