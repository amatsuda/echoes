# frozen_string_literal: true

require 'pty'

module Echoes
  class Tab
    attr_accessor :screen, :parser, :pty_read, :pty_write, :pty_pid,
                  :scroll_offset, :scroll_accum, :title

    def initialize(command:, rows:, cols:)
      @screen = Screen.new(rows: rows, cols: cols)
      @parser = Parser.new(@screen)
      @pty_read, @pty_write, @pty_pid = PTY.spawn(command)
      @pty_read.winsize = [rows, cols]
      @scroll_offset = 0
      @scroll_accum = 0.0
      @title = File.basename(command)
    end

    def alive?
      Process.waitpid(@pty_pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      false
    end

    def resize(rows, cols)
      @screen.resize(rows, cols)
      @pty_read.winsize = [rows, cols]
    rescue Errno::EIO, IOError
    end

    def close
      @pty_write.close rescue nil
      @pty_read.close rescue nil
      Process.kill(:HUP, @pty_pid) rescue nil
    end
  end
end
