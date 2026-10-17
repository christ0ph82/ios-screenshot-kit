# Screenshot Kit

XCUITest-driven iOS screenshot capture, packaging, and verification across devices and locales.

Your app owns a UI test that navigates to each screen and calls `captureScreenshot(named:)`. Screenshot Kit runs the test across a device/locale matrix, packages PNGs into App Store locale folders, and checks the resulting set. It also writes a manifest and an HTML contact sheet.

The Ruby library has no runtime gem dependencies and does not require fastlane. Capture requires macOS, Xcode, and installed simulators. Packaging, verification, and tests can run under Ruby 3.1 or later on Linux.

This repository is a source snapshot shared for developers to integrate into their own projects. Expect to configure the capture matrix, write app-specific tests or supply images, and adapt checks to your app. The examples are starting points rather than a turnkey setup.

## What works today

| Task | Current support |
|---|---|
| Automatically capture an iOS app through XCUITest | Built in; requires Xcode's iOS Simulator and an app-owned UI test. |
| Package existing PNGs from a device, Unity, or another capture tool | Supported by calling Packaging and Verification directly, without Capture or Xcode. Files must follow the documented naming and locale layout. |
| Capture on a physical iPhone/iPad | No built-in runner. Supply PNGs captured separately; the bundled SnapshotHelper cannot run on a physical device. |
| Capture inside Unity Editor or a Unity player | No Unity integration included. A Unity script or Recorder can produce PNGs for the existing packager. |
| Publish screenshots or release an app | Not part of this kit; use your upload tooling or the companion Release Kit. |
| Automate Android, desktop, Steam, or Google Play workflows | No built-in capture runner or store-specific packaging/upload integration. |

The PNG input path is reusable, while the output conventions and several checks are tailored to iOS App Store listings. See [external capture and adaptation notes](docs/external-capture-and-unity.md) for the existing import recipe and an illustration using Unity. Any Unity-specific capture, code changes, and validation belong to the adopting project; these notes are not a Unity support commitment or product roadmap.

## Setup

For a ZIP distribution, copy this directory to `vendor/screenshot-kit` in your app. To vendor it with Git, run this from your app's root:

```bash
git subtree add --prefix vendor/screenshot-kit https://github.com/christ0ph82/ios-screenshot-kit.git main --squash
```

Add to your app's `Gemfile`:

```ruby
gem "screenshot_kit", path: "vendor/screenshot-kit"
```

Run `bundle install`. Copy [examples/screenshot_config.rb](examples/screenshot_config.rb) to `fastlane/screenshot_config.rb` and replace the project, scheme, test identifier, device, and surfaces. The example uses explicit English and French locale rows. Create metadata folders, which drive packaging's locale discovery:

```bash
mkdir -p fastlane/metadata/en-US fastlane/metadata/fr-FR
ruby vendor/screenshot-kit/bin/screenshot_kit_sync ExampleAppUITests
```

Add the two copied Swift files to your UI-test target in Xcode. Filesystem-synchronized groups may do this automatically; the sync tool does not edit your project. Adapt [examples/ScreenshotTests.swift](examples/ScreenshotTests.swift) and add it to the same target. Replace its `home-screen` accessibility identifier with a real readiness check.

## Capture, package, verify

Copy [examples/run_screenshots.rb](examples/run_screenshots.rb) to `fastlane/run_screenshots.rb`, then run:

```bash
bundle exec ruby fastlane/run_screenshots.rb
```

The runner captures first, requires real sources, packages `appstore` output, and verifies it. It does not upload anything. Inspect the HTML contact sheet and PNGs before uploading through your preferred tool.

Device names must match installed simulators. Set `pixels` to the required upload dimensions. If a later composition step resizes raw captures, also set `capture_pixels`. The kit can verify raw dimensions but does not provide a poster composer or resizer. Confirm current App Store requirements for your device classes.

## Capture behavior

- Builds once with `build-for-testing`, then runs sequential device/locale passes with `test-without-building` by default.
- Sets a 9:41 status bar and configured appearance, and retries transient simulator failures.
- Uses repository-local and machine-wide locks. Other simulator tools must cooperate with the lock protocol to avoid contention.
- Writes both a SnapshotHelper PNG and a named XCTest attachment per capture.
- Separates transient staging from the durable per-product cache.

**Capture clears its configured cache and staging PNGs.** Use dedicated paths for artifacts you can regenerate. The default staging location is `~/Library/Caches/tools.fastlane/screenshots`; the cache is `~/Library/Caches/screenshot-kit/captures/<product-slug>`. Do not use the same directory for both. Packaging also replaces its mode's output directory.

The Swift helper forwards locale settings and `SCREENSHOT_KIT_APP_ENV` JSON to the app's launch configuration. Your tests own fixture setup, navigation, and readiness waits.

## Packaging and checks

Packaging matches captures by surface ID; IDs must match `captureScreenshot(named:)` names. Surface array order controls listing order. Locale folders come from `metadata_path`, excluding fastlane's non-locale folders.

English may use explicit locale rows with `english_asc_locales: []` and `translation_base_asc: "en-US"`, or one flat capture shared through `english_asc_locales`. Do not declare a locale in both lists. Locales sharing one language are exempt from translation byte-identity comparisons.

Packaging can generate reference placeholders when sources are optional. These are not release-ready. Set `<PREFIX>_REQUIRE_SCREENSHOT_SOURCE=1` on release paths, as the example does. Verification checks the manifest, dimensions, byte-identical translations, and raw-capture status-bar contamination. Byte comparisons flag suspicious localization; they cannot prove translation quality.

`release_ready` is a packaging claim, not proof of complete matrix coverage. For strict release gates, also compare the manifest against your expected devices, locales, and surfaces. Inspect missing device groups and unexpected device slugs: dimension checks apply to recognized configured devices. Review captures visually.

`Packaging#run!("review")` provides generic surface packaging in review mode. Appearance variants, accessibility matrices, attachment export, and image composition require app-specific integration. [Release Kit](https://github.com/christ0ph82/ios-release-kit) can orchestrate broader fastlane workflows.

## Updates and development

```bash
git subtree pull --prefix vendor/screenshot-kit https://github.com/christ0ph82/ios-screenshot-kit.git main --squash
ruby vendor/screenshot-kit/bin/screenshot_kit_sync ExampleAppUITests
ruby vendor/screenshot-kit/bin/screenshot_kit_sync ExampleAppUITests --check
```

For a ZIP distribution, copy its directory to `vendor/screenshot-kit` and use the same path-gem setup. Subtree updates require a Git remote.

In the kit's checkout:

```bash
bundle install
bundle exec ruby -Ilib test/run_tests.rb
```

Use a UTF-8 shell locale (for example `LANG=en_US.UTF-8` on macOS). Manifest reads currently rely on the default external encoding; a US-ASCII shell can fail on non-ASCII content.

Tests exercise Ruby logic and generated PNG fixtures. Live capture needs validation against your Xcode project and simulator runtime. When changing shared Swift sources, bump the version and sync consumers again.

MIT licensed. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md) for Fastlane's SnapshotHelper attribution.
