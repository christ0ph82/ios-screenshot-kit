# External screenshots and Unity

The current built-in capture runner is for XCUITest on Xcode's iOS Simulator. Packaging and verification can consume PNGs from other producers without calling that runner. Unity is used here to illustrate how an adopter might reuse those pieces. These are research and adaptation notes, not a roadmap or a promise of Unity support. No Unity project or physical-device capture has been integration-tested with this kit; the adopter owns any integration, modifications, and validation.

## Existing PNG interface

Use one folder per App Store locale and one file per configured device/surface pair:

```text
captures/
  en-US/
    iPhone 16 Pro Max-home.png
    iPhone 16 Pro Max-level01.png
  fr-FR/
    iPhone 16 Pro Max-home.png
    iPhone 16 Pro Max-level01.png
```

For this example, configure device name `iPhone 16 Pro Max`, surfaces `home` and `level01`, both locales as explicit rows, `english_asc_locales: []`, and `translation_base_asc: "en-US"`. Create matching locale folders under `metadata_path`. Supply every configured device/locale/surface combination. Keep input outside the packaging output directory, which is replaced on every run.

Prefer the exact `<configured-device-name>-<surface-id>.png` format. A bare `home.png` becomes an unrecognized `device` group and can bypass dimension checks. Unknown PNG names are ignored; duplicate matches are errors. Avoid surface IDs that are suffixes of one another. Device labels express the target dimensions; they do not prove that an image came from that physical hardware.

Adapt the existing app config and call only the two downstream stages:

```ruby
require_relative "screenshot_config"

config = SCREENSHOT_CONFIG
ENV[config.env("SCREENSHOT_SOURCE_DIR")] = File.expand_path("../captures", __dir__)
ENV[config.env("REQUIRE_SCREENSHOT_SOURCE")] = "1"
ScreenshotKit::Packaging.new(config).run!("appstore")
ScreenshotKit::Verification.new(config).run!("appstore")
```

This snippet assumes it lives in the app's `fastlane/` directory. It never calls `ScreenshotKit::Capture`, launches Xcode, or uploads anything. The current Config constructor still requires the capture-related keyword arguments even though this path does not use them. A separate packaging-only config would simplify that interface.

Files outside `cache_dir` are verified against `pixels`, the configured upload size, rather than `capture_pixels`. The verifier compares an exact width/height pair. Configure landscape dimensions for landscape images; mixed orientations under one device label need additional handling. The kit neither rotates nor resizes images.

## Ways a Unity project could produce PNGs

| Approach | What the project supplies | Fit |
|---|---|---|
| Unity Editor Game view | A deterministic scene/fixture setup and Unity Recorder or a capture script, with explicit output dimensions | Quick iteration and producing a repeatable screenshot set without an Apple simulator |
| Unity player on an actual iPhone/iPad | An in-game capture mode, or device screenshots, plus a way to export the files | Validating the real iOS rendering, safe areas, native UI, and plugins |
| Unity iOS export in Xcode's Simulator | A simulator-compatible export, an XCUITest target/scheme, and reproducible game navigation/readiness | Reusing the existing Capture runner after project integration work |

[Unity ScreenCapture.CaptureScreenshot](https://docs.unity3d.com/6000.0/Documentation/ScriptReference/ScreenCapture.CaptureScreenshot.html) writes PNGs from the running game. Mobile output uses the persistent data location, so the integration must retrieve those files. [Unity Recorder](https://docs.unity3d.com/Packages/com.unity.recorder@5.1/manual/index.html) operates in Editor Play mode; its [image recorder](https://docs.unity3d.com/Packages/com.unity.recorder@5.1/manual/RecorderImage.html) supports custom width/height and PNG output. Capture the intended game UI as well as the scene, and wait for loading, localization, and rendering to finish.

Do not assume a headless build command can also capture images: Recorder documents that Editor `-batchmode` is unsupported, and it does not record Unity's Device Simulator view. See [Recorder limitations](https://docs.unity3d.com/Packages/com.unity.recorder@5.1/manual/KnownIssues.html). Unity's Device Simulator is also distinct from Apple's iOS Simulator; it is an Editor preview, not an execution of the iOS build.

Apple supports [screenshots from physical and simulated devices](https://developer.apple.com/documentation/xcode/capturing-screenshots-and-videos-from-devices). The restriction to simulators belongs to this kit's Capture implementation and SnapshotHelper, not to screenshot capture in general. A future physical-device runner would need a device destination, capture/export mechanism, and device-appropriate preparation in place of `simctl` and the simulator cache.

## Checks that need adapting for games

- **Status bar:** set `status_bar_guard: false` for full-screen gameplay or other images outside the heuristic's light iOS status-bar assumptions. The guard currently runs on supplied PNGs too; it does not infer whether they contain a status bar.
- **Localization:** identical images across different languages currently fail verification. A scene with no visible text can legitimately look identical. There is no per-surface language-neutral exemption; add a deliberate policy before relying on this check for a game. Do not fake language values or remove the comparison anchor to hide the failure.
- **Completeness:** `release_ready` does not enforce the full configured matrix when a device group is entirely absent. Add a strict expected-matrix check and reject unknown device labels before using a new producer for releases.
- **Rendering fidelity:** Editor screenshots can differ from the shipped iOS build in shaders, safe areas, native overlays, or plugins. Validate representative captures on the target platform. Apple's [screenshot guidance](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata) requires images to represent the app in use; an Editor export is not evidence of App Store acceptance.
- **Provenance:** the manifest records a source path and a broad source category. It does not attest to a Unity build, scene, fixture seed, or actual hardware. A Unity adapter should record those facts explicitly.

## Work an adopter would own

The smallest useful first step is a Unity-owned C# capture harness: choose scene/state, fixture seed, locale, and output size; wait for a known ready frame; write stable surface filenames; then invoke the existing Ruby packager. A device or platform validation pass should precede publishing. No simulator is needed for this initial PNG workflow.

Depending on the project, an adopter may want to separate capture settings from packaging settings, add strict matrix validation, and adapt verification policies for gameplay. Those changes and testing against the adopter's Unity project would be part of their integration work; they are not planned additions to this toolkit.

For app releases, Unity still [exports an Xcode project for iOS](https://docs.unity3d.com/6000.0/Documentation/Manual/how-unity-builds-ios-applications.html). Run export and any post-processing before Release Kit's archive stage. Configure the generated app scheme, replace Swift-oriented verification commands with Unity checks, and validate version/signing values. Keep the shared lanes' expected command-list keys unless also adapting the lanes. Workspace-based exports require adaptation because the current archive lane passes `project:`. Version discovery also needs testing against multi-target exports and paths containing spaces; it currently merges targets' settings and does not shell-escape the project/scheme arguments.

If using XCUITest capture, recreate test targets and bridges through repeatable post-processing because a fresh Unity export may overwrite manual project edits. Game scene objects may require an explicit testing bridge rather than native UI-element navigation. The app must also translate the requested locale and fixture settings into its Unity runtime; injecting Apple's locale arguments alone does not prove the game's localization package uses them.
