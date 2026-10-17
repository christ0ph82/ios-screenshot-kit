# frozen_string_literal: true

require_relative "test_helper"
require_relative "test_png_strip"
require "json"

class TestVerification < Minitest::Test
  include KitTestHelpers

  IPHONE = "iPhone 17 Pro Max"

  # Builds a packaged-looking output dir + manifest by hand, so verification is
  # tested against exactly the layout packaging writes.
  # `source_dir` is positional, not a keyword: most call sites pass their
  # locale hash bare, and a keyword parameter would swallow it as kwargs.
  def build_output(root, config, locale_shots, source_dir = "/captures")
    output = config.output_dir("appstore")
    shots = []
    locale_shots.each do |locale, surfaces|
      surfaces.each_with_index do |(id, seed, pixels), index|
        filename = "iphone-17-pro-max-#{format("%02d", index + 1)}-#{id}.png"
        path = File.join(output, locale, filename)
        write_capture(path, width: pixels[0], height: pixels[1], seed: seed)
        shots << { "id" => id, "route" => id, "ui_test_route" => id, "fixture" => "f",
                   "expected_focus" => "e", "device" => IPHONE, "locale" => locale,
                   "appearance" => "light", "file" => File.join(locale, filename) }
      end
    end
    manifest = {
      "schema_version" => 2, "kit_version" => ScreenshotKit::VERSION, "mode" => "appstore",
      "generated_at" => Time.now.utc.iso8601, "devices" => [IPHONE],
      "locales" => locale_shots.keys, "appearance" => "light", "source" => "provided-png",
      "release_ready" => true, "source_dir" => source_dir,
      "expected_per_locale_per_device" => locale_shots.values.first.length,
      "screenshots" => shots
    }
    FileUtils.mkdir_p(output)
    File.write(File.join(output, "manifest.json"), JSON.generate(manifest))
    output
  end

  # The packaging placeholder writer paints dark bands, which would trip the
  # status-bar guard on every fixture; the guard gets dedicated tests with
  # controlled pixels, and stays off elsewhere.
  def iphone_config(root, status_bar_guard: false)
    build_config(root, devices: [{ name: IPHONE, pixels: [64, 128] }], status_bar_guard: status_bar_guard)
  end

  def test_passes_on_clean_output
    Dir.mktmpdir do |root|
      config = iphone_config(root)
      build_output(root, config,
                   "en-CA" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]],
                   "en-US" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]],
                   "fr-CA" => [["alpha", 11, [64, 128]], ["beta", 12, [64, 128]]],
                   "hi" => [["alpha", 21, [64, 128]], ["beta", 22, [64, 128]]])
      report = ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      assert report.ok?
      assert_empty report.warnings
    end
  end

  def test_wrong_dimensions_fail
    Dir.mktmpdir do |root|
      config = iphone_config(root)
      build_output(root, config, "en-CA" => [["alpha", 1, [64, 96]]])
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/64x96, expected 64x128/, error.message)
    end
  end

  def test_locale_identical_to_english_fails
    Dir.mktmpdir do |root|
      config = iphone_config(root)
      # fr-CA reuses English's seeds byte-for-byte: captured in English.
      build_output(root, config,
                   "en-CA" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]],
                   "fr-CA" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]])
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/Locale fr-CA: 2 of 2 capture\(s\) byte-identical to en-CA/, error.message)
    end
  end

  def test_locale_identical_except_one_jittery_surface_still_fails
    Dir.mktmpdir do |root|
      config = iphone_config(root)
      # The failure shape that slipped through the first shipped check: the
      # language injection failed, every text surface is English, but one
      # nondeterministic surface (map tiles) differs by a few bytes per pass.
      # Whole-set comparison called this "not identical" and passed it.
      build_output(root, config,
                   "en-CA" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]],
                   "fr-CA" => [["alpha", 1, [64, 128]], ["beta", 99, [64, 128]]])
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/Locale fr-CA: 1 of 2 capture\(s\) byte-identical to en-CA \(iphone-17-pro-max-01-alpha\.png\)/,
                   error.message)
    end
  end

  def test_two_identical_localized_locales_warn
    Dir.mktmpdir do |root|
      config = iphone_config(root)
      build_output(root, config,
                   "en-CA" => [["alpha", 1, [64, 128]]],
                   "fr-CA" => [["alpha", 40, [64, 128]]],
                   "hi" => [["alpha", 40, [64, 128]]])
      ui = RecordingUI.new
      report = ScreenshotKit::Verification.new(config, ui: ui).run!("appstore")
      assert report.ok?
      assert(report.warnings.any? { |warning| warning.include?("fr-CA and hi") })
    end
  end

  # A matrix that ships English as explicit App Store rows (each with its own
  # store wording) declares no aliases, so there is no alias for the
  # translation check to anchor on and it must be told the base.
  def english_rows_config(root, overrides = {})
    build_config(root, {
      devices: [{ name: IPHONE, pixels: [64, 128] }],
      status_bar_guard: false,
      english_asc_locales: [],
      locales: [
        { asc: "en-US", language: "en", region: "US" },
        { asc: "en-GB", language: "en", region: "GB" },
        { asc: "en-AU", language: "en", region: "AU" },
        { asc: "fr-CA", language: "fr-CA", region: "CA" },
        { asc: "hi", language: "hi", region: "IN" }
      ],
      translation_base_asc: "en-US"
    }.merge(overrides))
  end

  def test_translation_base_catches_a_locale_captured_in_the_base_language
    Dir.mktmpdir do |root|
      config = english_rows_config(root)
      # Without an anchor this matrix passed unchecked; fr-CA reuses en-US's
      # seeds byte-for-byte, so its language never reached the app.
      build_output(root, config,
                   "en-US" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]],
                   "en-GB" => [["alpha", 3, [64, 128]], ["beta", 4, [64, 128]]],
                   "fr-CA" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]])
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/Locale fr-CA: 2 of 2 capture\(s\) byte-identical to en-US/, error.message)
    end
  end

  def test_same_language_rows_may_be_identical_to_the_base
    Dir.mktmpdir do |root|
      config = english_rows_config(root)
      # en-GB is a separate store row served by the same `en` catalog: equal
      # pixels are the designed outcome, not a failed injection.
      build_output(root, config,
                   "en-US" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]],
                   "en-GB" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]],
                   "fr-CA" => [["alpha", 11, [64, 128]], ["beta", 12, [64, 128]]])
      report = ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      assert report.ok?, "same-language rows must not error: #{report.errors.join("; ")}"
      assert_empty report.warnings
    end
  end

  def test_pairwise_warning_skips_same_language_pairs_only
    Dir.mktmpdir do |root|
      config = english_rows_config(root)
      build_output(root, config,
                   "en-US" => [["alpha", 1, [64, 128]]],
                   "en-GB" => [["alpha", 3, [64, 128]]],
                   "en-AU" => [["alpha", 3, [64, 128]]],
                   "fr-CA" => [["alpha", 40, [64, 128]]],
                   "hi" => [["alpha", 40, [64, 128]]])
      ui = RecordingUI.new
      report = ScreenshotKit::Verification.new(config, ui: ui).run!("appstore")
      assert report.ok?, report.errors.join("; ")
      assert_equal 1, report.warnings.length, report.warnings.join("; ")
      assert_includes report.warnings.first, "fr-CA and hi"
    end
  end

  def test_translation_base_falls_back_to_a_captured_english_alias
    Dir.mktmpdir do |root|
      # The named base was not captured at all (en-CA-only run); the alias
      # scan still anchors the check rather than skipping it.
      config = build_config(root, devices: [{ name: IPHONE, pixels: [64, 128] }],
                                  status_bar_guard: false, translation_base_asc: "en-US")
      build_output(root, config,
                   "en-CA" => [["alpha", 1, [64, 128]]],
                   "fr-CA" => [["alpha", 1, [64, 128]]])
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/byte-identical to en-CA/, error.message)
    end
  end

  def test_not_release_ready_fails
    Dir.mktmpdir do |root|
      config = iphone_config(root)
      output = build_output(root, config, "en-CA" => [["alpha", 1, [64, 128]]])
      manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
      manifest["release_ready"] = false
      manifest["source"] = "deterministic-fixture-reference"
      File.write(File.join(output, "manifest.json"), JSON.generate(manifest))

      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/not release-ready/, error.message)
    end
  end

  def test_status_bar_intruder_is_flagged_against_device_baseline
    Dir.mktmpdir do |root|
      config = iphone_config(root, status_bar_guard: true)
      output = build_output(root, config,
                            "en-CA" => [["alpha", 1, [64, 128]], ["beta", 2, [64, 128]]],
                            "fr-CA" => [["alpha", 11, [64, 128]], ["beta", 12, [64, 128]]])
      # Repaint one file with a dark block in the breadcrumb region; the
      # placeholder writer's own banding stays below the margin for the rest.
      strip_test = TestPngStrip.new("repaint")
      strip_test.write_png(File.join(output, "fr-CA", "iphone-17-pro-max-02-beta.png"),
                           width: 64, height: 128, dark_rect: { x: 2, y: 4, w: 16, h: 3 })
      # Rewrite the rest as clean flat images so the baseline is uniform.
      [["en-CA", "01-alpha"], ["en-CA", "02-beta"], ["fr-CA", "01-alpha"]].each do |locale, suffix|
        strip_test.write_png(File.join(output, locale, "iphone-17-pro-max-#{suffix}.png"),
                             width: 64, height: 128)
      end

      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/Status-bar intruder/, error.message)
      assert_match(/iphone-17-pro-max-02-beta\.png/, error.message)
    end
  end

  def test_status_bar_guard_can_be_disabled
    Dir.mktmpdir do |root|
      config = build_config(root, devices: [{ name: IPHONE, pixels: [64, 128] }], status_bar_guard: false)
      output = build_output(root, config, "en-CA" => [["alpha", 1, [64, 128]]])
      strip_test = TestPngStrip.new("repaint")
      strip_test.write_png(File.join(output, "en-CA", "iphone-17-pro-max-01-alpha.png"),
                           width: 64, height: 128, dark_rect: { x: 2, y: 4, w: 16, h: 3 })
      report = ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      assert report.ok?
    end
  end

  CAPTURE_PIXELS = [72, 144].freeze
  UPLOAD_PIXELS = [64, 128].freeze

  def composed_config(root, capture_pixels: CAPTURE_PIXELS)
    build_config(root,
                 devices: [{ name: IPHONE, pixels: UPLOAD_PIXELS, capture_pixels: capture_pixels }.compact],
                 status_bar_guard: false,
                 cache_dir: File.join(root, "capture-cache"))
  end

  def test_package_built_from_the_capture_cache_is_held_to_capture_pixels
    Dir.mktmpdir do |root|
      config = composed_config(root)
      build_output(root, config, { "en-CA" => [["alpha", 1, CAPTURE_PIXELS]] }, config.cache_dir)
      report = ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      assert report.ok?, report.errors.join("; ")
    end
  end

  # Same files, different provenance: a composed poster tree is the upload
  # itself, so capture pixels are exactly what must not ship.
  def test_capture_sized_files_from_an_external_source_still_fail
    Dir.mktmpdir do |root|
      config = composed_config(root)
      build_output(root, config, { "en-CA" => [["alpha", 1, CAPTURE_PIXELS]] },
                   File.join(root, "composed"))
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/72x144, expected 64x128/, error.message)
      assert_match(/App Store Connect rejects non-native sizes/, error.message)
    end
  end

  # Capture mode is not a free pass: a cache package whose files are some
  # third size is still wrong, and the message says which expectation applied.
  def test_capture_mode_rejects_a_file_that_is_not_capture_sized
    Dir.mktmpdir do |root|
      config = composed_config(root)
      build_output(root, config, { "en-CA" => [["alpha", 1, UPLOAD_PIXELS]] }, config.cache_dir)
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/64x128, expected 72x144 \(capture size; this package was built from the raw capture cache\)/,
                   error.message)
      refute_match(/App Store Connect rejects/, error.message)
    end
  end

  # A repo that uploads what it captures declares no capture_pixels, and
  # provenance must make no difference to it.
  def test_device_without_capture_pixels_behaves_identically_in_both_modes
    Dir.mktmpdir do |root|
      config = composed_config(root, capture_pixels: nil)
      [config.cache_dir, File.join(root, "composed")].each do |source_dir|
        build_output(root, config, { "en-CA" => [["alpha", 1, UPLOAD_PIXELS]] }, source_dir)
        report = ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
        assert report.ok?, "#{source_dir}: #{report.errors.join("; ")}"

        build_output(root, config, { "en-CA" => [["alpha", 1, CAPTURE_PIXELS]] }, source_dir)
        error = assert_raises(ScreenshotKit::Error) do
          ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
        end
        assert_match(/72x144, expected 64x128/, error.message)
        assert_match(/App Store Connect rejects non-native sizes/, error.message)
      end
    end
  end

  # An old manifest predates the key entirely; unknown provenance is verified
  # strictly, as the upload it is presumed to be.
  def test_manifest_without_source_dir_is_verified_in_upload_mode
    Dir.mktmpdir do |root|
      config = composed_config(root)
      output = build_output(root, config, { "en-CA" => [["alpha", 1, CAPTURE_PIXELS]] },
                            config.cache_dir)
      manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
      manifest.delete("source_dir")
      File.write(File.join(output, "manifest.json"), JSON.generate(manifest))

      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/App Store Connect rejects non-native sizes/, error.message)
    end
  end

  def test_manifest_naming_a_missing_file_fails
    Dir.mktmpdir do |root|
      config = iphone_config(root)
      output = build_output(root, config, "en-CA" => [["alpha", 1, [64, 128]]])
      File.delete(File.join(output, "en-CA", "iphone-17-pro-max-01-alpha.png"))
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Verification.new(config, ui: RecordingUI.new).run!("appstore")
      end
      assert_match(/does not exist/, error.message)
    end
  end
end

