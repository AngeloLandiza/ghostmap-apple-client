import Foundation

/// Makes the app safe to drive from `RoomMapperUITests` without a real backend.
///
/// `scripts/rm.sh test-ui` launches the app with the `-uiTesting` argument; everything else about
/// the app is unchanged, including running on the connected device rather than a simulator (the
/// simulator cannot run ARKit — see TESTING.md). With that argument present, every HTTP(S) request
/// this process makes is answered locally instead of leaving the phone, so a test never depends on
/// (or waits on) whatever network the test bench happens to have.
enum UITestSupport {
    /// Call once, as early in launch as possible — before `AppEnvironment` creates any
    /// `URLSession` — so every session it builds picks up the registered protocol.
    static func activateIfNeeded(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("-uiTesting") else { return }
        URLProtocol.registerClass(UITestStubURLProtocol.self)
    }
}

/// Answers every HTTP(S) request with a canned response instead of touching the network.
///
/// `URLProtocol.registerClass` is honored by `URLSession` tasks built from a `.default`
/// configuration (every session in this app, including `GhostmapAPI`'s and `MapUploader`'s), so
/// registering this once at launch is enough — no session needs to know it exists.
final class UITestStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let status: Int
        let body: Data
        if url.path.hasSuffix("/health") {
            status = 200
            body = Data("""
            {"ok":true,"configured":true,"service":"ghostmap-backend-stub","version":"0.0.0-uitest"}
            """.utf8)
        } else {
            // No UI test needs a real response body yet: everything past health (sign-in, maps,
            // parties) needs an account, and none of the three flows this target covers signs one
            // in. A stubbed 501 fails loudly instead of hanging, if a future test reaches further.
            status = 501
            body = Data("""
            {"error":{"code":"stubbed","message":"UI testing: network is stubbed"}}
            """.utf8)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
