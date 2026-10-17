import XCTest

final class ScreenshotTests: XCTestCase {
    @MainActor
    func testCaptureHome() {
        continueAfterFailure = false
        let app = XCUIApplication()
        ScreenshotKitLaunch.configure(app)
        // Configure your app's non-sensitive fixture state before launch.
        app.launch()
        XCTAssertTrue(app.otherElements["home-screen"].waitForExistence(timeout: 15))
        captureScreenshot(named: "home")
    }
}
