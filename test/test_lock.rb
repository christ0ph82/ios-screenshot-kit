# frozen_string_literal: true

require_relative "test_helper"

class TestLock < Minitest::Test
  include KitTestHelpers

  def test_acquire_and_release
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".lock")
      lock = ScreenshotKit::Lock.new(path, ui: RecordingUI.new)
      lock.with_lock do
        assert Dir.exist?(path)
        assert_equal Process.pid.to_s, File.read(File.join(path, "pid"))
      end
      refute Dir.exist?(path)
    end
  end

  def test_refuses_when_held_by_live_process
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".lock")
      Dir.mkdir(path)
      File.write(File.join(path, "pid"), Process.pid.to_s)

      lock = ScreenshotKit::Lock.new(path, ui: RecordingUI.new)
      error = assert_raises(ScreenshotKit::Error) { lock.acquire }
      assert_match(/Another capture run \(pid #{Process.pid}\)/, error.message)
      # The live holder's lock must survive the refusal.
      assert Dir.exist?(path)
    end
  end

  def test_reaps_stale_lock
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".lock")
      Dir.mkdir(path)
      # A pid that cannot be running: pid_max on macOS is 99998.
      File.write(File.join(path, "pid"), "999999")

      ui = RecordingUI.new
      lock = ScreenshotKit::Lock.new(path, ui: ui)
      lock.acquire
      assert_equal Process.pid.to_s, File.read(File.join(path, "pid"))
      assert(ui.importants.any? { |line| line.include?("stale") })
      lock.release
    end
  end

  def test_releases_on_exception
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".lock")
      lock = ScreenshotKit::Lock.new(path, ui: RecordingUI.new)
      assert_raises(RuntimeError) do
        lock.with_lock { raise "boom" }
      end
      refute Dir.exist?(path)
    end
  end
end

