# frozen_string_literal: true

require "fileutils"

module ScreenshotKit
  class Lock
    def initialize(path, ui: PlainUI.new)
      @path = path
      @ui = ui
    end

    def with_lock
      acquire
      begin
        yield
      ensure
        release
      end
    end

    def acquire
      FileUtils.mkdir_p(File.dirname(@path))
      begin
        Dir.mkdir(@path)
      rescue Errno::EEXIST
        holder = begin
          File.read(File.join(@path, "pid")).strip
        rescue StandardError
          ""
        end
        if !holder.empty? && process_alive?(holder)
          @ui.user_error!(
            "Another capture run (pid #{holder}) is driving the simulator; wait for it to finish. " \
            "Lock: #{@path}"
          )
        end
        @ui.important("Clearing stale simulator-capture lock (pid #{holder.empty? ? "unknown" : holder} is gone)")
        FileUtils.rm_rf(@path)
        begin
          Dir.mkdir(@path)
        rescue Errno::EEXIST
          @ui.user_error!("Could not acquire the simulator-capture lock at #{@path}; another run grabbed it first.")
        end
      end
      write_pid
    end

    def release
      FileUtils.rm_rf(@path)
    end

    private

    def write_pid
      File.write(File.join(@path, "pid"), Process.pid.to_s)
    end

    def process_alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue Errno::ESRCH, ArgumentError
      false
    rescue Errno::EPERM
      true
    end
  end
end

