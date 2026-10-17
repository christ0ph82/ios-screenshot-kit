# frozen_string_literal: true

require_relative "test_helper"
require "json"

class TestPackaging < Minitest::Test
  include KitTestHelpers

  IPHONE = "iPhone 17 Pro Max"
  IPAD = "iPad Pro 13-inch (M5)"

  # `seed_flat: false` produces the shape a matrix with no English aliases
  # actually leaves behind: per-locale directories and an empty flat cache.
  def with_packaged(overrides: {}, locales: %w[en-CA en-US fr-CA hi], seed_sources: true, seed_flat: true, env: {})
    Dir.mktmpdir do |root|
      config = build_config(root, overrides)
      seed_metadata(root, locales)
      source_dir = File.join(root, "captures")

      if seed_sources
        # Flat English (SnapshotHelper naming), both devices.
        [[IPHONE, [64, 128]], [IPAD, [96, 128]]].each_with_index do |(device, pixels), device_index|
          if seed_flat
            config.surface_ids.each_with_index do |id, surface_index|
              write_capture(File.join(source_dir, "#{device}-#{id}.png"),
                            width: pixels[0], height: pixels[1], seed: device_index * 10 + surface_index)
            end
          end
          # Localized subdirectories with distinct bytes.
          %w[fr-CA hi].each_with_index do |asc, locale_index|
            config.surface_ids.each_with_index do |id, surface_index|
              write_capture(File.join(source_dir, asc, "#{device}-#{id}.png"),
                            width: pixels[0], height: pixels[1],
                            seed: 100 + device_index * 20 + locale_index * 5 + surface_index)
            end
          end
        end
      end

      stash = {}
      resolved_env = { config.env("SCREENSHOT_SOURCE_DIR") => source_dir }.merge(env)
      resolved_env.each do |key, value|
        stash[key] = ENV[key]
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
      begin
        ui = RecordingUI.new
        manifest = ScreenshotKit::Packaging.new(config, ui: ui).run!("appstore")
        yield config, manifest, ui, root
      ensure
        stash.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end
    end
  end

  def test_full_capture_is_release_ready_and_english_locales_share_flat_files
    with_packaged do |config, manifest, _ui, _root|
      assert_equal true, manifest["release_ready"]
      assert_equal "provided-png", manifest["source"]
      assert_equal %w[en-CA en-US fr-CA hi], manifest["locales"]
      assert_equal ScreenshotKit::VERSION, manifest["kit_version"]

      output = config.output_dir("appstore")
      en_ca = File.binread(File.join(output, "en-CA", "iphone-17-pro-max-01-alpha.png"))
      en_us = File.binread(File.join(output, "en-US", "iphone-17-pro-max-01-alpha.png"))
      fr = File.binread(File.join(output, "fr-CA", "iphone-17-pro-max-01-alpha.png"))
      assert_equal en_ca, en_us, "English locales must share the flat capture"
      refute_equal en_ca, fr, "localized locale must come from its own directory"
    end
  end

  # Verification reads this to tell a package built straight from the raw
  # capture cache (capture-sized files) from one built from a composed tree
  # (upload-sized files), so it has to be the absolute, normalized path or the
  # comparison against cache_dir misses and the package is verified in the
  # wrong mode.
  def test_manifest_records_the_absolute_source_dir
    with_packaged do |_config, manifest, _ui, root|
      assert_equal File.join(root, "captures"), manifest["source_dir"]
    end
  end

  def test_manifest_source_dir_is_normalized
    Dir.mktmpdir do |root|
      canonical = File.join(root, "captures")
      config = build_config(root)
      seed_metadata(root, %w[en-US])
      write_capture(File.join(canonical, "#{IPHONE}-alpha.png"), width: 64, height: 128, seed: 1)
      ENV[config.env("SCREENSHOT_SOURCE_DIR")] = File.join(canonical, ".", "")
      begin
        manifest = ScreenshotKit::Packaging.new(config, ui: RecordingUI.new).run!("appstore")
        assert_equal canonical, manifest["source_dir"]
        on_disk = JSON.parse(File.read(File.join(config.output_dir("appstore"), "manifest.json")))
        assert_equal canonical, on_disk["source_dir"], "the key must land in the manifest on disk too"
      ensure
        ENV.delete(config.env("SCREENSHOT_SOURCE_DIR"))
      end
    end
  end

  # File.expand_path("") is the working directory, which was never a source.
  def test_manifest_source_dir_stays_empty_when_nothing_was_captured
    with_packaged(seed_sources: false, env: { "KITTEST_SCREENSHOT_SOURCE_DIR" => nil }) do |_c, manifest, _u, _r|
      assert_nil manifest["source_dir"]
    end
  end

  def test_missing_localized_locale_fails_when_source_required
    error = assert_raises(ScreenshotKit::Error) do
      with_packaged(locales: %w[en-CA en-US fr-CA hi pa-IN],
                    env: { "KITTEST_REQUIRE_SCREENSHOT_SOURCE" => "1" }) { |_c, _m, _u, _r| }
    end
    assert_match %r{pa-IN/\(no captures\)/alpha}, error.message
  end

  def test_missing_locale_without_requirement_packages_placeholders_not_release_ready
    with_packaged(locales: %w[en-CA en-US fr-CA hi pa-IN]) do |config, manifest, _ui, _root|
      assert_equal false, manifest["release_ready"]
      placeholder_shots = manifest["screenshots"].select { |shot| shot["locale"] == "pa-IN" }
      assert placeholder_shots.all? { |shot| shot.key?("known_non_goals") }
      # Real captures for the covered locales still copy through.
      real = manifest["screenshots"].find { |shot| shot["locale"] == "fr-CA" }
      refute real.key?("known_non_goals")
      assert File.exist?(File.join(config.output_dir("appstore"), real["file"]))
    end
  end

  def test_ambiguous_duplicate_capture_aborts
    assert_raises(ScreenshotKit::Error) do
      Dir.mktmpdir do |root|
        config = build_config(root)
        seed_metadata(root, %w[en-US])
        source_dir = File.join(root, "captures")
        # Same device+surface twice: flat id and device-prefixed id.
        write_capture(File.join(source_dir, "alpha.png"), width: 64, height: 128, seed: 1)
        write_capture(File.join(source_dir, "device-alpha.png"), width: 64, height: 128, seed: 2)
        ENV[config.env("SCREENSHOT_SOURCE_DIR")] = source_dir
        begin
          ScreenshotKit::Packaging.new(config, ui: RecordingUI.new).run!("appstore")
        ensure
          ENV.delete(config.env("SCREENSHOT_SOURCE_DIR"))
        end
      end
    end
  end

  def test_no_english_aliases_means_no_flat_fallback
    # Flat files are present and unclaimable: with no aliases every locale
    # resolves from its own subdirectory or not at all.
    with_packaged(overrides: { english_asc_locales: [] },
                  locales: %w[fr-CA hi]) do |config, manifest, _ui, root|
      assert_equal %w[fr-CA hi], manifest["locales"]
      output = config.output_dir("appstore")
      flat = File.binread(File.join(root, "captures", "#{IPHONE}-alpha.png"))
      %w[fr-CA hi].each do |locale|
        packaged = File.binread(File.join(output, locale, "iphone-17-pro-max-01-alpha.png"))
        refute_equal flat, packaged, "#{locale} must not inherit the flat capture"
      end
    end
  end

  # The bug this pins: release_ready also demanded a non-empty flat cache, so
  # a complete per-locale matrix with no English aliases — which produces no
  # flat files at all — could never package as shippable.
  def test_complete_matrix_without_english_aliases_is_release_ready
    with_packaged(overrides: { english_asc_locales: [] },
                  locales: %w[fr-CA hi], seed_flat: false) do |_config, manifest, _ui, _root|
      assert_equal true, manifest["release_ready"]
      assert_equal "provided-png", manifest["source"]
      refute(manifest["screenshots"].any? { |shot| shot.key?("known_non_goals") })
    end
  end

  def test_incomplete_matrix_without_english_aliases_is_not_release_ready
    with_packaged(overrides: { english_asc_locales: [] },
                  locales: %w[fr-CA hi pa-IN], seed_flat: false) do |_config, manifest, _ui, _root|
      assert_equal false, manifest["release_ready"]
    end
  end

  def test_placeholder_set_when_nothing_captured
    with_packaged(seed_sources: false, env: { "KITTEST_SCREENSHOT_SOURCE_DIR" => nil }) do |config, manifest, _ui, _root|
      assert_equal false, manifest["release_ready"]
      assert_equal "deterministic-fixture-reference", manifest["source"]
      first = manifest["screenshots"].first
      path = File.join(config.output_dir("appstore"), first["file"])
      assert File.exist?(path)
      # Placeholder dimensions come from the first configured device.
      assert_equal [64, 128], ScreenshotKit::Verification.new(config).send(:png_dimensions, path)
    end
  end
end

