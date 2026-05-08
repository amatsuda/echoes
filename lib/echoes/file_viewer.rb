# frozen_string_literal: true

require 'reline'

module Echoes
  # Vim-equivalent editor pane backed by `Rvim::Editor`. Editing,
  # `:w` (write), `:q` (quit), search, visual mode, undo/redo and
  # the rest of rvim's surface all work — this class is the
  # rendering shim that turns rvim's editor state into the styled
  # segments echoes' Screen wants. The bottom row is reserved for
  # the statusline (mode / filename / modified marker / line:col)
  # or, when in command/search mode, for the cmdline (`:`, `/`,
  # or `?` prompt with the typed text and cursor).
  class FileViewer
    # rvim's syntax highlighter labels each token with a vim-style
    # color symbol (`:Comment`, `:String`, …). Map to ANSI palette
    # indices that this Screen's Cell.fg uses.
    COLOR_MAP = {
      Comment:    8,    # bright black / grey
      String:     2,    # green
      Keyword:    5,    # magenta
      Symbol:     3,    # yellow
      Number:     3,    # yellow
      Constant:   6,    # cyan
      Function:   4,    # blue
      Type:       6,    # cyan
      Special:    3,    # yellow
      PreProc:    5,    # magenta
      Operator:  14,    # bright cyan
      Identifier: 7,    # white
    }.freeze

    DEFAULT_SEGMENT = {
      fg: nil, bg: nil,
      bold: false, italic: false, underline: false, inverse: false,
    }.freeze

    attr_reader :file

    def initialize(file:, rows:, cols:)
      require 'rvim'
      @editor = Rvim::Editor.new(Reline.core.config)
      @rows = rows
      @cols = cols
      @file = file
      resize(rows: rows, cols: cols)
      @editor.open(file) if file && File.exist?(file)
      @lang = @file ? Rvim::Syntax.detect_language(@file) : nil
    end

    # Match rvim's window dimensions to the host pane's. Called on
    # construction and on later `Pane#resize`.
    def resize(rows:, cols:)
      @rows = rows
      @cols = cols
      win = @editor.current_window
      return unless win
      win.height = rows
      win.width  = cols
    end

    # Forward a single character (or escape sequence) to the editor.
    # Accepts Strings like 'j', 'G', "\x04" (Ctrl-D), or "\e[A". Maps
    # macOS NSEvent special-key codepoints to vim equivalents so the
    # arrow keys "just work" in viewer mode.
    SPECIAL_KEY_MAP = {
      "\u{F700}" => 'k',  # Up
      "\u{F701}" => 'j',  # Down
      "\u{F702}" => 'h',  # Left
      "\u{F703}" => 'l',  # Right
      "\u{F72C}" => "\x02",  # PageUp → Ctrl-B
      "\u{F72D}" => "\x06",  # PageDown → Ctrl-F
      "\u{F729}" => 'g',  # Home (caller may follow with another 'g')
      "\u{F72B}" => 'G',  # End
    }.freeze

    def feed_key(ch)
      mapped = SPECIAL_KEY_MAP[ch] || ch
      mapped.each_char { |c| @editor.send(:dispatch_synthesized_key, c) }
      true
    rescue
      false
    end

    # Visible window's lines as Arrays of styled-segment Hashes
    # (`{text:, fg:, bg:, bold:, italic:, underline:, inverse:}`),
    # one Array per visible row. The last row is the statusline (or
    # cmdline, in `:`/`/`/`?` modes); the rows above are buffer text
    # padded with vim-style `~` markers when shorter than the pane.
    def visible_segments
      win = @editor.current_window
      lines = @editor.current_buffer&.lines || []
      top = win&.scroll_top || 0
      body_rows = [@rows - 1, 1].max  # reserve last row for status/cmdline
      slice = lines[top, body_rows] || []
      out = slice.map { |line| line_to_segments(line) }
      while out.size < body_rows
        out << [DEFAULT_SEGMENT.merge(text: '~', fg: 4)]
      end
      out << bottom_row_segments
      out
    end

    # (row, col) of the cursor within the viewport. In cmdline modes
    # (:ex / :search_*) the cursor sits on the bottom row at the end
    # of the cmdline text; otherwise it tracks the editor cursor in
    # the buffer body.
    def cursor_position
      if cmdline_mode?
        text = cmdline_text
        [@rows - 1, text.length.clamp(0, @cols - 1)]
      else
        win = @editor.current_window
        top = win&.scroll_top || 0
        row = (@editor.line_index || 0) - top
        col = @editor.byte_pointer || 0
        body_max = [@rows - 2, 0].max
        [row.clamp(0, body_max), col.clamp(0, @cols - 1)]
      end
    end

    # rvim sets `quit` after `:q` / `:q!` / `:wq`. The host polls this
    # via `Pane#alive?` and reaps the pane like it would a dead shell.
    def closed?
      @editor.quit?
    end

    # Short label for the current vim mode (used in the statusline
    # and exposed for window-title / future status-bar plumbing).
    def mode_label
      return :cmdline if cmdline_mode?
      return :visual  if @editor.visual_mode
      return :insert  if @editor.send(:editing_mode_label) == :vi_insert
      :normal
    end

    # Filename for the window title; appends `[+]` while the buffer
    # has unsaved changes (vim convention). Returns `'[No Name]'` for
    # buffers opened with no path (e.g. `:enew`).
    def display_filename
      base = @file && !@file.empty? ? File.basename(@file) : '[No Name]'
      @editor.modified ? "#{base} [+]" : base
    end

    private

    def cmdline_mode?
      [:ex, :search_forward, :search_backward].include?(@editor.prompt_mode)
    end

    # The text the user sees on the bottom row when in cmdline mode:
    # the leader char (`:`, `/`, `?`) followed by what they've typed.
    def cmdline_text
      leader =
        case @editor.prompt_mode
        when :search_forward  then '/'
        when :search_backward then '?'
        else                       ':'
        end
      "#{leader}#{@editor.prompt_buffer}"
    end

    # One row of segments for the bottom of the pane. Either the
    # cmdline (in :ex/search mode) or the inverse-video statusline.
    def bottom_row_segments
      if cmdline_mode?
        text = cmdline_text
        [DEFAULT_SEGMENT.merge(text: text.byteslice(0, @cols).to_s)]
      else
        statusline_segments
      end
    end

    # Inverse-video statusline: "MODE  filename [+]   <padding>   line:col".
    # `status_message` (if rvim has one — e.g. ':"…" written') wins
    # over the mode label so saves and errors are visible.
    def statusline_segments
      status = @editor.status_message
      left =
        if status && !status.empty?
          status.to_s
        else
          mode = mode_label_text
          fname = display_filename
          mode.empty? ? fname : "#{mode}  #{fname}"
        end
      lineno = (@editor.line_index || 0) + 1
      col    = (@editor.byte_pointer || 0) + 1
      right  = "#{lineno}:#{col}"

      max = @cols
      pad = max - left.length - right.length
      pad = 1 if pad < 1
      text = "#{left}#{' ' * pad}#{right}"
      text = text.byteslice(0, max).to_s

      [DEFAULT_SEGMENT.merge(text: text, inverse: true)]
    end

    def mode_label_text
      case mode_label
      when :insert then '-- INSERT --'
      when :visual then '-- VISUAL --'
      else              ''
      end
    end

    def line_to_segments(line)
      return [DEFAULT_SEGMENT.merge(text: '')] if line.nil? || line.empty?
      spans = (@lang ? Rvim::Syntax.highlight(line, @lang) : []).sort_by { |s, _e, _c| s }
      result = []
      pos = 0
      spans.each do |start, last, color_sym|
        if start > pos
          result << DEFAULT_SEGMENT.merge(text: line.byteslice(pos, start - pos).to_s)
        end
        text = line.byteslice(start, last - start + 1).to_s
        result << DEFAULT_SEGMENT.merge(text: text, fg: COLOR_MAP[color_sym])
        pos = last + 1
      end
      result << DEFAULT_SEGMENT.merge(text: line.byteslice(pos..).to_s) if pos < line.bytesize
      result.empty? ? [DEFAULT_SEGMENT.merge(text: line)] : result
    end
  end
end
