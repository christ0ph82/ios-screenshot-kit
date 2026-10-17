# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/screenshot_kit"

module KitTestHelpers
  # A tiny but real config over a tmpdir. Device pixels are small so packaging
  # tests can write real PNGs fast; the dimensions are still enforced exactly.
  def build_config(root, overrides = {})
    defaults = {
      root: root,
      env_prefix: "KITTEST",
      product_name: "Kit Test App",
      project: "App/App.xcodeproj",
      ui_test_scheme: "AppUITests",
      only_testing: "AppUITests/ScreenshotTests",
      derived_data: File.join("fastlane", "build", "DerivedData"),
      devices: [
        { name: "iPhone 17 Pro Max", pixels: [64, 128] },
        { name: "iPad Pro 13-inch (M5)", pixels: [96, 128] }
      ],
      locales: [
        { asc: "fr-CA", language: "fr-CA", region: "CA" },
        { asc: "hi", language: "hi", region: "IN" }
      ],
      english_asc_locales: %w[en-CA en-US],
      surfaces: [
        { id: "alpha", title: "Alpha", fixture: "fixture a", expected_focus: "focus a" },
        { id: "beta", title: "Beta", fixture: "fixture b", expected_focus: "focus b" }
      ],
      output_root: File.join("fastlane", "build", "screenshots"),
      metadata_path: File.join("fastlane", "metadata")
    }
    ScreenshotKit::Config.new(**defaults.merge(overrides))
  end

  # The metadata directory drives packaging's locale discovery.
  def seed_metadata(root, locales)
    locales.each { |locale| FileUtils.mkdir_p(File.join(root, "fastlane", "metadata", locale)) }
    FileUtils.mkdir_p(File.join(root, "fastlane", "metadata", "review_information"))
  end

  # Writes a real PNG of the given dimensions with content varied by seed, so
  # distinctness checks see genuinely different bytes.
  def write_capture(path, width:, height:, seed: 0)
    FileUtils.mkdir_p(File.dirname(path))
    packaging = ScreenshotKit::Packaging.allocate
    packaging.send(:write_png, path, width: width, height: height,
                                     palette_index: seed, title: "t#{seed}", subtitle: "s#{seed}")
  end

  # A quiet UI that records instead of printing, and raises like fastlane's.
  class RecordingUI
    attr_reader :importants, :messages, :successes

    def initialize
      @importants = []
      @messages = []
      @successes = []
    end

    def header(_text); end
    def message(text) = @messages << text
    def important(text) = @importants << text
    def success(text) = @successes << text
    def user_error!(text) = raise(ScreenshotKit::Error, text)
  end
end

