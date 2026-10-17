# frozen_string_literal: true

# The shared screenshot pipeline: XCUITest-driven capture, a per-device ×
# per-locale matrix runner, and packaging that refuses to call a partial or
# untranslated set release-ready.
#
# This library is deliberately fastlane-free. The capture side shells out to
# xcodebuild/simctl through an injected runner (a Fastfile passes fastlane's
# `sh`; anything else works too), and the packaging side runs under plain
# `ruby` in CI on Linux. Nothing here may `require "fastlane"`.
module ScreenshotKit
  class Error < StandardError; end
  class CommandFailed < Error; end
end

require_relative "screenshot_kit/version"
require_relative "screenshot_kit/shell"
require_relative "screenshot_kit/config"
require_relative "screenshot_kit/lock"
require_relative "screenshot_kit/simulator"
require_relative "screenshot_kit/xctestrun"
require_relative "screenshot_kit/capture"
require_relative "screenshot_kit/packaging"
require_relative "screenshot_kit/png_strip"
require_relative "screenshot_kit/verification"

