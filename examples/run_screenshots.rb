# frozen_string_literal: true
require_relative "screenshot_config"

config = SCREENSHOT_CONFIG
cache = ScreenshotKit::Capture.new(config).run!
ENV[config.env("SCREENSHOT_SOURCE_DIR")] = cache
ENV[config.env("REQUIRE_SCREENSHOT_SOURCE")] = "1"
ScreenshotKit::Packaging.new(config).run!("appstore")
ScreenshotKit::Verification.new(config).run!("appstore")
