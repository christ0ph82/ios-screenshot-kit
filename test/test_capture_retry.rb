# frozen_string_literal: true

require_relative "test_helper"
require "json"

# The matrix runner's retry, lock, and choreography — proven with injected
# runners, no simulator. The real xcodebuild path is integration-verified by
# the consumer repos' lanes.
class TestCaptureRetry < Minitest::Test
  include KitTestHelpers

  DEVICE = "iPhone 17 Pro Max"
  UDID = "AAAA-1111"

  # A fake command layer: simctl queries answer from canned JSON, xcodebuild
  # test invocations fail `failures` times before succeeding, and a successful
  # test invocation writes the PNGs SnapshotHelper would have.
  class FakeRunner
    attr_reader :commands, :test_attempts

    def initialize(staging_dir, surface_ids, failures: 0)
      @staging_dir = staging_dir
      @surface_ids = surface_ids
      @failures = failures
      @commands = []
      @test_attempts = 0
    end

    def sh
      lambda do |command|
        @commands << command
        if command.include?("xcodebuild") && (command.include?(" test ") || command.include?("test-without-building"))
          @test_attempts += 1
          raise ScreenshotKit::CommandFailed, "simulated transient failure" if @test_attempts <= @failures

          @surface_ids.each do |id|
            File.write(File.join(@staging_dir, "#{DEVICE}-#{id}.png"), "png-#{id}-#{@test_attempts}")
          end
        end
      end
    end

    def capture
      lambda do |command|
        @commands << command
        JSON.generate("devices" => { "ios" => [{ "name" => DEVICE, "udid" => UDID, "state" => "Shutdown" }] })
      end
    end
  end

  def capture_config(root)
    build_config(
      root,
      devices: [{ name: DEVICE, pixels: [64, 128] }],
      locales: [{ asc: "fr-CA", language: "fr-CA", region: "CA" }],
      build_once: false,
      cache_dir: File.join(root, "cache"),
      staging_dir: File.join(root, "staging"),
      lock_path: File.join(root, ".lock"),
      machine_lock_path: File.join(root, ".machine-lock")
    )
  end

  def test_transient_failure_retries_resets_and_recovers
    Dir.mktmpdir do |root|
      config = capture_config(root)
      runner = FakeRunner.new(config.staging_dir, config.surface_ids, failures: 1)
      ui = RecordingUI.new

      cache = ScreenshotKit::Capture.new(config, sh: runner.sh, capture: runner.capture, ui: ui).run!

      # One failed attempt + retry for fr-CA, then a clean English pass.
      assert_equal 3, runner.test_attempts
      assert(ui.importants.any? { |line| line.include?("attempt 1 of 3") })
      assert(runner.commands.any? { |command| command.include?("simctl shutdown all") },
             "retry must reset simulator state")
      # The reset takes the status bar with it, so prepare must run again:
      # boot/status_bar commands appear more than once for the device.
      status_bar_calls = runner.commands.count { |command| command.include?("status_bar #{UDID} override") }
      assert_operator status_bar_calls, :>=, 2

      # Choreography: fr-CA landed in its directory, English stayed flat.
      assert_equal config.surface_ids.sort,
                   Dir[File.join(cache, "fr-CA", "*.png")].map { |f| File.basename(f, ".png").sub("#{DEVICE}-", "") }.sort
      assert_equal config.surface_ids.sort,
                   Dir[File.join(cache, "*.png")].map { |f| File.basename(f, ".png").sub("#{DEVICE}-", "") }.sort

      # Lock released.
      refute Dir.exist?(config.lock_path)
      # Status bar cleared at the end.
      assert(runner.commands.any? { |command| command.include?("status_bar #{UDID} clear") })
    end
  end

  def test_persistent_failure_exhausts_attempts_and_raises
    Dir.mktmpdir do |root|
      config = capture_config(root)
      runner = FakeRunner.new(config.staging_dir, config.surface_ids, failures: 99)
      ui = RecordingUI.new

      assert_raises(ScreenshotKit::CommandFailed) do
        ScreenshotKit::Capture.new(config, sh: runner.sh, capture: runner.capture, ui: ui).run!
      end
      assert_equal config.attempts, runner.test_attempts
      # A genuine failure must still release the lock for the next run.
      refute Dir.exist?(config.lock_path)
    end
  end

  def test_unknown_locale_narrowing_is_rejected
    Dir.mktmpdir do |root|
      config = capture_config(root)
      runner = FakeRunner.new(config.staging_dir, config.surface_ids)
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Capture.new(config, sh: runner.sh, capture: runner.capture, ui: RecordingUI.new)
                              .run!(locales: ["xx-XX"])
      end
      assert_match(/Unknown screenshot locale/, error.message)
    end
  end

  def test_localized_pass_writing_nothing_fails_hard
    Dir.mktmpdir do |root|
      config = capture_config(root)
      runner = FakeRunner.new(config.staging_dir, [], failures: 0) # succeeds but writes no PNGs
      error = assert_raises(ScreenshotKit::Error) do
        ScreenshotKit::Capture.new(config, sh: runner.sh, capture: runner.capture, ui: RecordingUI.new).run!
      end
      assert_match(/wrote no PNGs/, error.message)
    end
  end
end

