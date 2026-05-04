# frozen_string_literal: true

require 'pty'

module Echoes
  # A Pane is one shell session within a Tab. It owns a Screen (the cell
  # grid the user sees) and a backing shell — either an external program
  # spawned via PTY (the default), or a Rubish::REPL running in-process
  # via Echoes::EmbeddedShell.
  #
  # Callers that need to send bytes to the shell or pull bytes back use
  # `write_input` / `read_available_output`. Don't reach for the legacy
  # `pty_read` / `pty_write` accessors — they're nil in embedded mode.
  class Pane
    attr_accessor :screen, :parser, :pty_read, :pty_write, :pty_pid,
                  :scroll_offset, :scroll_accum, :title, :copy_mode
    attr_reader :embedded_shell

    def initialize(command:, rows:, cols:, cwd: nil, embedded: false)
      @screen = Screen.new(rows: rows, cols: cols)
      if embedded
        require_relative 'embedded_shell'
        @embedded_shell = EmbeddedShell.new
        @parser = Parser.new(@screen, writer: ->(_s) { })
        @title = 'rubish'
        @input_buffer = +''
      else
        start_dir = (cwd && Dir.exist?(cwd)) ? cwd : Dir.home
        Dir.chdir(start_dir) do
          ENV['TERM'] = Echoes.config.term
          ENV['LANG'] ||= 'en_US.UTF-8'
          ENV['LC_CTYPE'] = 'UTF-8'
          @pty_read, @pty_write, @pty_pid = PTY.spawn(command)
          @pty_read.winsize = [rows, cols]
        end
        @parser = Parser.new(@screen, writer: ->(s) { @pty_write.write(s) rescue nil })
        @title = File.basename(command)
      end
      @scroll_offset = 0
      @scroll_accum = 0.0
      @copy_mode = nil
      render_initial_prompt if embedded
    end

    def embedded?
      !@embedded_shell.nil?
    end

    # Send raw bytes to the shell. In PTY mode these go through pty_write
    # to the child process. In embedded mode there is no per-keystroke
    # input channel (line editing happens in Echoes itself), so this is
    # a no-op — the host should call `submit_line` for completed lines.
    def write_input(bytes)
      if embedded?
        # phase-1 stub: no per-keystroke routing yet
      else
        @pty_write.write(bytes) rescue nil
      end
    end

    # Submit a complete line of input. PTY mode writes the line plus CR;
    # embedded mode hands the line directly to the in-process REPL.
    def submit_line(line)
      if embedded?
        @embedded_shell.submit_line(line)
      else
        @pty_write.write("#{line}\r") rescue nil
      end
    end

    # Drain whatever output bytes are available from the shell right now.
    # Returns "" if nothing is ready; never blocks; never raises.
    def read_available_output(max = 16384)
      if embedded?
        @embedded_shell.read_available_output
      else
        @pty_read.read_nonblock(max)
      end
    rescue IO::WaitReadable, EOFError, Errno::EIO, IOError
      ''
    end

    def alive?
      if embedded?
        true
      else
        Process.waitpid(@pty_pid, Process::WNOHANG).nil?
      end
    rescue Errno::ECHILD
      false
    end

    def resize(rows, cols)
      @screen.resize(rows, cols)
      @pty_read.winsize = [rows, cols] unless embedded?
    rescue Errno::EIO, IOError
    end

    def close
      return if embedded?
      @pty_write.close rescue nil
      @pty_read.close rescue nil
      Process.kill(:HUP, @pty_pid) rescue nil
    end

    def process_output(data)
      @parser.feed(data)
    end

    # Embedded-mode keyboard handling. Returns true if the pane consumed
    # the event, false if the GUI should fall through to its own
    # PTY-style handling (which is the only mode in non-embedded panes).
    #
    # Phase 1: a tiny line editor — printable chars echo to the screen
    # and append to @input_buffer; Backspace pops a char and erases the
    # last cell; Enter submits the buffered line, captures output, and
    # re-renders the prompt. No history nav, no left/right cursor moves,
    # no Tab completion yet.
    def handle_key(chars:, flags: 0)
      return false unless embedded?
      return true if chars.nil? || chars.empty?

      case chars
      when "\r", "\n"
        line = @input_buffer
        @input_buffer = +''
        process_output("\r\n")
        @embedded_shell.submit_line(line)
        drain_and_render_output
        render_prompt
      when "\u{7F}", "\b"  # DEL (macOS Backspace) or BS
        unless @input_buffer.empty?
          @input_buffer.chop!
          process_output("\b \b")
        end
      else
        # Printable ASCII / multibyte; ignore single-byte controls (< 0x20)
        # other than the cases above.
        first = chars.bytes.first
        if first && first >= 0x20
          @input_buffer << chars
          process_output(chars)
        end
      end
      true
    end

    private

    def drain_and_render_output
      out = @embedded_shell.read_available_output
      return if out.empty?
      # Builtins emit bare \n; the cell-grid parser expects \r\n.
      process_output(out.gsub(/(?<!\r)\n/, "\r\n"))
    end

    def render_initial_prompt
      drain_and_render_output  # in case any startup output is buffered
      render_prompt
    end

    def render_prompt
      process_output(@embedded_shell.prompt.to_s)
    end
  end
end
