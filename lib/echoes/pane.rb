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
        @input_cursor = 0     # offset within @input_buffer (0..length)
        @embedded_running = false
        @history_index = nil  # nil = not browsing; integer = browsing
        @history_saved = nil  # input held aside while browsing
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
    #
    # In embedded mode this is also where we detect that an async
    # command has finished — we drain its trailing output, append a
    # fresh prompt, and re-enable the in-pane line editor.
    def read_available_output(max = 16384)
      if embedded?
        out = @embedded_shell.read_available_output
        if @embedded_running && @embedded_shell.reap_if_done
          out << @embedded_shell.read_available_output
          out << @embedded_shell.prompt.to_s
          @embedded_running = false
        end
        out
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
      if embedded?
        @embedded_shell.resize(rows: rows, cols: cols)
      else
        @pty_read.winsize = [rows, cols]
      end
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
    # Two states:
    #   - prompt mode (no command running): printable chars echo to the
    #     screen and append to @input_buffer; Backspace pops a char and
    #     erases the last cell; Enter submits the buffered line for
    #     async execution.
    #   - running mode (a command is in flight): keystrokes get
    #     forwarded to the command's stdin via the pty master, so the
    #     user can type into vim, scroll less, etc. Ctrl-C interrupts.
    def handle_key(chars:, flags: 0)
      return false unless embedded?
      return true if chars.nil? || chars.empty?

      if @embedded_shell.running?
        # Translate macOS special-key code points to the ANSI escape
        # sequences a real terminal would have produced — that's what
        # programs reading from the pty (vim, less, etc.) expect.
        translated = translate_for_pty(chars, flags)
        @embedded_shell.forward_input(translated)
        return true
      end

      case chars
      when "\r", "\n"
        line = @input_buffer
        @input_buffer = +''
        @input_cursor = 0
        @history_index = nil
        @history_saved = nil
        process_output("\r\n")
        @embedded_shell.submit_line(line, rows: @screen.rows, cols: @screen.cols)
        @embedded_running = true
      when "\u{7F}", "\b"
        delete_before_cursor
      when "\u{F728}"  # NSDeleteFunctionKey (forward delete)
        delete_at_cursor
      when "\u{F702}"  # NSLeftArrowFunctionKey
        cursor_left
      when "\u{F703}"  # NSRightArrowFunctionKey
        cursor_right
      when "\u{F729}"  # NSHomeFunctionKey
        cursor_home
      when "\u{F72B}"  # NSEndFunctionKey
        cursor_end
      when "\u{F700}"  # NSUpArrowFunctionKey
        history_step(-1)
      when "\u{F701}"  # NSDownArrowFunctionKey
        history_step(1)
      when "\t"
        complete_input
      else
        first = chars.bytes.first
        if first && first >= 0x20
          @history_index = nil  # editing ends history-walk mode
          @history_saved = nil
          insert_at_cursor(chars)
        end
      end
      true
    end

    private

    def render_initial_prompt
      process_output(@embedded_shell.prompt.to_s)
    end

    # ↑/↓ history navigation. step is -1 (older) or +1 (newer).
    def history_step(step)
      hist = @embedded_shell.history
      return if hist.empty?

      if @history_index.nil?
        return if step > 0  # already at "current input", down-arrow no-op
        @history_saved = @input_buffer.dup
        @history_index = hist.size  # one past last; about to decrement
      end

      new_index = @history_index + step
      if new_index < 0
        return  # already at oldest
      elsif new_index >= hist.size
        # past the newest entry → restore the user's saved in-progress input
        replace_input_buffer(@history_saved || '')
        @history_index = nil
        @history_saved = nil
      else
        @history_index = new_index
        replace_input_buffer(hist[@history_index] || '')
      end
    end

    # Erase the currently-displayed input line and replace it with
    # `new_line`. After the call the screen cursor is at the end of
    # new_line. Used by history navigation, which always wants the
    # cursor at the end after a swap.
    def replace_input_buffer(new_line)
      replace_input_line(new_line, new_line.length)
    end

    # Lower-level variant: replace the input line with `new_line` and
    # position the cursor at `new_cursor` within it. Handles the
    # erase-old / draw-new / position-cursor dance with the parser.
    def replace_input_line(new_line, new_cursor)
      tail_len = @input_buffer.length - @input_cursor
      process_output("\e[#{tail_len}C") if tail_len > 0
      process_output("\b \b" * @input_buffer.length)
      @input_buffer = +new_line
      @input_cursor = new_cursor
      process_output(new_line)
      back = new_line.length - new_cursor
      process_output("\e[#{back}D") if back > 0
    end

    # ---- Mid-line editing primitives. All operate on @input_buffer
    # and @input_cursor and emit just enough on the screen to keep the
    # cell-grid view in sync.

    def insert_at_cursor(chars)
      @input_buffer.insert(@input_cursor, chars)
      tail = @input_buffer[(@input_cursor + chars.length)..] || ''
      @input_cursor += chars.length
      # Echo the new chars + the tail that shifted right; then move
      # the cursor back to its logical position.
      process_output(chars + tail)
      process_output("\e[#{tail.length}D") unless tail.empty?
    end

    def delete_before_cursor
      return if @input_cursor == 0
      @input_buffer.slice!(@input_cursor - 1)
      @input_cursor -= 1
      tail = @input_buffer[@input_cursor..] || ''
      # \b moves left over the doomed cell; rewrite tail; pad with
      # space to clobber the leftover char at the end; move back.
      process_output("\b" + tail + ' ')
      process_output("\e[#{tail.length + 1}D")
    end

    def delete_at_cursor
      return if @input_cursor >= @input_buffer.length
      @input_buffer.slice!(@input_cursor)
      tail = @input_buffer[@input_cursor..] || ''
      process_output(tail + ' ')
      process_output("\e[#{tail.length + 1}D")
    end

    def cursor_left
      return if @input_cursor == 0
      @input_cursor -= 1
      process_output("\e[D")
    end

    def cursor_right
      return if @input_cursor >= @input_buffer.length
      @input_cursor += 1
      process_output("\e[C")
    end

    def cursor_home
      return if @input_cursor == 0
      process_output("\e[#{@input_cursor}D")
      @input_cursor = 0
    end

    def cursor_end
      n = @input_buffer.length - @input_cursor
      return if n == 0
      process_output("\e[#{n}C")
      @input_cursor = @input_buffer.length
    end

    # Translate a macOS NSEvent character (which uses U+F70x for
    # special keys) to the ANSI escape sequence a unix program reading
    # from a pty would expect. Plain printable input passes through;
    # Ctrl+letter gets masked to its control byte (so Ctrl-C → ETX).
    SPECIAL_KEY_TO_ANSI = {
      "\u{F700}" => "\e[A",  # Up
      "\u{F701}" => "\e[B",  # Down
      "\u{F703}" => "\e[C",  # Right
      "\u{F702}" => "\e[D",  # Left
      "\u{F728}" => "\e[3~", # Delete (forward)
      "\u{F729}" => "\e[H",  # Home
      "\u{F72B}" => "\e[F",  # End
      "\u{F72C}" => "\e[5~", # PageUp
      "\u{F72D}" => "\e[6~", # PageDown
    }.freeze

    NSEVENT_CONTROL_FLAG = 0x40000

    def translate_for_pty(chars, flags)
      mapped = SPECIAL_KEY_TO_ANSI[chars]
      return mapped if mapped
      if (flags & NSEVENT_CONTROL_FLAG) != 0 && chars.length == 1 && chars.ord >= 0x20
        return (chars.ord & 0x1F).chr
      end
      chars
    end

    # Tab completion. If exactly one candidate matches the word at
    # cursor, splice it in and add a trailing space (or `/` for dirs).
    # Multiple candidates → print them inline below the prompt and
    # redraw the input. Zero → no-op (silent).
    WORD_BREAK_CHARS = " \t\n\"'><=;|&{("

    def complete_input
      point = @input_cursor
      candidates = @embedded_shell.complete_at(line: @input_buffer, point: point)
      return if candidates.empty?

      if candidates.size == 1
        word_start = point
        word_start -= 1 while word_start > 0 && !WORD_BREAK_CHARS.include?(@input_buffer[word_start - 1])
        completion = candidates.first
        completion = "#{completion} " unless completion.end_with?('/')
        tail = @input_buffer[point..] || ''
        new_input = @input_buffer[0...word_start] + completion + tail
        new_cursor = word_start + completion.length
        replace_input_line(new_input, new_cursor)
      else
        process_output("\r\n")
        per_row = 4
        candidates.each_with_index do |c, i|
          process_output(c.ljust(20))
          process_output("\r\n") if i % per_row == per_row - 1
        end
        process_output("\r\n") unless candidates.size % per_row == 0
        process_output(@embedded_shell.prompt.to_s)
        process_output(@input_buffer)
        # Cursor on screen is at end after the redraw; sync state.
        @input_cursor = @input_buffer.length
      end
    end
  end
end
