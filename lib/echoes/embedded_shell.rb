# frozen_string_literal: true

require 'pty'

module Echoes
  # Wraps a Rubish::REPL running in the same Ruby process as Echoes,
  # exposing a small structured API in place of the byte-stream / PTY
  # interface that an external shell would use.
  #
  # Builtins (cd, echo, export, …) execute synchronously on the calling
  # thread — they're cheap.
  #
  # External commands (anything that forks: ls, git, grep, vim, less, …)
  # run asynchronously on a worker thread. While a command is in flight:
  #
  #   - submit_line returns immediately, so the GUI's main thread stays
  #     responsive.
  #   - Output streams into the buffer and the host drains it via
  #     read_available_output on each tick.
  #   - Keystrokes the user types in the GUI can be forwarded to the
  #     running command's stdin via forward_input. (Echo, line discipline,
  #     and raw-mode are handled by the pty kernel ldisc — the same way
  #     they would be in a normal terminal.)
  #   - reap_if_done, called from the main thread, detects that the
  #     command has exited, joins the reader thread, restores the parent
  #     process's file descriptors, and tears the pty down.
  class EmbeddedShell
    def initialize
      require 'rubish'
      @repl = Rubish::REPL.new(no_rc: true)
      @output_buffer = +''
      @output_lock = Mutex.new
      # Anything that auto-launches a pager (`git log`, `git diff`,
      # `man`, …) would otherwise sit waiting for keys we don't
      # forward to the running command yet. Default the pager-related
      # env vars to `cat` so those tools just dump their output. The
      # user can override by setting a value before launching Echoes.
      ENV['GIT_PAGER'] ||= 'cat'
      ENV['PAGER'] ||= 'cat'
    end

    # Kick off a command line. Returns immediately. Use #running? to
    # check status, #read_available_output to stream output, and
    # #reap_if_done from the main thread to finalize when the command
    # has exited.
    #
    # `rows:` / `cols:` set the pty winsize so programs that query
    # terminal dimensions (vim, less, top, anything that calls
    # `tcgetwinsize`) see the actual window size, not the kernel
    # default of 24x80.
    def submit_line(line, rows: 24, cols: 80)
      return if running?

      master, slave = PTY.open
      slave.winsize = [rows, cols] rescue nil
      @master = master
      @slave  = slave

      # Reader thread drains the pty master concurrently — without it a
      # program writing more than the kernel's pty buffer would block.
      @reader = Thread.new(master) do |m|
        begin
          loop do
            chunk = m.readpartial(4096)
            @output_lock.synchronize { @output_buffer << chunk }
          end
        rescue EOFError, IOError, Errno::EIO
          # done
        end
      end

      # Save and redirect the parent's FDs. Children that fork from this
      # process inherit FD 0/1/2 = pty slave, so they see a real TTY.
      # The original FDs go back into place during reap_if_done.
      @saved_stdout = STDOUT.dup
      @saved_stderr = STDERR.dup
      @saved_stdin  = STDIN.dup
      @saved_stdout_glob = $stdout
      @saved_stderr_glob = $stderr
      @saved_stdin_glob  = $stdin

      STDOUT.reopen(slave)
      STDERR.reopen(slave)
      STDIN.reopen(slave)
      $stdout = STDOUT
      $stderr = STDERR
      $stdin  = STDIN

      # Bypassing rubish's process_line means we also bypass its
      # history-append. Add the entry ourselves so up/down arrows in
      # Echoes' line editor work, and so rubish's `history` builtin
      # sees it.
      Reline::HISTORY << line unless line.empty? || line.strip.empty?

      @command_thread = Thread.new do
        begin
          @repl.send(:execute, line)
          STDOUT.flush rescue nil
          STDERR.flush rescue nil
        rescue => e
          @output_lock.synchronize do
            @output_buffer << "rubish: #{e.class}: #{e.message}\r\n"
          end
        end
      end
    end

    # Frozen snapshot of the command history (oldest first). Most-recent
    # is the last element.
    def history
      Reline::HISTORY.to_a
    end

    # Update the running command's pty winsize. Called when Echoes'
    # window is resized mid-command — kernel pty winsize change emits
    # SIGWINCH to the foreground process group on the pty, so vim/less
    # / etc. repaint at the new size. No-op when no command is in
    # flight (the next submit_line will pick up the new dimensions).
    def resize(rows:, cols:)
      return unless @slave
      @slave.winsize = [rows, cols]
    rescue IOError, Errno::EIO
    end

    def running?
      !@command_thread.nil? && @command_thread.alive?
    end

    # Forward bytes from the GUI's keyboard to the running command's
    # stdin. No-op if no command is running.
    def forward_input(bytes)
      return unless @command_thread
      @master.write(bytes) rescue nil
    end

    # Send SIGINT (Ctrl-C) to whatever process group is running on the
    # pty. The kernel routes the signal to the foreground process group
    # of the controlling tty. No-op if no command is running.
    def interrupt
      return unless @command_thread
      # ETX (^C, 0x03) on a pty's master end is converted by the line
      # discipline into a SIGINT delivered to the foreground process
      # group. Cleaner than chasing PIDs ourselves.
      @master.write("\x03") rescue nil
    end

    # Called from the main thread on each tick while a command is in
    # flight. If the command thread has exited, restore the parent's
    # FDs, drain the remaining output, and tear down the pty. Returns
    # true on the tick where cleanup happened, false otherwise.
    def reap_if_done
      return false unless @command_thread
      return false if @command_thread.alive?

      STDOUT.reopen(@saved_stdout)
      STDERR.reopen(@saved_stderr)
      STDIN.reopen(@saved_stdin)
      @saved_stdout.close
      @saved_stderr.close
      @saved_stdin.close
      $stdout = @saved_stdout_glob
      $stderr = @saved_stderr_glob
      $stdin  = @saved_stdin_glob

      @slave.close   # closing the slave gives the reader EOF on master
      @reader.join
      @master.close

      @master = nil
      @slave  = nil
      @reader = nil
      @command_thread = nil
      true
    end

    # Drain whatever output bytes are currently buffered. Empty String
    # if nothing is ready; never blocks.
    def read_available_output
      @output_lock.synchronize do
        data = @output_buffer.dup
        @output_buffer.clear
        data
      end
    end

    # Submit and block until the command exits. The async submit_line
    # is what the GUI uses; this helper is for scripts and tests that
    # don't have a tick loop.
    def submit_and_wait(line, rows: 24, cols: 80, timeout: 30)
      submit_line(line, rows: rows, cols: cols)
      deadline = Time.now + timeout
      while running?
        if Time.now > deadline
          interrupt
          break
        end
        sleep 0.01
      end
      reap_if_done
      nil
    end

    # Structured prompt segments — Array of
    # `{text:, fg:, bg:, bold:, italic:, underline:, inverse:}` hashes.
    def prompt_segments
      @repl.prompt_segments
    end

    # The prompt as a single String containing ANSI escape codes.
    def prompt
      @repl.prompt
    end

    # Tab-completion candidates for the given input line and cursor
    # position. Returns an Array of String.
    def complete_at(line:, point:)
      @repl.complete_at(line: line, point: point)
    end

    # Classify a candidate command line. :ok / :incomplete / :error.
    # See Rubish::REPL#try_parse.
    def try_parse(line)
      @repl.try_parse(line)
    end

    # Tokenize a line for syntax highlighting. Returns an Array of
    # `Rubish::Lexer::Token` (each has `:type` and `:value`). Empty
    # array on lexer failure — never raises.
    def tokenize(line)
      @repl.tokenize(line)
    end

    # Continuation prompt (PS2). Used when the user's input is
    # incomplete (e.g., they typed `if true; then` and pressed Enter
    # without a closing `fi`).
    def continuation_prompt
      @repl.send(:continuation_prompt)
    end

    # Last command's exit status (0 on success).
    def last_status
      @repl.instance_variable_get(:@last_status) || 0
    end

    # Current working directory of the embedded shell.
    def cwd
      Dir.pwd
    end
  end
end
