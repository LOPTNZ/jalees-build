import XCTest
@testable import Wird

/// The owner's server answers over plain http on a Tailscale address (100.64–127.x.x). On 2.2.1 iOS refused it with
/// -1022 (App Transport Security) while Safari opened it. The build machine serves http://100.64.0.1:8790/health on
/// an address of that range (tools/build-repo/sim.yml); these tests run inside the app, under its own Info.plist.
final class NetworkTests: XCTestCase {
    private let base = "http://100.64.0.1:8790"

    private func get(_ path: String) async throws -> (Data, Int) {
        var r = URLRequest(url: URL(string: base + path)!, timeoutInterval: 8)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let e as URLError where [.cannotConnectToHost, .timedOut, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(e.code) {
            throw XCTSkip("no test server on \(base) (\(e.code.rawValue))")
        }
    }

    func testPlainHTTPOnATailscaleAddressIsAllowed() async throws {
        do {
            let (d, code) = try await get("/health")
            XCTAssertEqual(code, 200)
            XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("\"ok\""))
        } catch let e as URLError where e.code == .appTransportSecurityRequiresSecureConnection {
            XCTFail("App Transport Security still refuses plain http to \(base): \(e)")
        }
    }

    @MainActor
    func testServerDiagnosisReachesTheServer() async throws {
        // the address only: the diagnosis stops after reaching it and asks for the token (none is set here)
        _ = try await get("/health")
        let before = (DB.shared.get("server.url"), DB.shared.get("server.token"))
        defer { DB.shared.set("server.url", before.0); DB.shared.set("server.token", before.1) }
        ServerLink.url = base
        DB.shared.set("server.token", nil)
        let said = await ServerLink.diagnose()
        // with no Tailscale on the build machine the diagnosis says so first; that is not what is checked here
        if said.contains("Tailscale مو شغّال") { throw XCTSkip("the simulator has no 100.x address of its own") }
        XCTAssertTrue(said.contains("وصلت للسيرفر"), said)
    }
}
