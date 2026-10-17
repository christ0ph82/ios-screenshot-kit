# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"

module ScreenshotKit
  class Capture
    def initialize(config, sh: Shell.default_sh, capture: Shell.default_capture, ui: PlainUI.new)
      @config = config
      @sh = sh
      @ui = ui
      @simulator = Simulator.new(capture: capture, sh: sh, ui: ui)
      @xctestrun = Xctestrun.new(capture: capture, ui: ui)
      @lock = Lock.new(config.lock_path, ui: ui)
      @machine_lock = Lock.new(config.machine_lock_path, ui: ui)
    end

    # Runs the whole matrix and returns the cache directory, ready to hand to
    # Packaging as the source dir: localized captures in "<cache>/<asc>/",
    # English flat at the top level.
    def run!(locales: nil)
      selected = select_locales(locales)
      # Two locks, nested: the repo lock excludes this repo's own audit
      # scripts; the machine lock excludes a kit run from another repo on the
      # same Mac, because the simulators are one shared pool.
      @machine_lock.with_lock { @lock.with_lock { run_matrix!(selected) } }
      @config.cache_dir
    end

    private

    def run_matrix!(selected)
      reset_cache!
      prepared_udids = []
      begin
        xctestrun = @config.build_once ? build_for_testing! : nil

        english_pass = @config.english_asc_locales.any? ? 1 : 0
        total = selected.length + english_pass

        selected.each_with_index do |locale, index|
          @ui.message("Locale #{index + 1}/#{total}: #{locale.asc} (#{locale.language}/#{locale.region})")
          locale_dir = File.join(@config.cache_dir, locale.asc)
          FileUtils.mkdir_p(locale_dir)
          # test-without-building reads language and environment from the
          # .xctestrun file, never from the command line, so each locale
          # replays its own injected copy. See Xctestrun for the scar.
          locale_xctestrun = xctestrun ? @xctestrun.localized_copy(xctestrun, locale) : nil
          capture_pass!(locale_dir, locale: locale, xctestrun: locale_xctestrun, prepared_udids: prepared_udids)
        end

        # The flat English pass exists only for repos whose English App Store
        # locales alias a single shared capture. A repo that captures English
        # as an explicit locale row declares no aliases and skips it.
        if english_pass == 1
          @ui.message("Locale #{total}/#{total}: English (flat, shared by #{@config.english_asc_locales.join(", ")})")
          capture_pass!(@config.cache_dir, locale: nil, xctestrun: xctestrun, prepared_udids: prepared_udids)
        end
      ensure
        # Overrides do not survive shutdown, but a run that never shuts down
        # would leave 9:41 stamped on the operator's simulators.
        prepared_udids.uniq.each { |udid| @simulator.clear_status_bar(udid) }
      end
    end

    def select_locales(requested)
      return @config.locales if requested.nil? || requested.empty?

      unknown = requested - @config.locales.map(&:asc)
      unless unknown.empty?
        @ui.user_error!(
          "Unknown screenshot locale(s): #{unknown.join(", ")}. " \
          "Known: #{@config.locales.map(&:asc).join(", ")}"
        )
      end
      @config.locales.select { |locale| requested.include?(locale.asc) }
    end

    def reset_cache!
      FileUtils.rm_rf(@config.cache_dir)
      FileUtils.mkdir_p(@config.cache_dir)
      FileUtils.rm_rf(Dir[File.join(staging_dir, "*.png")])
      FileUtils.mkdir_p(staging_dir)
    end

    # Where SnapshotHelper actually writes; see Config#staging_dir. Only *.png
    # is ever cleared there: the directory is shared with any other tool still
    # using fastlane's snapshot, and this kit does not own it.
    def staging_dir
      @config.staging_dir
    end

    def build_for_testing!
      @ui.header("Build for testing")
      products = File.join(@config.root, @config.derived_data, "Build", "Products")
      FileUtils.rm_rf(Dir[File.join(products, "*.xctestrun")])
      @sh.call(
        [
          "xcodebuild",
          "build-for-testing",
          "-project", Shellwords.escape(File.join(@config.root, @config.project)),
          "-scheme", Shellwords.escape(@config.ui_test_scheme),
          "-destination", "'platform=iOS Simulator,name=#{@config.devices.first.name}'",
          "-derivedDataPath", Shellwords.escape(File.join(@config.root, @config.derived_data))
        ].join(" ")
      )
      xctestrun = Dir[File.join(products, "*.xctestrun")].max_by { |path| File.mtime(path) }
      @ui.user_error!("build-for-testing produced no .xctestrun under #{products}") if xctestrun.nil?
      xctestrun
    end

    # One pass over every device, into `destination`. `locale: nil` is the
    # English pass: no language injection, captures stay flat.
    def capture_pass!(destination, locale:, xctestrun:, prepared_udids:)
      label = locale ? locale.asc : "English"

      @config.devices.each do |device|
        # Staging holds one device's pass at a time. Everything already
        # captured lives under `destination`, so clearing here cannot cost a
        # finished pass — which is what made the old flat-English special case
        # necessary, and why there no longer is one.
        FileUtils.rm_rf(Dir[File.join(staging_dir, "*.png")])
        run_with_retries!(device, locale: locale, label: label, xctestrun: xctestrun, prepared_udids: prepared_udids)

        captured = Dir[File.join(staging_dir, "*.png")]
        if captured.empty?
          @ui.user_error!(
            "#{label} capture on #{device.name} wrote no PNGs into #{staging_dir}. The UI test " \
            "passed, so check that setupSnapshot ran before snapshot(), that the app ships a " \
            "#{locale&.language} catalog, and that SnapshotHelper still writes to that directory."
          )
        end
        FileUtils.mkdir_p(destination)
        FileUtils.mv(captured, destination)
      end
    end

    def test_command(device, locale:, xctestrun:)
      command = ["xcodebuild"]
      if xctestrun
        command += ["test-without-building", "-xctestrun", Shellwords.escape(xctestrun)]
      else
        command += [
          "test",
          "-project", Shellwords.escape(File.join(@config.root, @config.project)),
          "-scheme", Shellwords.escape(@config.ui_test_scheme),
          "-derivedDataPath", Shellwords.escape(File.join(@config.root, @config.derived_data))
        ]
      end
      command += [
        "-destination", "'platform=iOS Simulator,name=#{device.name}'",
        "-only-testing:#{@config.only_testing}"
      ]
      if locale
        # -testLanguage/-testRegion localize the *runner*, whose preferred
        # language the kit's Swift launch helper reads back as its fallback.
        # The TEST_RUNNER_ variables are the primary channel: xcodebuild
        # forwards them into the runner's environment, and the launch helper
        # turns them into -AppleLanguages/-AppleLocale launch arguments for
        # the app. Neither alone proved reliable across toolchains; together
        # they have. The app-env payload carries per-locale fixture wording.
        command += [
          "-testLanguage", locale.language,
          "-testRegion", locale.region,
          "TEST_RUNNER_SCREENSHOT_KIT_LANGUAGE=#{locale.language}",
          "TEST_RUNNER_SCREENSHOT_KIT_LOCALE=#{locale.resolved_apple_locale}"
        ]
        unless locale.app_env.empty?
          command << "TEST_RUNNER_SCREENSHOT_KIT_APP_ENV=#{Shellwords.escape(JSON.generate(locale.app_env))}"
        end
      end
      command.join(" ")
    end

    # Retry a transient simulator failure, resetting simulator state between
    # attempts. Every failure retries rather than matching error text:
    # transient CoreSimulator failures have several signatures (dead
    # containers, "No such process", boot and launch timeouts) and a missed
    # signature costs the whole matrix. A genuinely broken test still fails —
    # after `attempts` tries.
    def run_with_retries!(device, locale:, label:, xctestrun:, prepared_udids:)
      command = test_command(device, locale: locale, xctestrun: xctestrun)

      (1..@config.attempts).each do |attempt|
        # Drop whatever a failed attempt wrote. Scoped to this device because
        # staging is shared with anything else on the machine still writing
        # through fastlane's snapshot.
        FileUtils.rm_rf(Dir[File.join(staging_dir, "#{device.name}-*.png")]) if attempt > 1

        # Boot + status bar per attempt, not per run: the retry path shuts
        # every simulator down, taking the 9:41 override with it.
        prepared_udids << @simulator.prepare(
          device.name,
          status_bar_time: @config.status_bar_time,
          appearance: @config.appearance
        )

        begin
          suffix = attempt > 1 ? " (attempt #{attempt}/#{@config.attempts})" : ""
          @ui.header("Capture #{label} screenshots on #{device.name}#{suffix}")
          @sh.call(command)
          return
        rescue StandardError => error
          raise if attempt == @config.attempts

          @ui.important(
            "#{label} capture on #{device.name} failed on attempt #{attempt} of #{@config.attempts}: " \
            "#{error.message.to_s.lines.first&.strip}"
          )
          @ui.important("Treating it as a transient simulator failure; resetting and retrying.")
          @simulator.shutdown_all
        end
      end
    end
  end
end

