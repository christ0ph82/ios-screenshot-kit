# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Real-PlistBuddy round trip over a miniature format-2 xctestrun: the locale
# copy must carry the kit's runner environment and the configuration language,
# and the base file must stay untouched. macOS-only, like the capture side.
class TestXctestrun < Minitest::Test
  include KitTestHelpers

  FIXTURE = {
    "__xctestrun_metadata__" => { "FormatVersion" => 2 },
    "TestConfigurations" => [
      {
        "IsEnabled" => true,
        "Name" => "Test Scheme Action",
        "TestTargets" => [
          {
            "BlueprintName" => "AppUITests",
            "CommandLineArguments" => [],
            "TestingEnvironmentVariables" => { "EXISTING" => "kept" }
          }
        ]
      }
    ]
  }.freeze

  def setup
    skip "PlistBuddy required" unless File.exist?("/usr/libexec/PlistBuddy")
  end

  def write_fixture(dir)
    json = File.join(dir, "fixture.json")
    File.write(json, JSON.generate(FIXTURE))
    base = File.join(dir, "base.xctestrun")
    system("plutil -convert xml1 -o #{base} #{json}") || flunk("plutil failed")
    base
  end

  def read_plist(path)
    JSON.parse(ScreenshotKit::Shell.default_capture.call("plutil -convert json -o - #{path}"))
  end

  def test_localized_copy_injects_language_env_and_configuration_language
    Dir.mktmpdir do |dir|
      base = write_fixture(dir)
      locale = ScreenshotKit::KitLocale.new(
        asc: "pt-BR", language: "pt-BR", region: "BR", apple_locale: "pt_BR",
        app_env: { "APP_PLAN" => "Força total" }
      )

      copy = ScreenshotKit::Xctestrun.new(ui: RecordingUI.new).localized_copy(base, locale)
      assert_equal File.join(dir, "screenshot-kit-pt-BR.xctestrun"), copy

      structure = read_plist(copy)
      configuration = structure.fetch("TestConfigurations").first
      assert_equal "pt-BR", configuration["TestLanguage"]
      assert_equal "BR", configuration["TestRegion"]

      environment = configuration.fetch("TestTargets").first.fetch("TestingEnvironmentVariables")
      assert_equal "kept", environment["EXISTING"], "must merge, not replace"
      assert_equal "pt-BR", environment["SCREENSHOT_KIT_LANGUAGE"]
      assert_equal "pt_BR", environment["SCREENSHOT_KIT_LOCALE"]
      assert_equal({ "APP_PLAN" => "Força total" }, JSON.parse(environment.fetch("SCREENSHOT_KIT_APP_ENV")))

      # The base must be untouched: the English pass replays it.
      base_environment = read_plist(base).fetch("TestConfigurations").first
      refute base_environment.key?("TestLanguage")
      refute base_environment.fetch("TestTargets").first.fetch("TestingEnvironmentVariables").key?("SCREENSHOT_KIT_LANGUAGE")
    end
  end

  def test_locale_without_app_env_omits_the_app_env_variable
    Dir.mktmpdir do |dir|
      base = write_fixture(dir)
      locale = ScreenshotKit::KitLocale.new(asc: "hi", language: "hi", region: "IN", app_env: {})
      copy = ScreenshotKit::Xctestrun.new(ui: RecordingUI.new).localized_copy(base, locale)
      environment = read_plist(copy).fetch("TestConfigurations").first
                                    .fetch("TestTargets").first.fetch("TestingEnvironmentVariables")
      assert_equal "hi", environment["SCREENSHOT_KIT_LANGUAGE"]
      assert_equal "hi_IN", environment["SCREENSHOT_KIT_LOCALE"]
      refute environment.key?("SCREENSHOT_KIT_APP_ENV")
    end
  end
end

