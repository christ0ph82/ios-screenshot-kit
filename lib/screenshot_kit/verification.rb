# frozen_string_literal: true

require "digest"
require "json"

module ScreenshotKit
  # Post-packaging checks that were previously a runbook's manual steps.
  # "fastlane finished successfully" is not evidence; these are.
  #
  # Checks, in order of how badly their failure ships:
  # 1. release_ready — a partial or placeholder set must not upload.
  # 2. Dimensions — every PNG matches its device's configured native pixels;
  #    App Store Connect rejects anything else, deliver sometimes does not.
  #    A package built straight from the raw capture cache is held to the
  #    device's `capture_pixels` instead, where it declares them: those files
  #    have not been through the consumer's composition stage yet, and failing
  #    them here would abort the run before the checks that must read raw
  #    captures. See #check_dimensions.
  # 3. Translated captures — a localized locale whose files are byte-identical
  #    to the base locale's set (English, unless `translation_base_asc` names
  #    another) was captured in the wrong language. That set passes review and
  #    tells a parent the app speaks their language when it does not — the
  #    silent failure this whole pipeline exists to prevent.
  class Verification
    Report = Struct.new(:errors, :warnings, keyword_init: true) do
      def ok?
        errors.empty?
      end
    end

    def initialize(config, ui: PlainUI.new)
      @config = config
      @ui = ui
    end

    # Verifies a packaged output directory against its manifest. Raises via
    # ui.user_error! on errors when `strict` (the default); always surfaces
    # warnings. Returns the Report.
    def run!(mode, strict: true)
      output = @config.output_dir(mode)
      manifest_path = File.join(output, "manifest.json")
      @ui.user_error!("No manifest at #{manifest_path}; package first.") unless File.exist?(manifest_path)
      manifest = JSON.parse(File.read(manifest_path))

      errors = []
      warnings = []

      if mode == "appstore" && manifest["release_ready"] != true
        errors << "Manifest is not release-ready (source: #{manifest["source"].inspect}). " \
                  "A placeholder or partial set must not reach deliver."
      end

      check_dimensions(manifest, output, errors)
      check_translations(manifest, output, errors, warnings) if mode == "appstore"
      check_status_bar_intruders(manifest, output, errors, warnings) if mode == "appstore" && @config.status_bar_guard

      warnings.each { |warning| @ui.important(warning) }
      if errors.empty?
        @ui.success("Screenshot verification passed: #{manifest.fetch("screenshots").length} file(s), " \
                    "#{manifest.fetch("locales").length} locale(s), #{manifest.fetch("devices").length} device(s).")
      elsif strict
        @ui.user_error!("Screenshot verification failed:\n- #{errors.join("\n- ")}")
      end
      Report.new(errors: errors, warnings: warnings)
    end

    private

    # PNG dimensions come straight from the IHDR chunk — bytes 16-23 are
    # width/height, big-endian — so this needs no image library and runs the
    # same on macOS and Linux CI.
    def png_dimensions(path)
      header = File.binread(path, 24)
      return nil unless header && header.bytesize == 24 && header[1, 3] == "PNG"

      header[16, 8].unpack("NN")
    end

    INTRUDER_REGION = { x_range: 0.015..0.30, y_range: 0.025..0.055 }.freeze
    INTRUDER_MARGIN = 0.02
    INTRUDER_CEILING = 0.08

    def check_status_bar_intruders(manifest, output, errors, warnings)
      by_device = manifest.fetch("screenshots").group_by { |shot| shot.fetch("device") }
      by_device.each do |device, shots|
        fractions = shots.to_h do |shot|
          path = File.join(output, shot.fetch("file"))
          [shot.fetch("file"), File.exist?(path) ? PngStrip.dark_fraction(path, **INTRUDER_REGION) : nil]
        end
        unreadable = fractions.select { |_, fraction| fraction.nil? }.keys
        unless unreadable.empty?
          warnings << "Status-bar guard could not read #{unreadable.length} file(s) on #{device} " \
                      "(unsupported PNG layout); those files are UNCHECKED, not clean."
        end

        readable = fractions.compact
        next if readable.empty?

        minimum = readable.values.min
        if minimum > INTRUDER_CEILING
          errors << "Every capture on #{device} carries top-left content above the calibrated ceiling " \
                    "(min #{format("%.3f", minimum)} > #{INTRUDER_CEILING}) — possibly a breadcrumb on every " \
                    "file, or a theme this guard is not calibrated for (disable via status_bar_guard: false)."
          next
        end

        intruders = readable.select { |_, fraction| fraction > minimum + INTRUDER_MARGIN }.keys.sort
        unless intruders.empty?
          errors << "Status-bar intruder (app-switch breadcrumb?) on #{device}: #{intruders.length} of " \
                    "#{readable.length} capture(s) show extra top-left content vs the device's clean baseline " \
                    "(#{intruders.first(4).join(", ")}#{intruders.length > 4 ? ", …" : ""}). Something foregrounded " \
                    "another app on the simulator mid-run; recapture with the simulator left alone."
        end
      end
    end

    # A package built straight from the raw capture cache holds the pixels the
    # simulator wrote, not the pixels App Store Connect accepts — those are the
    # same number only for a repo that uploads what it captures. Where a
    # composition stage sits between capture and upload, the device declares
    # `capture_pixels` and a from-the-cache package is verified against that;
    # otherwise every shot fails on dimensions by construction and the run
    # never reaches the checks that must read raw captures, the status-bar
    # guard above among them. Provenance decides, not a flag: the manifest
    # records the directory it packaged from, and only that directory being
    # cache_dir means these are raw captures. An external source (a composed
    # poster tree) — or an old manifest with no `source_dir` at all — is held
    # to upload pixels, which is the stricter and safer default.
    def capture_mode?(manifest)
      source_dir = manifest["source_dir"]
      # Manifests are read off disk: anything that is not a usable path reads
      # as unknown provenance, which verifies strictly rather than raising.
      return false unless source_dir.is_a?(String) && !source_dir.empty?

      File.expand_path(source_dir) == File.expand_path(@config.cache_dir)
    end

    def check_dimensions(manifest, output, errors)
      capture_mode = capture_mode?(manifest)
      # Only devices that actually declare a distinct capture size are verified
      # (and reported) differently; every other device behaves identically in
      # both modes.
      capture_sized_slugs = if capture_mode
                              @config.devices.reject { |d| d.capture_pixels.nil? }.map(&:slug)
                            else
                              []
                            end
      expected_by_slug = @config.devices.to_h do |device|
        [device.slug, capture_sized_slugs.include?(device.slug) ? device.capture_pixels : device.pixels]
      end

      manifest.fetch("screenshots").each do |shot|
        path = File.join(output, shot.fetch("file"))
        unless File.exist?(path)
          errors << "Manifest names #{shot.fetch("file")} but the file does not exist."
          next
        end

        slug = ScreenshotKit.device_slug(shot.fetch("device"))
        expected = expected_by_slug[slug]
        # A device outside the configured matrix (a placeholder fallback name,
        # a review-only device) has no expected size to hold it to.
        next if expected.nil?

        actual = png_dimensions(path)
        if actual.nil?
          errors << "#{shot.fetch("file")} is not a PNG."
        elsif actual != expected
          errors << if capture_sized_slugs.include?(slug)
                      "#{shot.fetch("file")} is #{actual.join("x")}, expected #{expected.join("x")} " \
                      "(capture size; this package was built from the raw capture cache) " \
                      "for #{shot.fetch("device")}."
                    else
                      "#{shot.fetch("file")} is #{actual.join("x")}, expected #{expected.join("x")} " \
                      "for #{shot.fetch("device")}. App Store Connect rejects non-native sizes."
                    end
        end
      end
    end

    # Per-surface, not whole-set. The first shipped version compared each
    # locale's complete digest list against English and erred only on full
    # identity — and a matrix whose language injection had silently failed
    # PASSED it, because one nondeterministic surface (map tiles render
    # differently every pass) made every all-English locale look "different".
    # Every capture here renders localized text, so a single surface
    # byte-identical to its English counterpart already means that locale's
    # language never reached the app.
    def check_translations(manifest, output, errors, warnings)
      shots_by_locale = manifest.fetch("screenshots").group_by { |shot| shot.fetch("locale") }
      base_locale = translation_base(shots_by_locale)
      return if base_locale.nil?

      # surface basename => digest, so locales compare surface-for-surface.
      digests = lambda do |locale|
        shots_by_locale.fetch(locale, []).to_h do |shot|
          path = File.join(output, shot.fetch("file"))
          [File.basename(shot.fetch("file")), File.exist?(path) ? Digest::MD5.file(path).hexdigest : nil]
        end
      end

      base = digests.call(base_locale)
      localized = shots_by_locale.keys - @config.english_asc_locales - [base_locale]
      localized_digests = localized.to_h { |locale| [locale, digests.call(locale)] }

      # Both identity checks compare *languages*, and store locales are finer
      # than languages: four English App Store rows served by one `en` catalog
      # render the same pixels by design, so identity between them is the
      # expected outcome and says nothing about whether injection worked. Only
      # a language that never reached the app is evidence. A locale the
      # manifest names but the config does not declare has no language to
      # match on and stays subject to both checks.
      languages = @config.locales.to_h { |locale| [locale.asc, locale.language] }
      same_language = lambda do |a, b|
        !languages[a].nil? && languages[a] == languages[b]
      end

      localized_digests.each do |locale, files|
        next if same_language.call(locale, base_locale)

        identical = files.select { |basename, digest| !digest.nil? && digest == base[basename] }.keys.sort
        next if identical.empty?

        errors << "Locale #{locale}: #{identical.length} of #{files.length} capture(s) byte-identical to " \
                  "#{base_locale} (#{identical.join(", ")}) — captured in #{base_locale}'s language, not its " \
                  "own. Check that the app ships a catalog for it and the language injection reached the app."
      end

      localized.combination(2).each do |a, b|
        next if same_language.call(a, b)

        matching = localized_digests.fetch(a).count do |basename, digest|
          !digest.nil? && digest == localized_digests.fetch(b)[basename]
        end
        total = localized_digests.fetch(a).length
        if matching == total && total.positive?
          warnings << "Locales #{a} and #{b} are byte-identical to each other. If they are distinct " \
                      "languages, one of them was captured wrong."
        end
      end
    end

    # The configured base wins when its captures are present; otherwise the
    # first English alias that was captured. Resolving neither is silence, not
    # an error: there is nothing to compare against, and saying so on every
    # alias-free run that declares no base would train operators to ignore it.
    def translation_base(shots_by_locale)
      configured = @config.translation_base_asc
      return configured if configured && shots_by_locale.key?(configured)

      @config.english_asc_locales.find { |locale| shots_by_locale.key?(locale) }
    end
  end
end

