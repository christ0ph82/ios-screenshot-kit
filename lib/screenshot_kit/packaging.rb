# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "zlib"

module ScreenshotKit
  # Packages captured PNGs into the per-locale layout deliver uploads from,
  # with a manifest that says — honestly — whether the set is release-ready.
  #
  # deliver discovers screenshots by walking *language folders* under the
  # screenshots path (Deliver::Loader::LanguageFolder). A flat directory of
  # PNGs contains no language folder, so deliver finds nothing, uploads the
  # metadata, and reports success having sent zero screenshots. Images
  # therefore go in per-locale folders; the manifest and contact sheet stay at
  # the top level, where deliver ignores them.
  #
  # The locale list is taken from the repo's fastlane/metadata directory
  # rather than configured twice, because screenshots are per-localization and
  # must cover the same locales the metadata does. The App Store Connect
  # record's *primary* locale not having a folder is not cosmetic: precheck
  # passes while the primary localization ships without screenshots.
  class Packaging
    NON_LOCALE_METADATA_DIRS = %w[default review_information trade_representative_contact_information].freeze

    PALETTES = [
      [30, 53, 87],
      [31, 96, 84],
      [116, 67, 42],
      [63, 81, 53],
      [84, 72, 116]
    ].freeze

    def initialize(config, ui: PlainUI.new)
      @config = config
      @ui = ui
    end

    VALID_MODES = %w[review appstore].freeze

    # Returns the manifest hash it wrote. `mode` is "appstore" or "review";
    # both package the same surfaces and differ in what each capture is read
    # for downstream.
    def run!(mode)
      unless VALID_MODES.include?(mode)
        @ui.user_error!("Unknown packaging mode #{mode.inspect}; expected one of #{VALID_MODES.join(", ")}.")
      end
      output = @config.output_dir(mode)
      FileUtils.rm_rf(output)
      FileUtils.mkdir_p(output)

      locales = discover_locales
      locale_outputs = locales.to_h do |locale|
        path = File.join(output, locale)
        FileUtils.mkdir_p(path)
        [locale, path]
      end

      source_dir = ENV[@config.env("SCREENSHOT_SOURCE_DIR")]
      flat_files = source_dir.to_s.empty? ? [] : Dir[File.join(source_dir, "*.png")].sort

      # Captures are per *locale*, not only per device. A localized listing
      # showing English screenshots is worse than showing none: it tells a
      # parent the app speaks their language when it does not, and it passes
      # App Store review. A locale's captures live in "<source_dir>/<asc>/"
      # when that directory exists; the flat source_dir is correct only for
      # the English locales, which are one language sharing a single capture
      # run. Any other locale without its own directory is missing, and says
      # so.
      sources_by_locale = locales.to_h do |locale|
        [locale, index_sources(sources_for_locale(source_dir, locale, flat_files))]
      end

      devices = sources_by_locale.values.flat_map(&:keys).uniq.sort

      missing = locales.flat_map do |locale|
        locale_devices = sources_by_locale.fetch(locale).keys.sort
        if locale_devices.empty?
          @config.surface_ids.map { |id| "#{locale}/(no captures)/#{id}" }
        else
          locale_devices.flat_map do |device|
            (@config.surface_ids - sources_by_locale.fetch(locale).fetch(device).keys).map { |id| "#{locale}/#{device}/#{id}" }
          end
        end
      end
      missing = @config.surface_ids.map { |id| "(no captures)/#{id}" } if devices.empty?

      if ENV[@config.env("REQUIRE_SCREENSHOT_SOURCE")] == "1" && !missing.empty?
        @ui.user_error!("Missing captured screenshot(s): #{missing.join(", ")}")
      end

      # Fall back to a single placeholder set when nothing was captured at
      # all, so the lane still produces a browsable reference before capture
      # is wired up. REQUIRE_SCREENSHOT_SOURCE=1 forbids placeholders on the
      # release path above.
      devices = [ENV[@config.env("SCREENSHOT_DEVICE")] || @config.devices.first.name] if devices.empty?

      manifest = build_manifest(mode, devices, locales, source_dir, flat_files, missing)

      locale_outputs.each do |locale, locale_output|
        devices.each do |device_name|
          @config.surfaces.each_with_index do |surface, index|
            filename = "#{ScreenshotKit.device_slug(device_name)}-#{format("%02d", index + 1)}-#{surface.id}.png"
            path = File.join(locale_output, filename)
            source_file = sources_by_locale.fetch(locale, {}).fetch(device_name, {})[surface.id]
            if source_file
              FileUtils.cp(source_file, path)
            else
              width, height = @config.devices.first.pixels
              write_png(path, width: width, height: height, palette_index: index,
                        title: surface.title, subtitle: surface.fixture)
            end

            shot = {
              "id" => surface.id,
              "route" => surface.title,
              "ui_test_route" => surface.id,
              "fixture" => surface.fixture,
              "expected_focus" => surface.expected_focus,
              "device" => device_name,
              "locale" => locale,
              "appearance" => @config.appearance,
              "file" => File.join(locale, filename)
            }
            unless source_file
              shot["known_non_goals"] = ["Generated reference pixels are not a visual-design approval substitute."]
            end
            manifest.fetch("screenshots") << shot
          end
        end
      end

      File.write(File.join(output, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
      File.write(File.join(output, "index.html"), contact_sheet(mode, manifest))

      @ui.message(
        "Generated #{manifest.fetch("screenshots").length} #{mode} screenshot artifacts: " \
        "#{@config.surfaces.length} surface(s) x #{devices.length} device(s) x #{locales.length} locale(s) " \
        "(#{locales.join(", ")}) in #{output}"
      )
      manifest
    end

    private

    def discover_locales
      metadata_root = File.join(@config.root, @config.metadata_path)
      locales = if Dir.exist?(metadata_root)
                  Dir.children(metadata_root).select do |entry|
                    File.directory?(File.join(metadata_root, entry)) &&
                      !NON_LOCALE_METADATA_DIRS.include?(entry)
                  end.sort
                else
                  []
                end
      locales.empty? ? @config.english_asc_locales.dup : locales
    end

    def sources_for_locale(source_dir, locale, flat_files)
      return [] if source_dir.to_s.empty?

      scoped = File.join(source_dir, locale)
      return Dir[File.join(scoped, "*.png")].sort if Dir.exist?(scoped)

      @config.english_asc_locales.include?(locale) ? flat_files : []
    end

    # Sources are matched to surfaces by id, never by position. Two producers
    # feed this and they name files differently: attachment exports write
    # exactly the surface id, SnapshotHelper writes "<device>-<surface id>.png".
    # Positional matching is not recoverable behaviour: one failed capture or
    # stray PNG silently relabels every subsequent shot, and the manifest then
    # asserts a provenance that is simply wrong.
    def index_sources(files)
      by_device = Hash.new { |hash, key| hash[key] = {} }
      files.each do |path|
        basename = File.basename(path, ".png")
        id = @config.surface_ids.find { |candidate| basename == candidate || basename.end_with?("-#{candidate}") }
        next if id.nil?

        device = basename == id ? "device" : basename.sub(/-#{Regexp.escape(id)}\z/, "")
        if by_device[device].key?(id)
          @ui.user_error!("Two captures for device '#{device}' surface '#{id}': #{by_device[device][id]} and #{path}")
        end
        by_device[device][id] = path
      end
      by_device
    end

    def build_manifest(mode, devices, locales, source_dir, flat_files, missing)
      # Flat files are evidence of capture only where something can claim
      # them. With no English aliases every locale resolves from its own
      # directory and the flat cache is expected to be empty; requiring it
      # would hold a complete per-locale matrix permanently unshippable.
      captured = missing.empty? && (@config.english_asc_locales.empty? || !flat_files.empty?)
      source = if captured
                 ENV[@config.env("SCREENSHOT_CAPTURE_SOURCE")] == "1" ? "xcresult-ui-test-attachments" : "provided-png"
               else
                 "deterministic-fixture-reference"
               end
      {
        "schema_version" => 2,
        "kit_version" => ScreenshotKit::VERSION,
        "mode" => mode,
        "generated_at" => Time.now.utc.iso8601,
        "devices" => devices,
        "locales" => locales,
        "appearance" => @config.appearance,
        "source" => source,
        # Release-ready means every surface resolved to a real capture on
        # every device for every locale, not merely that some PNG was found.
        # A partial capture must never read as shippable.
        "release_ready" => mode == "appstore" && captured,
        # Absolute, so verification can recognize a package built straight from
        # the raw capture cache and hold it to capture dimensions rather than
        # upload dimensions. A relative or unexpanded path would compare unequal
        # to the same directory named another way, and the package would be
        # verified in the wrong mode. Nil/empty stays as it is: nothing was
        # packaged from anywhere, and File.expand_path("") is the cwd.
        "source_dir" => source_dir.to_s.empty? ? source_dir : File.expand_path(source_dir),
        "expected_per_locale_per_device" => @config.surfaces.length,
        "screenshots" => []
      }
    end

    def contact_sheet(mode, manifest)
      html = +"<!doctype html><html><head><meta charset=\"utf-8\"><title>#{@config.product_name} #{mode} screenshots</title>"
      html << "<style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:24px;background:#f8f7f2;color:#1f2933} " \
              ".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px} " \
              "figure{margin:0;padding:12px;background:white;border:1px solid #d9ded8;border-radius:8px} " \
              "img{width:100%;height:auto;border-radius:6px} figcaption{font-size:13px;line-height:1.35}</style></head><body>"
      html << "<h1>#{@config.product_name} #{mode} screenshots</h1>"
      manifest.fetch("screenshots").group_by { |shot| [shot.fetch("locale"), shot.fetch("device")] }.each do |(locale, device), shots|
        html << "<h2>#{locale} — #{device}</h2><div class=\"grid\">"
        shots.each do |shot|
          html << "<figure><img src=\"#{shot.fetch("file")}\" alt=\"#{shot.fetch("id")}\">" \
                  "<figcaption><strong>#{shot.fetch("route")}</strong><br>#{shot.fetch("expected_focus")}</figcaption></figure>"
        end
        html << "</div>"
      end
      html << "</body></html>"
      html
    end

    def png_chunk(type, data)
      type = type.b
      data = data.b
      [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
    end

    def write_png(path, width:, height:, palette_index:, title:, subtitle:)
      color = PALETTES.fetch(palette_index % PALETTES.length)
      accent = color.map { |component| [component + 72, 235].min }
      rows = []
      height.times do |y|
        row = +"".b
        width.times do |x|
          band = y < 120 || y > height - 160
          stripe = ((x / 32) + (y / 32)).even?
          pixel = band ? accent : (stripe ? color : color.map { |component| [component + 12, 255].min })
          row << pixel.pack("C3")
        end
        rows << "\x00".b + row
      end

      data = [
        "\x89PNG\r\n\x1A\n".b,
        png_chunk("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")),
        png_chunk("tEXt", "Title\x00#{title}"),
        png_chunk("tEXt", "Description\x00#{subtitle}"),
        png_chunk("IDAT", Zlib::Deflate.deflate(rows.join, Zlib::BEST_COMPRESSION)),
        png_chunk("IEND", "")
      ].join.b

      File.binwrite(path, data)
    end
  end
end

