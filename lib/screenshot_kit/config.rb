# frozen_string_literal: true

module ScreenshotKit
  # Short, stable, filename-safe device prefix. deliver groups by detected
  # display type and then orders by filename, so this controls ordering within
  # a group.
  def self.device_slug(name)
    slug = name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    slug.empty? ? "device" : slug
  end

  # One device the matrix captures on. `pixels` is the portrait [width, height]
  # App Store Connect expects for its display class — the *upload* size —
  # and verification checks every packaged PNG against it.
  #
  # `capture_pixels` is optional and says: the simulator captures at this size,
  # and a downstream composition stage (poster framing, scaling) turns it into
  # `pixels`. A repo that uploads exactly what it captures leaves it nil. Where
  # it is set the two differ — an iPhone 17 Pro Max captures 1320x2868 and its
  # App Store display class accepts 1290x2796 — and verification holds a
  # package built straight from the raw capture cache to this size instead, so
  # the run reaches the checks that must read raw captures (the status-bar
  # guard) rather than aborting on dimensions by construction.
  Device = Struct.new(:name, :pixels, :capture_pixels, keyword_init: true) do
    def slug
      ScreenshotKit.device_slug(name)
    end
  end

  # One localized App Store locale. `asc` is the App Store Connect locale (and
  # the fastlane/metadata directory name); `language` is the *catalog*
  # identifier the app ships, which is not always the same string (es-MX is
  # served by the neutral `es` catalog). `app_env` is extra environment for the
  # app process during this locale's capture — store-facing per-locale fixture
  # wording rides here, reaching the app through the test runner and the kit's
  # Swift launch helper.
  #
  # `apple_locale` overrides the derived `<language>_<region>` fed to
  # -AppleLocale, for languages whose catalog identifier already carries a
  # script or region: deriving would mint `pt_BR_BR` from pt-BR, and zh-Hans
  # wants `zh_CN`, not `zh_Hans_CN`. Leave nil where the derivation is right.
  #
  # English may use explicit rows here, or a single flat capture shared
  # through `english_asc_locales`. Do not declare the same locale in both.
  KitLocale = Struct.new(:asc, :language, :region, :app_env, :apple_locale, keyword_init: true) do
    def resolved_apple_locale
      apple_locale || "#{language.tr("-", "_")}_#{region}"
    end
  end

  # One captured surface. `id` is the contract with the UI test: every id must
  # be the name passed to a `captureScreenshot(named:)` call, or packaging
  # falls back to placeholder pixels for it. Array order is store-listing
  # order. `title`/`fixture`/`expected_focus` feed the manifest and contact
  # sheet: what screen, over what fixture state, and what a reviewer should be
  # checking.
  Surface = Struct.new(:id, :title, :fixture, :expected_focus, keyword_init: true)

  # The whole per-repo contract. Everything an app has to say about itself to
  # run the shared pipeline lives in one of these — the repos differ only in
  # this object plus their UI test.
  class Config
    attr_reader :root, :env_prefix, :product_name, :project, :ui_test_scheme,
                :only_testing, :derived_data, :devices, :locales,
                :english_asc_locales, :surfaces, :output_root, :metadata_path,
                :cache_dir, :staging_dir, :lock_path, :machine_lock_path, :status_bar_time,
                :attempts, :build_once, :status_bar_guard, :appearance,
                :translation_base_asc

    def initialize(
      root:,
      env_prefix:,
      product_name:,
      project:,
      ui_test_scheme:,
      only_testing:,
      derived_data:,
      devices:,
      locales:,
      english_asc_locales:,
      surfaces:,
      output_root:,
      metadata_path:,
      # Per product, and deliberately a sibling of the old shared
      # tools.fastlane/screenshots path rather than a child of it: the capture
      # run clears its cache_dir wholesale, so on a machine where another
      # adopter still runs an older kit, nesting under the legacy path would
      # leave this product's captures inside that adopter's blast radius.
      cache_dir: File.join(Dir.home, "Library", "Caches", "screenshot-kit", "captures", ScreenshotKit.device_slug(product_name)),
      staging_dir: File.join(Dir.home, "Library", "Caches", "tools.fastlane", "screenshots"),
      lock_path: nil,
      machine_lock_path: File.join(Dir.home, "Library", "Caches", "screenshot-kit", "simulator.lock"),
      status_bar_time: "9:41",
      attempts: 3,
      build_once: true,
      status_bar_guard: true,
      appearance: "light",
      translation_base_asc: nil
    )
      @root = root
      @env_prefix = env_prefix
      @product_name = product_name
      @project = project
      @ui_test_scheme = ui_test_scheme
      @only_testing = only_testing
      @derived_data = derived_data
      @devices = devices.map { |d| d.is_a?(Device) ? d : Device.new(**d) }
      @locales = locales.map { |l| l.is_a?(KitLocale) ? l : KitLocale.new(app_env: {}, **l) }
      @english_asc_locales = english_asc_locales
      @surfaces = surfaces.map { |s| s.is_a?(Surface) ? s : Surface.new(**s) }
      @output_root = output_root
      @metadata_path = metadata_path
      @cache_dir = cache_dir
      @staging_dir = staging_dir
      @lock_path = lock_path || File.join(root, "fastlane", "build", ".simulator-capture.lock")
      # A second, machine-wide lock: repo-local locks cannot see a kit run
      # from a *different* repo on the same Mac, and the simulators are one
      # shared pool. (A neighbor that takes no lock at all is still invisible;
      # the status-bar guard is the net for that.)
      @machine_lock_path = machine_lock_path
      @status_bar_time = status_bar_time
      @attempts = attempts
      @build_once = build_once
      @status_bar_guard = status_bar_guard
      # Pinned per prepare, never inherited: appearance is persistent device
      # state on a shared simulator pool, and a neighbor's dark-mode session
      # once turned a whole capture matrix dark under a manifest claiming
      # light. (The status-bar guard's ceiling caught it; this removes the
      # cause.)
      @appearance = appearance
      # The locale every other locale's pixels are compared against for
      # translation evidence. Left nil, verification anchors on whichever
      # English alias was captured — which a matrix that ships English as
      # explicit rows has none of, and there the check would silently do
      # nothing. Such a matrix names one of its English rows here instead.
      @translation_base_asc = translation_base_asc
      validate!
    end

    def env(name)
      "#{env_prefix}_#{name}"
    end

    def surface_ids
      surfaces.map(&:id)
    end

    def output_dir(mode)
      File.join(root, output_root, mode)
    end

    private

    def valid_pixels?(value)
      value.is_a?(Array) && value.length == 2 && value.all? { |px| px.is_a?(Integer) && px.positive? }
    end

    def validate!
      raise Error, "root must be an absolute path" unless root.to_s.start_with?("/")
      raise Error, "env_prefix must be [A-Z0-9_]+" unless env_prefix.to_s.match?(/\A[A-Z0-9_]+\z/)
      raise Error, "at least one device is required" if devices.empty?
      raise Error, "at least one surface is required" if surfaces.empty?
      # english_asc_locales may be empty: a repo that captures English as an
      # explicit localized row (with its own app_env) declares no aliases and
      # gets no flat English pass.
      raise Error, "english_asc_locales must be an Array" unless english_asc_locales.is_a?(Array)
      raise Error, "attempts must be >= 1" unless attempts.is_a?(Integer) && attempts >= 1

      # Staging is globbed for freshly written PNGs and cleared between passes;
      # a relative path would resolve against whatever directory the lane
      # happens to run from, which is not where SnapshotHelper wrote.
      unless staging_dir.to_s.start_with?("/")
        raise Error, "staging_dir must be an absolute path"
      end
      if File.expand_path(staging_dir) == File.expand_path(cache_dir)
        raise Error, "staging_dir must not be cache_dir: the capture run clears cache_dir wholesale, " \
                     "and staging is where SnapshotHelper writes"
      end

      devices.each do |device|
        unless valid_pixels?(device.pixels)
          raise Error, "device #{device.name.inspect} needs pixels [width, height]"
        end
        # Optional end to end: a repo that uploads what it captures declares
        # nothing here, and a consumer slicing device hashes to known keys
        # never has to learn the key exists.
        unless device.capture_pixels.nil? || valid_pixels?(device.capture_pixels)
          raise Error, "device #{device.name.inspect} capture_pixels must be [width, height]"
        end
      end

      duplicate_ids = surface_ids.tally.select { |_, count| count > 1 }.keys
      raise Error, "duplicate surface ids: #{duplicate_ids.join(", ")}" unless duplicate_ids.empty?

      ascs = locales.map(&:asc)
      duplicate_ascs = ascs.tally.select { |_, count| count > 1 }.keys
      raise Error, "duplicate locales: #{duplicate_ascs.join(", ")}" unless duplicate_ascs.empty?

      overlap = ascs & english_asc_locales
      unless overlap.empty?
        raise Error, "#{overlap.join(", ")} cannot be both a localized locale and an English alias"
      end

      # A base naming nothing the matrix captures would leave the translation
      # check anchorless, and it fails open — silently.
      unless translation_base_asc.nil? || (ascs + english_asc_locales).include?(translation_base_asc)
        raise Error, "translation_base_asc #{translation_base_asc.inspect} is neither a declared locale nor an English alias"
      end

      locales.each do |locale|
        if locale.language.to_s.empty? || locale.region.to_s.empty?
          raise Error, "locale #{locale.asc.inspect} needs language and region"
        end
        unless locale.app_env.is_a?(Hash)
          raise Error, "locale #{locale.asc.inspect} app_env must be a Hash"
        end
      end
    end
  end
end

