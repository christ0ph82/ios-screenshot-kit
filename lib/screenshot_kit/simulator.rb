# frozen_string_literal: true

require "json"

module ScreenshotKit
  # simctl plumbing for the matrix runner: resolving devices, booting them,
  # and dressing the status bar for store captures.
  class Simulator
    def initialize(capture: Shell.default_capture, sh: Shell.default_sh, ui: PlainUI.new)
      @capture = capture
      @sh = sh
      @ui = ui
    end

    def udid(device_name)
      devices = JSON.parse(@capture.call("xcrun simctl list devices available -j")).fetch("devices")
      match = devices.values.flatten.find { |device| device["name"] == device_name }
      @ui.user_error!("No available simulator named #{device_name.inspect}") if match.nil?
      match.fetch("udid")
    end

    # Boot + status bar in one step, safe to call repeatedly: the retry path
    # shuts every simulator down between attempts, so each attempt has to be
    # able to rebuild this state from nothing.
    #
    # The override is what keeps a capture from shipping with the wall-clock
    # time and battery of whatever Mac ran it: 9:41, full battery, full bars —
    # the store-clean status bar. Overrides do not survive shutdown, which is
    # why this must run per attempt, never once per run.
    def prepare(device_name, status_bar_time: "9:41", appearance: "light")
      device_udid = udid(device_name)
      # Boot tolerantly, without a state pre-check: on a shared Mac the device
      # can transition to Booted between a check and the boot call, and simctl
      # answers that race with exit 149 "Unable to boot device in current
      # state: Booted" — which cost a whole matrix run once. `bootstatus -b`
      # is the authority: it boots when needed and waits for readiness, and a
      # device that genuinely cannot boot fails the capture itself with a far
      # clearer error than a boot exit code.
      run_tolerantly("xcrun simctl boot #{device_udid}")
      run_tolerantly("xcrun simctl bootstatus #{device_udid} -b")
      # Appearance is persistent device state; pin it or inherit whatever the
      # last occupant of this shared simulator left behind.
      run_tolerantly("xcrun simctl ui #{device_udid} appearance #{appearance}") if appearance
      if status_bar_time
        run_tolerantly(
          "xcrun simctl status_bar #{device_udid} override --time '#{status_bar_time}' " \
          "--batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3"
        )
      end
      device_udid
    end

    def clear_status_bar(device_udid)
      run_tolerantly("xcrun simctl status_bar #{device_udid} clear")
    end

    # Shutdown, never erase. Transient CoreSimulator failures (a runner bundle
    # reaped into containermanagerd/Dead mid-launch, an SBMainWorkspace launch
    # denial) clear when the device restarts; erasing would wipe simulators
    # over a fault that costs nothing.
    def shutdown_all
      run_tolerantly("xcrun simctl shutdown all")
    end

    private

    # Status-bar and bootstatus failures are not worth failing a capture over;
    # the capture itself is the arbiter.
    def run_tolerantly(command)
      @sh.call(command)
    rescue StandardError => error
      @ui.important("Tolerated: #{error.message.to_s.lines.first&.strip}")
    end
  end
end

