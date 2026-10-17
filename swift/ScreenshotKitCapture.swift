//
//  ScreenshotKitCapture.swift
//  SYNCED FROM screenshot-kit — do not edit in the consumer repo.
//  Update by running: ruby vendor/screenshot-kit/bin/screenshot_kit_sync <ui-test-dir>
//

import XCTest

/// Launch configuration for a screenshot test driven by the screenshot-kit
/// matrix runner. Call `ScreenshotKitLaunch.configure(app)` before adding the
/// app-specific fixture environment and calling `app.launch()`.
enum ScreenshotKitLaunch {
    /// Wires up SnapshotHelper and injects the capture locale.
    ///
    /// The language plumbing is belt and suspenders, and both halves have
    /// independently earned their place:
    ///
    /// - `setupSnapshot(app)` only injects `-AppleLanguages` when *snapshot*
    ///   drives the run and has set its `deviceLanguage` global. The kit
    ///   drives xcodebuild directly, so that global is empty and, without the
    ///   injection below, every capture comes out in English no matter what
    ///   `-testLanguage` was passed — a silent failure that looks like a
    ///   successful localized run.
    /// - The primary channel is the runner's environment:
    ///   `SCREENSHOT_KIT_LANGUAGE`/`SCREENSHOT_KIT_LOCALE`, forwarded by
    ///   xcodebuild from `TEST_RUNNER_`-prefixed variables the matrix runner
    ///   sets. The fallback is the runner's own preferred language, which is
    ///   what `-testLanguage` sets. Neither channel alone has proven reliable
    ///   across toolchains; together they have.
    /// - `-AppleLanguages` and `-AppleLocale` are NSUserDefaults *argument
    ///   domain* values, so they are launch **arguments**. Fixture knobs read
    ///   from `ProcessInfo.environment` are launch **environment**. The two
    ///   are not interchangeable and each silently no-ops in the other's
    ///   position.
    ///
    /// Per-locale fixture wording (store-facing strings the app renders
    /// verbatim) arrives as a JSON object in `SCREENSHOT_KIT_APP_ENV` and is
    /// merged into the app's launch environment.
    static func configure(_ app: XCUIApplication) {
        setupSnapshot(app)

        let environment = ProcessInfo.processInfo.environment
        let language = environment["SCREENSHOT_KIT_LANGUAGE"]
            ?? Locale.preferredLanguages.first
        if let language, !language.isEmpty {
            app.launchArguments += ["-AppleLanguages", "(\(language))"]
            let locale = environment["SCREENSHOT_KIT_LOCALE"]
                ?? language.replacingOccurrences(of: "-", with: "_")
            app.launchArguments += ["-AppleLocale", locale]
        }

        if let encoded = environment["SCREENSHOT_KIT_APP_ENV"],
           let data = encoded.data(using: .utf8),
           let extra = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            for (key, value) in extra {
                app.launchEnvironment[key] = value
            }
        }
    }
}

extension XCTestCase {
    /// Keep both screenshot consumers fed: the App Store lane reads the PNG
    /// written by SnapshotHelper, while the review lane exports named XCTest
    /// attachments from the result bundle. One call, both outputs — a capture
    /// that feeds only one lane is how the two sets drift.
    func captureScreenshot(named name: String) {
        snapshot(name)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

