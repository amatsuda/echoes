# frozen_string_literal: true

require 'pty'

module Echoes
  # A Pane is one shell session within a Tab. It owns a Screen (the cell
  # grid the user sees) and a backing shell — either an external program
  # spawned via PTY (the default), or a Rubish::REPL running in a per-pane
  # helper subprocess via Echoes::EmbeddedShell. The helper owns the pty
  # as its controlling tty so Ctrl-C / SIGWINCH / job control all work.
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
        @continuation_lines = []  # collected lines while waiting for a complete command
        @kill_ring = +''      # last killed text (for Ctrl-Y yank)
        @autosuggestion = +''  # fish-style: tail of the most recent matching history entry
        @input_mode = :prompt  # :prompt | :search (running uses @embedded_shell.running?)
        @search_query = +''    # Ctrl-R substring being typed
        @search_index = nil    # index into history of the current match (nil = no match)
        @search_saved_buffer = nil
        @search_saved_cursor = nil
        @search_saved_autosuggestion = nil
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
    # command has finished — we drain its trailing output, emit OSC 133
    # ;D (command end), then ;A + prompt + ;B for the next command, and
    # re-enable the in-pane line editor.
    def read_available_output(max = 16384)
      if embedded?
        out = @embedded_shell.read_available_output
        if @embedded_running && @embedded_shell.reap_if_done
          out << @embedded_shell.read_available_output
          out << osc133_d(@embedded_shell.last_status)
          out << osc133_a
          out << @embedded_shell.prompt.to_s
          out << osc133_b
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
      if embedded?
        @embedded_shell.shutdown
        return
      end
      @pty_write.close rescue nil
      @pty_read.close rescue nil
      Process.kill(:HUP, @pty_pid) rescue nil
    end

    def process_output(data)
      @parser.feed(data)
    end

    # Text of the most recently completed command's output, extracted
    # from the OSC 133 ;C..;D region. Returns nil when no command has
    # finished yet on this pane. Useful for "copy last command output"
    # workflows and for piping output to external tools.
    def last_command_output_text
      mark = @screen.last_completed_command_mark
      return nil unless mark
      text = @screen.text_for_command_output(mark)
      text.empty? ? nil : text
    end

    # Convenience: copy `last_command_output_text` to the system
    # clipboard via the screen's clipboard handler. Returns true on
    # success, false if there's nothing to copy or no clipboard
    # handler is wired (e.g., in tests).
    def copy_last_command_output
      text = last_command_output_text
      return false unless text
      @screen.set_clipboard(text)
      true
    end

    # Most recently submitted command's text (the literal line the user
    # ran). Reads rubish's Reline::HISTORY directly, which is more
    # reliable than scraping the cell grid (no wrapping / column-offset
    # ambiguity from the prompt). Returns nil if no command has been
    # submitted yet.
    def last_command_text
      return nil unless embedded?
      hist = @embedded_shell.history
      hist.last
    end

    def copy_last_command_text
      text = last_command_text
      return false unless text && !text.empty?
      @screen.set_clipboard(text)
      true
    end

    # Jump scroll position to the previous or next OSC 133 prompt
    # boundary recorded on @screen. Returns true if a jump happened,
    # false if there was no target in that direction. The Screen's
    # `command_marks` are populated by the parser whenever the running
    # shell emits OSC 133 (the embedded shell does this automatically;
    # PTY-mode shells like zsh/fish emit them too when configured).
    def jump_to_prompt(direction:)
      marks = @screen.command_marks.select { |m| m[:prompt_start] }
      return false if marks.empty?

      scrollback_size = @screen.scrollback.size
      current_top = scrollback_size - @scroll_offset

      target =
        case direction
        when :prev then marks.reverse.find { |m| m[:prompt_start] < current_top }
        when :next then marks.find       { |m| m[:prompt_start] > current_top }
        end
      return false unless target

      row = target[:prompt_start]
      if row >= scrollback_size
        # Target is in the live grid — scroll to bottom.
        @scroll_offset = 0
      else
        @scroll_offset = (scrollback_size - row).clamp(0, scrollback_size)
      end
      true
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

      return handle_search_key(chars, flags) if @input_mode == :search

      # Emacs/readline-style bindings on Ctrl+letter at the prompt.
      # macOS gives us `chars` as the plain letter (Cocoa's
      # charactersIgnoringModifiers); flags carries the Control bit.
      if (flags & NSEVENT_CONTROL_FLAG) != 0 && chars.length == 1 && chars.ord >= 0x20
        return true if handle_ctrl_letter(chars.downcase)
      end

      option_held = (flags & NSEVENT_OPTION_FLAG) != 0
      cmd_held    = (flags & NSEVENT_COMMAND_FLAG) != 0
      shift_held  = (flags & NSEVENT_SHIFT_FLAG) != 0

      # Cmd+Shift+letter: pane-level shortcuts that operate on OSC 133
      # marks. Cmd+Shift+Up/Down (jump-to-prompt) is matched in the
      # arrow-key cases below.
      if cmd_held && shift_held && chars.length == 1
        case chars.downcase
        when 'o'
          copy_last_command_output
          return true
        when 'l'
          copy_last_command_text
          return true
        end
      end

      case chars
      when "\r", "\n"
        submit_or_continue
      when "\u{7F}", "\b"
        option_held ? kill_word_left : delete_before_cursor
      when "\u{F728}"  # NSDeleteFunctionKey (forward delete)
        option_held ? kill_word_right : delete_at_cursor
      when "\u{F702}"  # NSLeftArrowFunctionKey
        option_held ? word_left : cursor_left
      when "\u{F703}"  # NSRightArrowFunctionKey
        if option_held
          word_right
        elsif at_end_with_suggestion?
          accept_full_autosuggestion
        else
          cursor_right
        end
      when "\u{F729}"  # NSHomeFunctionKey
        cursor_home
      when "\u{F72B}"  # NSEndFunctionKey
        if at_end_with_suggestion?
          accept_full_autosuggestion
        else
          cursor_end
        end
      when "\u{F700}"  # NSUpArrowFunctionKey
        if cmd_held && shift_held
          jump_to_prompt(direction: :prev)
        else
          history_step(-1)
        end
      when "\u{F701}"  # NSDownArrowFunctionKey
        if cmd_held && shift_held
          jump_to_prompt(direction: :next)
        else
          history_step(1)
        end
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
      process_output(osc133_a)
      process_output(@embedded_shell.prompt.to_s)
      process_output(osc133_b)
    end

    # OSC 133 escape strings. Hosts surrounding shells in their own
    # render layer (us) emit these to mark prompt/input/output regions.
    # The terminal parser routes them to Screen#osc133_mark.
    def osc133_a; "\e]133;A\e\\"; end
    def osc133_b; "\e]133;B\e\\"; end
    def osc133_c; "\e]133;C\e\\"; end
    def osc133_d(code = nil)
      code.nil? ? "\e]133;D\e\\" : "\e]133;D;#{code}\e\\"
    end

    # Enter pressed at the prompt. Decide whether the accumulated
    # input forms a complete command — if so, submit it; if not,
    # keep collecting continuation lines under PS2.
    def submit_or_continue
      this_line = @input_buffer
      candidate = (@continuation_lines + [this_line]).join("\n")

      case @embedded_shell.try_parse(candidate)
      when :incomplete
        # Accumulate and prompt for more.
        @continuation_lines << this_line
        @input_buffer = +''
        @input_cursor = 0
        @autosuggestion = +''
        process_output("\r\n")
        process_output(@embedded_shell.continuation_prompt)
      else
        # :ok or :error — let rubish run it; rubish reports syntax
        # errors itself. Either way, this line completes the input.
        line = candidate
        @input_buffer = +''
        @input_cursor = 0
        @continuation_lines = []
        @history_index = nil
        @history_saved = nil
        @autosuggestion = +''
        process_output("\r\n")
        process_output(osc133_c)
        @embedded_shell.submit_line(line, rows: @screen.rows, cols: @screen.cols)
        @embedded_running = true
      end
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
    # The drawn content is colorized via `colorize_input`; SGR escapes
    # don't advance the cell cursor, so the count-based math here still
    # holds. After redrawing the input, the dim autosuggestion (if any)
    # is appended and the cursor is moved back to the logical position.
    def replace_input_line(new_line, new_cursor)
      prev_visible = @input_buffer.length + @autosuggestion.length
      tail_len = prev_visible - @input_cursor
      process_output("\e[#{tail_len}C") if tail_len > 0
      process_output("\b \b" * prev_visible)
      @input_buffer = +new_line
      @input_cursor = new_cursor
      @autosuggestion = compute_autosuggestion
      process_output(colorize_input(new_line))
      process_output("\e[2m" + @autosuggestion + "\e[0m") unless @autosuggestion.empty?
      back = new_line.length + @autosuggestion.length - new_cursor
      process_output("\e[#{back}D") if back > 0
    end

    # ---- Mid-line editing primitives. All operate on @input_buffer
    # and @input_cursor and emit just enough on the screen to keep the
    # cell-grid view in sync.

    def insert_at_cursor(chars)
      new_line = @input_buffer.dup.insert(@input_cursor, chars)
      replace_input_line(new_line, @input_cursor + chars.length)
    end

    def delete_before_cursor
      return if @input_cursor == 0
      new_line = @input_buffer.dup.tap { |s| s.slice!(@input_cursor - 1) }
      replace_input_line(new_line, @input_cursor - 1)
    end

    def delete_at_cursor
      return if @input_cursor >= @input_buffer.length
      new_line = @input_buffer.dup.tap { |s| s.slice!(@input_cursor) }
      replace_input_line(new_line, @input_cursor)
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

    # Emacs/readline keybindings handled at the prompt. Returns true
    # if we consumed the keystroke. The PTY-mode pane still uses the
    # GUI's existing Ctrl-letter -> control byte path; this only fires
    # in embedded prompt mode.
    def handle_ctrl_letter(letter)
      case letter
      when 'a' then cursor_home;          true
      when 'e'
        # Ctrl-E: jump to end. If already at end and a suggestion is
        # showing, accept it (fish-style).
        if at_end_with_suggestion?
          accept_full_autosuggestion
        else
          cursor_end
        end
        true
      when 'b' then cursor_left;          true
      when 'f'
        # Ctrl-F: forward one char. At end-of-input with a suggestion,
        # accept just one word of it (fish's accept-autosuggestion-word).
        if at_end_with_suggestion?
          accept_word_of_autosuggestion
        else
          cursor_right
        end
        true
      when 'h' then delete_before_cursor; true   # ASCII 0x08 (BS)
      when 'i' then complete_input;       true   # ASCII 0x09 (Tab)
      when 'j' then submit_or_continue;   true   # ASCII 0x0A (LF / Enter)
      when 'm' then submit_or_continue;   true   # ASCII 0x0D (CR / Enter)
      when 'p' then history_step(-1);     true   # readline alias for ↑
      when 'n' then history_step(1);      true   # readline alias for ↓
      when 't' then transpose_chars;      true
      when 'y' then yank_kill_ring;       true
      when 'd'
        # Bash convention: Ctrl-D on an empty line is "EOF / exit"; on
        # a non-empty line it's forward-delete. We don't have an exit
        # path yet for the embedded REPL — for now just no-op when
        # empty.
        delete_at_cursor unless @input_buffer.empty?
        true
      when 'k' then kill_to_end;          true
      when 'u' then kill_to_start;        true
      when 'w' then kill_word_left;       true
      when 'l' then redraw_screen;        true
      when 'r' then enter_search;         true
      when 'c'
        # Ctrl-C at the prompt: discard the in-progress line, drop
        # the user on a fresh prompt below. Like bash.
        process_output("^C\r\n")
        @input_buffer = +''
        @input_cursor = 0
        @history_index = nil
        @history_saved = nil
        @autosuggestion = +''
        process_output(osc133_a)
        process_output(@embedded_shell.prompt.to_s)
        process_output(osc133_b)
        true
      else
        false
      end
    end

    def kill_to_end
      return if @input_cursor >= @input_buffer.length
      @kill_ring = @input_buffer[@input_cursor..]
      new_line = @input_buffer[0, @input_cursor]
      replace_input_line(new_line, @input_cursor)
    end

    def kill_to_start
      return if @input_cursor == 0
      @kill_ring = @input_buffer[0, @input_cursor]
      new_line = @input_buffer[@input_cursor..] || ''
      replace_input_line(new_line, 0)
    end

    def kill_word_left
      return if @input_cursor == 0
      i = @input_cursor
      i -= 1 while i > 0 && @input_buffer[i - 1] == ' '
      i -= 1 while i > 0 && @input_buffer[i - 1] != ' '
      removed = @input_cursor - i
      return if removed == 0
      @kill_ring = @input_buffer[i, removed]
      new_line = @input_buffer.dup.tap { |s| s.slice!(i, removed) }
      replace_input_line(new_line, i)
    end

    # Mirror of kill_word_left: skip whitespace forward, then a word, kill
    # that span. Bound to Option+forward-Delete; matches macOS muscle memory.
    def kill_word_right
      return if @input_cursor >= @input_buffer.length
      j = @input_cursor
      j += 1 while j < @input_buffer.length && @input_buffer[j] == ' '
      j += 1 while j < @input_buffer.length && @input_buffer[j] != ' '
      removed = j - @input_cursor
      return if removed == 0
      @kill_ring = @input_buffer[@input_cursor, removed]
      new_line = @input_buffer.dup.tap { |s| s.slice!(@input_cursor, removed) }
      replace_input_line(new_line, @input_cursor)
    end

    # Re-insert the most recently killed text at the cursor.
    def yank_kill_ring
      return if @kill_ring.empty?
      insert_at_cursor(@kill_ring)
    end

    # Swap the char before the cursor with the char at the cursor and
    # advance one position. At end-of-line, swaps the last two chars
    # (readline behavior). At start-of-line, no-op.
    def transpose_chars
      return if @input_buffer.length < 2 || @input_cursor == 0
      new_line = @input_buffer.dup
      if @input_cursor == @input_buffer.length
        new_line[-2], new_line[-1] = new_line[-1], new_line[-2]
        replace_input_line(new_line, @input_cursor)
      else
        new_line[@input_cursor - 1], new_line[@input_cursor] =
          new_line[@input_cursor], new_line[@input_cursor - 1]
        replace_input_line(new_line, @input_cursor + 1)
      end
    end

    def redraw_screen
      process_output("\e[2J\e[H")
      process_output(@embedded_shell.prompt.to_s)
      process_output(colorize_input(@input_buffer))
      process_output("\e[2m" + @autosuggestion + "\e[0m") unless @autosuggestion.empty?
      back = @input_buffer.length + @autosuggestion.length - @input_cursor
      process_output("\e[#{back}D") if back > 0
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
    NSEVENT_OPTION_FLAG  = 0x80000
    NSEVENT_SHIFT_FLAG   = 0x20000
    NSEVENT_COMMAND_FLAG = 0x100000

    def word_left
      return if @input_cursor == 0
      i = @input_cursor
      i -= 1 while i > 0 && @input_buffer[i - 1] == ' '
      i -= 1 while i > 0 && @input_buffer[i - 1] != ' '
      steps = @input_cursor - i
      return if steps == 0
      process_output("\e[#{steps}D")
      @input_cursor = i
    end

    def word_right
      return if @input_cursor >= @input_buffer.length
      i = @input_cursor
      i += 1 while i < @input_buffer.length && @input_buffer[i] != ' '
      i += 1 while i < @input_buffer.length && @input_buffer[i] == ' '
      steps = i - @input_cursor
      return if steps == 0
      process_output("\e[#{steps}C")
      @input_cursor = i
    end

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
        process_output(colorize_input(@input_buffer))
        # Cursor on screen is at end after the redraw; sync state.
        @input_cursor = @input_buffer.length
        @autosuggestion = compute_autosuggestion
        unless @autosuggestion.empty?
          process_output("\e[2m" + @autosuggestion + "\e[0m")
          process_output("\e[#{@autosuggestion.length}D")
        end
      end
    end

    # Map of token type → SGR escape. Keywords get bold yellow; the
    # control-flow operators get bright cyan; redirections get bright
    # magenta. Word tokens are handled separately below — quoted ones
    # render green, the first word at command position renders bold.
    TOKEN_COLOR_MAP = {
      IF: "\e[1;33m", THEN: "\e[1;33m", ELSE: "\e[1;33m", ELIF: "\e[1;33m",
      ELSIF: "\e[1;33m", FI: "\e[1;33m", UNLESS: "\e[1;33m", WHILE: "\e[1;33m",
      UNTIL: "\e[1;33m", FOR: "\e[1;33m", SELECT: "\e[1;33m", CASE: "\e[1;33m",
      WHEN: "\e[1;33m", ESAC: "\e[1;33m", FUNCTION: "\e[1;33m", DEF: "\e[1;33m",
      COPROC: "\e[1;33m", TIME: "\e[1;33m", LAZY_LOAD: "\e[1;33m",
      PIPE: "\e[96m", PIPE_BOTH: "\e[96m", SEMICOLON: "\e[96m",
      DOUBLE_SEMI: "\e[96m", AND: "\e[96m", OR: "\e[96m", AMPERSAND: "\e[96m",
      REDIRECT_OUT: "\e[95m", REDIRECT_APPEND: "\e[95m", REDIRECT_IN: "\e[95m",
      REDIRECT_ERR: "\e[95m", REDIRECT_CLOBBER: "\e[95m", DUP_OUT: "\e[95m",
      DUP_IN: "\e[95m", HEREDOC: "\e[95m", HEREDOC_INDENT: "\e[95m",
      HERESTRING: "\e[95m",
    }.freeze

    # Token types that put the *next* WORD into "command position" — i.e.
    # this is where the user types a program name, which we render bold.
    COMMAND_BOUNDARY_TYPES = %i[
      SEMICOLON PIPE PIPE_BOTH AND OR AMPERSAND
      IF THEN ELSE ELIF ELSIF WHILE UNTIL FOR SELECT CASE WHEN
      DOUBLE_SEMI CASE_FALL CASE_CONT LBRACE LPAREN
    ].freeze

    # Take the user's in-progress input line and return a copy with
    # ANSI SGR escapes wrapped around each token. SGRs don't advance
    # the cell-grid cursor, so the surrounding cell-count math in
    # `replace_input_line` is unchanged. Falls back to the plain line
    # on any failure — highlighting must never lose user input.
    def colorize_input(line)
      return line if line.empty?
      tokens = @embedded_shell.tokenize(line)
      return line if tokens.empty?

      out = +''
      pos = 0
      command_position = true
      tokens.each do |tok|
        val = tok.value.to_s
        next if val.empty?
        idx = line.index(val, pos)
        break unless idx
        # Whitespace skipped by the lexer copies through verbatim.
        out << line[pos...idx] if idx > pos

        sgr = sgr_for_token(tok, command_position)
        if sgr
          out << sgr << val << "\e[0m"
        else
          out << val
        end
        pos = idx + val.length

        if tok.type == :WORD
          command_position = false
        elsif COMMAND_BOUNDARY_TYPES.include?(tok.type)
          command_position = true
        end
      end
      out << line[pos..] if pos < line.length
      out
    rescue
      line
    end

    # Find the most recent history entry that has @input_buffer as a
    # strict prefix; the suffix is what we render as a dim ghost-text
    # autosuggestion. Empty input → no suggestion. Empty during
    # multi-line continuation: history stores commands as one entry
    # each, so a partial second-line buffer wouldn't match meaningfully.
    def compute_autosuggestion
      return '' if @input_buffer.empty?
      return '' unless @continuation_lines.empty?
      hist = @embedded_shell.history
      return '' if hist.empty?
      hist.reverse_each do |entry|
        # Multi-line history entries (saved from continuation submissions
        # as one big string with embedded "\n") can't render as inline
        # ghost text — skip them.
        next if entry.include?("\n")
        if entry.start_with?(@input_buffer) && entry.length > @input_buffer.length
          return entry[@input_buffer.length..]
        end
      end
      ''
    rescue
      ''
    end

    def at_end_with_suggestion?
      @input_cursor >= @input_buffer.length && !@autosuggestion.empty?
    end

    # Accept the entire pending suggestion: splice it in at the cursor.
    # `insert_at_cursor` routes through `replace_input_line`, which
    # recomputes the now-empty suggestion against the new buffer.
    def accept_full_autosuggestion
      return if @autosuggestion.empty?
      insert_at_cursor(@autosuggestion)
    end

    # Accept just the next word (run of whitespace + run of non-whitespace)
    # from the pending suggestion. Mirrors fish's accept-autosuggestion-word.
    def accept_word_of_autosuggestion
      return if @autosuggestion.empty?
      s = @autosuggestion
      i = 0
      i += 1 while i < s.length && s[i] == ' '
      i += 1 while i < s.length && s[i] != ' '
      insert_at_cursor(s[0, i])
    end

    # ---- Ctrl-R reverse-incremental history search.
    #
    # While in :search mode, the current line on screen is replaced with
    #   (reverse-i-search)`query': matched-history-line
    # Typed chars narrow the query; Ctrl-R jumps to the next older match;
    # Enter accepts the match and submits it; Esc / Ctrl-G cancels and
    # restores the original input. Other keys (arrows, etc.) cancel the
    # search and re-process the keystroke in :prompt mode — so e.g. ↑
    # exits search and walks the regular history.

    def enter_search
      @input_mode = :search
      @search_query = +''
      @search_index = nil
      @search_saved_buffer = @input_buffer.dup
      @search_saved_cursor = @input_cursor
      @search_saved_autosuggestion = @autosuggestion.dup
      render_search
    end

    def handle_search_key(chars, flags)
      ctrl = (flags & NSEVENT_CONTROL_FLAG) != 0
      if ctrl && chars.length == 1 && chars.ord >= 0x20
        case chars.downcase
        when 'r' then search_step_back; return true
        when 'g' then exit_search(:cancel); return true
        when 'h' then search_backspace;   return true
        end
      end

      case chars
      when "\e"
        exit_search(:cancel)
      when "\r", "\n"
        exit_search(:accept_and_submit)
      when "\u{7F}", "\b"
        search_backspace
      else
        ord = chars.length == 1 ? chars.ord : nil
        # Accept printable input: ASCII printable plus normal Unicode.
        # Exclude the macOS NSEvent special-key range (U+F700–F7FF) —
        # those are arrows / Home / End / Delete and should fall through
        # to the cancel-and-reprocess path so the user lands back in
        # prompt mode and the keystroke runs there.
        if !ctrl && ord && ord >= 0x20 && (ord < 0xF700 || ord > 0xF7FF)
          @search_query << chars
          restart_search_from_end
          render_search
        else
          exit_search(:cancel)
          return handle_key(chars: chars, flags: flags)
        end
      end
      true
    end

    def search_backspace
      return if @search_query.empty?
      @search_query.chop!
      restart_search_from_end
      render_search
    end

    # After the query changes, find the newest history entry that
    # contains the new query. nil index means no match.
    def restart_search_from_end
      hist = @embedded_shell.history
      @search_index = nil
      return if @search_query.empty?
      (hist.size - 1).downto(0) do |i|
        entry = hist[i]
        next if entry.nil? || entry.include?("\n")
        if entry.include?(@search_query)
          @search_index = i
          return
        end
      end
    end

    # Ctrl-R while already in search: jump to the next older match for
    # the current query. If none, leave the index alone.
    def search_step_back
      hist = @embedded_shell.history
      return if @search_query.empty?
      start_idx = (@search_index || hist.size) - 1
      start_idx.downto(0) do |i|
        entry = hist[i]
        next if entry.nil? || entry.include?("\n")
        if entry.include?(@search_query)
          @search_index = i
          render_search
          return
        end
      end
    end

    def render_search
      hist = @embedded_shell.history
      matched = (@search_index ? hist[@search_index] : nil) || ''
      display = "(reverse-i-search)`#{@search_query}': #{matched}"
      process_output("\r\e[K")
      process_output(display)
    end

    def exit_search(action)
      hist = @embedded_shell.history
      matched = @search_index ? hist[@search_index] : nil

      case action
      when :accept_and_submit
        accepted = matched || @search_saved_buffer || ''
        @input_buffer = +accepted
        @input_cursor = @input_buffer.length
        @autosuggestion = +''
        @input_mode = :prompt
        @search_query = +''
        @search_index = nil
        @search_saved_buffer = nil
        @search_saved_cursor = nil
        @search_saved_autosuggestion = nil
        process_output("\r\e[K")
        process_output(@embedded_shell.prompt.to_s)
        process_output(colorize_input(@input_buffer))
        submit_or_continue
      else  # :cancel
        @input_buffer = @search_saved_buffer || +''
        @input_cursor = @search_saved_cursor || 0
        @autosuggestion = @search_saved_autosuggestion || +''
        @input_mode = :prompt
        @search_query = +''
        @search_index = nil
        @search_saved_buffer = nil
        @search_saved_cursor = nil
        @search_saved_autosuggestion = nil
        process_output("\r\e[K")
        process_output(@embedded_shell.prompt.to_s)
        process_output(colorize_input(@input_buffer))
        process_output("\e[2m" + @autosuggestion + "\e[0m") unless @autosuggestion.empty?
        back = @input_buffer.length + @autosuggestion.length - @input_cursor
        process_output("\e[#{back}D") if back > 0
      end
    end

    def sgr_for_token(tok, command_position)
      if tok.type == :WORD
        first = tok.value.to_s[0]
        return "\e[32m" if first == '"' || first == "'"
        return "\e[1m"  if command_position
        nil
      else
        TOKEN_COLOR_MAP[tok.type]
      end
    end
  end
end
