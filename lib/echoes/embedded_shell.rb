# frozen_string_literal: true

require 'stringio'
require 'pty'

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
      # Phase 1 doesn't forward keystrokes to running programs, so anything
      # that auto-launches a pager (`git log`, `git diff`, `man`, …) would
      # hang waiting for navigation keys we never deliver. Default the
      # pager-related env vars to `cat` so those tools just dump their
      # output. The user can override by setting their own value before
      # launching Echoes.
      ENV['GIT_PAGER'] ||= 'cat'
      ENV['PAGER'] ||= 'cat'
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

    # Capture stdout and stderr produced during the block, including
    # writes from forked child processes — and additionally make those
    # writes look like they're going to a real terminal, so programs
    # that branch on isatty(stdout) (`ls --color=auto`, `git log`,
    # paginators, …) emit their richer output instead of the
    # "redirected to a file" variant.
    #
    # We do this by allocating a pty pair (master, slave). The slave
    # is a TTY device. We point this process's FD 1 / FD 2 at the
    # slave (via STDOUT.reopen). Any fork() that follows inherits FD
    # 1/2 still pointing at the slave, so isatty returns true for the
    # child too.
    #
    # A reader thread drains the master concurrently so a child
    # producing more than the kernel pty buffer doesn't deadlock.
    # Errno::EIO is the canonical "all writers closed" outcome on
    # macOS PTY masters; we treat it as EOF.
    def capture_output
      master, slave = PTY.open
      reader = Thread.new do
        captured = +''
        begin
          loop { captured << master.readpartial(4096) }
        rescue EOFError, IOError, Errno::EIO
        end
        captured
      end

      saved_stdout = STDOUT.dup
      saved_stderr = STDERR.dup
      saved_stdin  = STDIN.dup
      saved_stdout_glob = $stdout
      saved_stderr_glob = $stderr
      saved_stdin_glob  = $stdin

      STDOUT.reopen(slave)
      STDERR.reopen(slave)
      # Phase 1 has no way to forward user keystrokes to a running command,
      # so wire stdin to /dev/null. Programs that try to read see EOF
      # immediately rather than blocking on input that will never arrive.
      STDIN.reopen('/dev/null', 'r')
      $stdout = STDOUT
      $stderr = STDERR
      $stdin  = STDIN

      begin
        yield
        STDOUT.flush rescue nil
        STDERR.flush rescue nil
      ensure
        STDOUT.reopen(saved_stdout)
        STDERR.reopen(saved_stderr)
        STDIN.reopen(saved_stdin)
        saved_stdout.close
        saved_stderr.close
        saved_stdin.close
        $stdout = saved_stdout_glob
        $stderr = saved_stderr_glob
        $stdin  = saved_stdin_glob
        slave.close
      end

      @output_buffer << reader.value
      master.close
    end
  end
end
