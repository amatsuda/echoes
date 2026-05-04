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
  end
end
