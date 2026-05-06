# frozen_string_literal: true

require 'reline'

module Echoes
  # Read-only file viewer that wraps `Rvim::Editor` for vim-style
  # navigation (hjkl, gg/G, w/b/e, 0/$, Ctrl-D/Ctrl-U/Ctrl-B/Ctrl-F,
  # /search, n/N, …) of arbitrary files. The visible window's lines
  # are exposed as styled-segment hashes (same shape as the prompt
  # ones) so the host can render them via `Screen#put_styled_segments`
  # — no ANSI roundtrip.
  #
  # Phase 1: read-only; no `:w`, no `:q` (host closes the pane). No
  # split layouts. Future phases can expose more of rvim's surface.
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
    # one Array per visible row. Slices the buffer to the current
    # scroll position and pads with empty rows so the viewer fills
    # the pane.
    def visible_segments
      win = @editor.current_window
      lines = @editor.current_buffer&.lines || []
      top = win&.scroll_top || 0
      slice = lines[top, @rows] || []
      out = slice.map { |line| line_to_segments(line) }
      while out.size < @rows
        out << [DEFAULT_SEGMENT.merge(text: '')]
      end
      out
    end

    # (row, col) of the cursor within the viewport.
    def cursor_position
      win = @editor.current_window
      top = win&.scroll_top || 0
      row = (@editor.line_index || 0) - top
      col = @editor.byte_pointer || 0
      [row.clamp(0, @rows - 1), col.clamp(0, @cols - 1)]
    end

    private

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
