# frozen_string_literal: true

module ScreenshotKit
  # Consumers hand in how commands run and how messages surface, so the kit
  # works identically inside a Fastfile (pass fastlane's `sh` and `UI`) and in
  # a bare script or test (use these defaults).
  #
  # Two callables, not one, because the two uses genuinely differ: `sh` streams
  # a long xcodebuild live and only its exit status matters; `capture` exists
  # for `simctl list -j`-style calls whose stdout is the result.
  module Shell
    module_function

    def default_sh
      lambda do |command|
        puts "$ #{command}"
        ok = Kernel.system(command)
        raise CommandFailed, "Command failed (exit #{$?.exitstatus}): #{command}" unless ok
      end
    end

    def default_capture
      lambda do |command|
        output = `#{command}`
        raise CommandFailed, "Command failed (exit #{$?.exitstatus}): #{command}" unless $?.success?

        # A bare non-interactive shell has no locale, so Ruby reads child
        # output as US-ASCII and the first multibyte character — a localized
        # marketing string inside a plist, say — raises mid-parse. Everything
        # this lambda captures (simctl JSON, plutil output) is UTF-8.
        output.force_encoding(Encoding::UTF_8)
      end
    end
  end

  # The slice of fastlane's UI the kit uses. Pass fastlane's `UI` directly —
  # the method names match — or take this default.
  class PlainUI
    def header(text) = puts("--- #{text} ---")
    def message(text) = puts(text)
    def important(text) = warn("! #{text}")
    def success(text) = puts(text)
    def user_error!(text) = raise(Error, text)
  end
end

