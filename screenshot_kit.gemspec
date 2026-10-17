# frozen_string_literal: true

require_relative "lib/screenshot_kit/version"

Gem::Specification.new do |spec|
  spec.name = "screenshot_kit"
  spec.version = ScreenshotKit::VERSION
  spec.authors = ["Christoph Sherry"]
  spec.summary = "XCUITest-driven App Store screenshot capture, packaging, and verification"
  spec.description = <<~DESC
    XCUITest-driven iOS screenshot capture, packaging, and verification
    across devices and locales. Distributed as a subtree-vendored path gem.
  DESC
  spec.homepage = "https://github.com/christ0ph82/ios-screenshot-kit"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  # Zero runtime dependencies, deliberately. The packaging CLI runs in CI via
  # plain `ruby` on ubuntu; the capture side shells out to xcodebuild/simctl on
  # a Mac. Nothing here may require fastlane — consumers hand in their own
  # command runner and UI.
  spec.files = Dir["lib/**/*.rb", "swift/*.swift", "bin/*", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "licenses/*", "examples/**/*", "docs/**/*.md"]
  spec.bindir = "bin"
  spec.executables = ["screenshot_kit_sync"]
end

