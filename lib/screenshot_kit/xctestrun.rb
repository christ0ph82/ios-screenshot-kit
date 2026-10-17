# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"

module ScreenshotKit
  # Per-locale .xctestrun preparation for the build-once matrix.
  #
  # Why this exists: `xcodebuild test-without-building` takes the runner's
  # environment and language from the .xctestrun FILE, not from the command
  # line. Both of the kit's language channels — `TEST_RUNNER_*` forwarding and
  # `-testLanguage`/`-testRegion` — are consumed when xcodebuild constructs a
  # test plan, which a replayed .xctestrun never does. The first full matrix
  # run proved it the expensive way: every "localized" pass launched in
  # English, silently, while xcodebuild happily echoed the ignored settings.
  #
  # So the matrix writes one .xctestrun per locale: a byte copy of the built
  # one with the kit's runner-environment contract injected into every test
  # target's TestingEnvironmentVariables, and TestLanguage/TestRegion set on
  # every configuration — restoring both halves of the belt-and-suspenders
  # under replay. Writes go through `plutil -replace` against the copy — it
  # takes the value as a single argument with no second tokenizer, where
  # PlistBuddy's own command parser strips the quotes out of a JSON-valued
  # string. The JSON conversion is read-only, to discover the configuration
  # and target counts and which targets lack an environment dict.
  class Xctestrun
    def initialize(capture: Shell.default_capture, ui: PlainUI.new)
      @capture = capture
      @ui = ui
    end

    # Returns the path of a localized copy next to `base_path`.
    def localized_copy(base_path, locale)
      target_path = File.join(File.dirname(base_path), "screenshot-kit-#{locale.asc}.xctestrun")
      FileUtils.rm_f(target_path)
      FileUtils.cp(base_path, target_path)

      structure = JSON.parse(@capture.call("plutil -convert json -o - #{Shellwords.escape(base_path)}"))
      configurations = structure.fetch("TestConfigurations") do
        @ui.user_error!("#{base_path} has no TestConfigurations; is it a format-2 xctestrun?")
      end

      environment = {
        "SCREENSHOT_KIT_LANGUAGE" => locale.language,
        "SCREENSHOT_KIT_LOCALE" => locale.resolved_apple_locale
      }
      environment["SCREENSHOT_KIT_APP_ENV"] = JSON.generate(locale.app_env) unless locale.app_env.empty?

      configurations.each_with_index do |configuration, configuration_index|
        set_string(target_path, "TestConfigurations.#{configuration_index}.TestLanguage", locale.language)
        set_string(target_path, "TestConfigurations.#{configuration_index}.TestRegion", locale.region)
        configuration.fetch("TestTargets", []).each_with_index do |target, target_index|
          environment_keypath = "TestConfigurations.#{configuration_index}.TestTargets.#{target_index}.TestingEnvironmentVariables"
          unless target.key?("TestingEnvironmentVariables")
            @capture.call(
              "plutil -insert #{Shellwords.escape(environment_keypath)} -json '{}' #{Shellwords.escape(target_path)}"
            )
          end
          environment.each do |key, value|
            set_string(target_path, "#{environment_keypath}.#{key}", value)
          end
        end
      end

      target_path
    end

    private

    # `plutil -replace` upserts: it inserts when the keypath is absent and
    # overwrites when it exists, so one form covers both states.
    def set_string(path, keypath, value)
      @capture.call(
        "plutil -replace #{Shellwords.escape(keypath)} -string #{Shellwords.escape(value)} #{Shellwords.escape(path)}"
      )
    end
  end
end

