# frozen_string_literal: true

require "rbconfig"

module RedQuilt
  # Opens a local HTML file in the OS default browser when `--open` is set.
  # Best-effort: unsupported platforms or spawn failures are logged but
  # never abort the CLI.
  class BrowserLauncher
    def initialize(err:)
      @err = err
    end

    def launch(path)
      command = platform_command
      unless command
        @err.puts "redquilt: --open is not supported on this platform; skipping."
        return
      end

      pid = Process.spawn(*command, path, in: :close, out: File::NULL, err: File::NULL)
      Process.detach(pid)
    rescue StandardError => e
      @err.puts "redquilt: failed to open browser: #{e.message}"
    end

    private

    def platform_command
      case RbConfig::CONFIG["host_os"]
      when /darwin/ then ["open"]
      when /linux|bsd/ then ["xdg-open"]
      when /mswin|mingw|cygwin/ then ["cmd.exe", "/c", "start", ""]
      end
    end
  end
end
