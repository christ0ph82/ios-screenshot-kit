# frozen_string_literal: true
require "screenshot_kit"

# Copy to fastlane/screenshot_config.rb; match your app and simulator.
SCREENSHOT_CONFIG = ScreenshotKit::Config.new(
  root: File.expand_path("..", __dir__),
  product_name: "ExampleApp",
  env_prefix: "EXAMPLE",
  project: "ExampleApp/ExampleApp.xcodeproj",
  ui_test_scheme: "ExampleAppUITests",
  only_testing: "ExampleAppUITests/ScreenshotTests",
  derived_data: "fastlane/build/DerivedData",
  devices: [{ name: "iPhone 16 Pro Max", pixels: [1320, 2868] }],
  locales: [
    { asc: "en-US", language: "en", region: "US" },
    { asc: "fr-FR", language: "fr", region: "FR" }
  ],
  english_asc_locales: [],
  translation_base_asc: "en-US",
  surfaces: [
    { id: "home", title: "Home", fixture: "Sample content",
      expected_focus: "Localized home screen with fixture data" }
  ],
  output_root: "fastlane/build/screenshots",
  metadata_path: "fastlane/metadata"
)
