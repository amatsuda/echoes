# frozen_string_literal: true

require 'pty'
require 'io/console'

module Echoes
  class Terminal
    attr_reader :screen

    def initialize(command: Echoes.config.shell, rows: nil, cols: nil)
      size = IO.console&.winsize || [24, 80]
      @rows = rows || size[0]
      @cols = cols || size[1]
      @command = command
      @screen = Screen.new(rows: @rows, cols: @cols)
      @parser = Parser.new(@screen)
    end

    def run
      PTY.spawn(@command) do |read_io, write_io, pid|
        @read_io = read_io
        @write_io = write_io
        @pid = pid

        @read_io.winsize = [@rows, @cols]

        setup_signal_handlers

        STDIN.raw do
          reader = Thread.new { read_loop }
          write_loop
          reader.kill
        end
      end
    end

    private

    def read_loop
      loop do
        data = @read_io.read_nonblock(4096)
        @parser.feed(data)
        render
      rescue IO::WaitReadable
        IO.select([@read_io])
        retry
      rescue EOFError, Errno::EIO
        break
      end
    end

    def write_loop
      loop do
        data = STDIN.read_nonblock(4096)
        @write_io.write(data)
      rescue IO::WaitReadable
        IO.select([STDIN])
        retry
      rescue EOFError, Errno::EIO
        break
      end
    end

    def render
      buf = +"\e[H"
      last_fg = nil
      last_bg = nil
      last_bold = false
      last_underline = false
      last_inverse = false

      @screen.grid.each_with_index do |row, r|
        row.each do |cell|
          if cell.fg != last_fg || cell.bg != last_bg || cell.bold != last_bold ||
             cell.underline != last_underline || cell.inverse != last_inverse
            codes = [0]
            codes << 1 if cell.bold
            codes << 4 if cell.underline
            codes << 7 if cell.inverse
            if cell.fg
              codes << (cell.fg < 8 ? cell.fg + 30 : cell.fg - 8 + 90)
            end
            if cell.bg
              codes << (cell.bg < 8 ? cell.bg + 40 : cell.bg - 8 + 100)
            end
            buf << "\e[#{codes.join(';')}m"
            last_fg = cell.fg
            last_bg = cell.bg
            last_bold = cell.bold
            last_underline = cell.underline
            last_inverse = cell.inverse
          end
          buf << cell.char
        end
        buf << "\r\n" unless r == @screen.rows - 1
      end

      buf << "\e[0m"
      buf << "\e[#{@screen.cursor.row + 1};#{@screen.cursor.col + 1}H"
      buf << (@screen.cursor.visible ? "\e[?25h" : "\e[?25l")
      STDOUT.write(buf)
    end

    def setup_signal_handlers
      Signal.trap(:WINCH) do
        if IO.console
          @rows, @cols = IO.console.winsize
          @screen.resize(@rows, @cols)
          @read_io.winsize = [@rows, @cols]
          render
        end
      end
    end
  end
end
