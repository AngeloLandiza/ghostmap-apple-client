import XCTest

/// Runs on the connected device (`scripts/rm.sh test-ui`) — the simulator cannot run ARKit, so
/// these tests only cover screens reachable without the camera: the map list, Settings and the
/// Party screen's local validation. Every launch passes `-uiTesting`, which makes
/// `UITestStubURLProtocol` answer any HTTP(S) request instead of letting it reach a real backend
/// (see `App/Support/UITestSupport.swift`), so a flaky test bench network can never be why one of
/// these fails.
final class RoomMapperUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        return app
    }

    /// The app opens straight to the map list — no login wall, no onboarding — and the primary
    /// "Scan" action is there from the first frame, per `RootView`.
    func testLaunchesToMapList() {
        let app = launchedApp()
        XCTAssertTrue(app.navigationBars["Maps"].waitForExistence(timeout: 15), "should land on the map list")
        XCTAssertTrue(app.buttons["Scan"].exists, "the Scan action should be reachable immediately")
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    /// Settings works entirely without an account: the backend URL field is there to point the app
    /// at a different deployment, and Sign in with Google is offered (disabled or not, depending on
    /// whether this build has a client id) without ever needing to actually sign in.
    func testSettingsShowsBackendURLFieldAndSignInButton() {
        let app = launchedApp()
        XCTAssertTrue(app.navigationBars["Maps"].waitForExistence(timeout: 15))

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        let backendField = app.textFields["https://ghostmap-backend.vercel.app"]
        XCTAssertTrue(backendField.waitForExistence(timeout: 5), "the backend URL field should be visible")

        XCTAssertTrue(app.buttons["Sign in with Google"].waitForExistence(timeout: 5), "sign-in should be offered even signed out")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Maps"].waitForExistence(timeout: 5), "Done should return to the map list")
    }

    /// A malformed invite code never reaches the network: `PartyCode.isValid` gates the lookup
    /// locally (see `PartyView.lookUp`), so the button that would call the backend stays disabled
    /// and the screen never advances past "Look up code".
    func testPartyScreenRejectsMalformedCodeWithoutNetworking() {
        let app = launchedApp()
        XCTAssertTrue(app.navigationBars["Maps"].waitForExistence(timeout: 15))

        app.buttons["Parties"].tap()
        XCTAssertTrue(app.navigationBars["Parties"].waitForExistence(timeout: 10))

        let codeField = app.textFields["ABCD 2345"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 5), "the join-code field should be visible")
        codeField.tap()
        codeField.typeText("1!2?")

        let lookupButton = app.buttons["Look up code"]
        XCTAssertTrue(lookupButton.waitForExistence(timeout: 5), "the button stays 'Look up code' until a lookup actually succeeds")
        XCTAssertFalse(lookupButton.isEnabled, "a malformed code must not enable the network-triggering lookup")

        lookupButton.tap()
        XCTAssertFalse(app.buttons["Join party"].exists, "no lookup means no party summary to join")
        XCTAssertTrue(app.navigationBars["Parties"].exists, "still on the party screen, nothing crashed")
    }
}
