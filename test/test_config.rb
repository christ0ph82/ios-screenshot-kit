# frozen_string_literal: true

require_relative "test_helper"

class TestConfig < Minitest::Test
  include KitTestHelpers

  def test_valid_config_builds
    Dir.mktmpdir do |root|
      config = build_config(root)
      assert_equal %w[alpha beta], config.surface_ids
      assert_equal "KITTEST_SCREENSHOT_SOURCE_DIR", config.env("SCREENSHOT_SOURCE_DIR")
      assert_equal File.join(root, "fastlane", "build", ".simulator-capture.lock"), config.lock_path
    end
  end

  def test_rejects_duplicate_surface_ids
    Dir.mktmpdir do |root|
      error = assert_raises(ScreenshotKit::Error) do
        build_config(root, surfaces: [
                       { id: "alpha", title: "A", fixture: "f", expected_focus: "e" },
                       { id: "alpha", title: "B", fixture: "f", expected_focus: "e" }
                     ])
      end
      assert_match(/duplicate surface ids: alpha/, error.message)
    end
  end

  def test_rejects_english_alias_overlap
    Dir.mktmpdir do |root|
      error = assert_raises(ScreenshotKit::Error) do
        build_config(root, locales: [{ asc: "en-CA", language: "en", region: "CA" }])
      end
      assert_match(/en-CA cannot be both/, error.message)
    end
  end

  def test_rejects_bad_device_pixels
    Dir.mktmpdir do |root|
      error = assert_raises(ScreenshotKit::Error) do
        build_config(root, devices: [{ name: "iPhone", pixels: [0, -3] }])
      end
      assert_match(/needs pixels/, error.message)
    end
  end

  def test_rejects_locale_missing_region
    Dir.mktmpdir do |root|
      error = assert_raises(ScreenshotKit::Error) do
        build_config(root, locales: [{ asc: "fr-CA", language: "fr-CA", region: "" }])
      end
      assert_match(/needs language and region/, error.message)
    end
  end

  def test_translation_base_asc_defaults_to_nil_and_accepts_a_row_or_an_alias
    Dir.mktmpdir do |root|
      assert_nil build_config(root).translation_base_asc
      assert_equal "fr-CA", build_config(root, translation_base_asc: "fr-CA").translation_base_asc
      assert_equal "en-US", build_config(root, translation_base_asc: "en-US").translation_base_asc
    end
  end

  def test_rejects_unknown_translation_base_asc
    Dir.mktmpdir do |root|
      error = assert_raises(ScreenshotKit::Error) do
        build_config(root, translation_base_asc: "de-DE")
      end
      assert_match(/translation_base_asc "de-DE" is neither/, error.message)
    end
  end


  # The capture run clears cache_dir wholesale, so a shared default would let
  # one product's run destroy another's captures. The default must therefore
  # be per-product, and live outside the legacy shared path that older-kit
  # adopters still wipe.
  def test_default_cache_dir_is_per_product_and_outside_the_legacy_shared_path
    Dir.mktmpdir do |root|
      one = build_config(root)
      two = build_config(root, product_name: "Other App")

      assert_equal File.join(Dir.home, "Library", "Caches", "screenshot-kit", "captures", "kit-test-app"),
                   one.cache_dir
      refute_equal one.cache_dir, two.cache_dir
      refute_match %r{tools\.fastlane}, one.cache_dir
    end
  end

  def test_default_staging_dir_is_where_snapshothelper_writes
    Dir.mktmpdir do |root|
      snapshot_helper_cache_path = File.join("Library", "Caches", "tools.fastlane") # getCacheDirectory()
      screenshots_subdirectory = "screenshots"                                      # screenshotsDirectory

      expected = File.join(Dir.home, snapshot_helper_cache_path, screenshots_subdirectory)
      assert_equal expected, build_config(root).staging_dir

      # Per-product, unlike cache_dir: the writer is machine-global.
      assert_equal build_config(root).staging_dir,
                   build_config(root, product_name: "Other App").staging_dir
      refute_equal build_config(root).cache_dir, build_config(root).staging_dir
    end
  end

  def test_rejects_relative_or_empty_staging_dir
    Dir.mktmpdir do |root|
      %w[relative/staging].push("").each do |bad|
        error = assert_raises(ScreenshotKit::Error) { build_config(root, staging_dir: bad) }
        assert_match(/staging_dir must be an absolute path/, error.message)
      end
    end
  end

  def test_rejects_staging_dir_equal_to_cache_dir
    Dir.mktmpdir do |root|
      error = assert_raises(ScreenshotKit::Error) do
        build_config(root, cache_dir: File.join(root, "captures"), staging_dir: File.join(root, "captures"))
      end
      assert_match(/staging_dir must not be cache_dir/, error.message)

      # Same directory reached by a different spelling is still the same
      # directory; the check normalizes before comparing.
      error = assert_raises(ScreenshotKit::Error) do
        build_config(root, cache_dir: File.join(root, "captures"),
                           staging_dir: File.join(root, "captures", ".", ""))
      end
      assert_match(/staging_dir must not be cache_dir/, error.message)
    end
  end

  def test_explicit_staging_dir_wins_over_the_default
    Dir.mktmpdir do |root|
      config = build_config(root, staging_dir: File.join(root, "staging"))
      assert_equal File.join(root, "staging"), config.staging_dir
    end
  end

  def test_explicit_cache_dir_wins_over_the_derived_default
    Dir.mktmpdir do |root|
      config = build_config(root, cache_dir: File.join(root, "my-cache"))
      assert_equal File.join(root, "my-cache"), config.cache_dir
    end
  end

  def test_device_slug
    assert_equal "ipad-pro-13-inch-m5", ScreenshotKit.device_slug("iPad Pro 13-inch (M5)")
    assert_equal "device", ScreenshotKit.device_slug("***")
  end

  def test_apple_locale_derivation_and_override
    derived = ScreenshotKit::KitLocale.new(asc: "fr-CA", language: "fr-CA", region: "CA", app_env: {})
    assert_equal "fr_CA_CA", derived.resolved_apple_locale

    overridden = ScreenshotKit::KitLocale.new(asc: "pt-BR", language: "pt-BR", region: "BR",
                                              app_env: {}, apple_locale: "pt_BR")
    assert_equal "pt_BR", overridden.resolved_apple_locale
  end
end

