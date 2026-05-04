# frozen_string_literal: true

require 'stringio'

module Echoes
  # Wraps a Rubish::REPL running in the same Ruby process as Echoes,
  # exposing a small structured API in place of the byte-stream / PTY
  # interface that an external shell would use.
  #
  # Phase 1 scope: builtins and non-TTY-needy external commands work
  # (their output flows through Ruby's $stdout, which we redirect for
  # capture). Interactive external programs that need a real TTY (vim,
  # less, htop, ...) are NOT handled here — they're a follow-up where
  # rubish would ask the host for a per-command PTY.
  class EmbeddedShell
    def initialize
      require 'rubish'
      @repl = Rubish::REPL.new(no_rc: true)
      @output_buffer = +''
    end

    # Submit a command line for execution. Stdout/stderr produced by
    # builtins (and Ruby-side code) is captured into the output buffer;
    # call `read_available_output` afterwards to drain it.
    def submit_line(line)
      capture_output { @repl.send(:execute, line) }
    end

    # Drain and return whatever output has accumulated since the last
    # call. Empty String if nothing.
    def read_available_output
      data = @output_buffer.dup
      @output_buffer.clear
      data
    end

    # Structured prompt segments — Array of
    # `{text:, fg:, bg:, bold:, italic:, underline:, inverse:}` hashes.
    # See Rubish::Prompt#prompt_segments for fg/bg encoding.
    def prompt_segments
      @repl.prompt_segments
    end

    # The prompt as a single String containing ANSI escape codes — useful
    # for hosts that already have an ANSI-aware renderer and want to feed
    # the prompt through it (vs. parsing segments themselves).
    def prompt
      @repl.prompt
    end

    # Tab-completion candidates for the given input line and cursor
    # position. Returns an Array of String.
    def complete_at(line:, point:)
      @repl.complete_at(line: line, point: point)
    end

    # Last command's exit status (0 on success).
    def last_status
      @repl.instance_variable_get(:@last_status) || 0
    end

    # Current working directory of the embedded shell. Builtins like
    # `cd` mutate this via `Dir.chdir`, so it always reflects whatever
    # the shell believes it's in.
    def cwd
      Dir.pwd
    end

    private

    def capture_output
      old_out = $stdout
      old_err = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      yield
      @output_buffer << $stdout.string
      @output_buffer << $stderr.string
    ensure
      $stdout = old_out
      $stderr = old_err
    end
  end
end
