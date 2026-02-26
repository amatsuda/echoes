# frozen_string_literal: true

module Echoes
  class Screen
    attr_reader :rows, :cols, :cursor, :grid, :scrollback, :pending_wrap
    attr_accessor :cell_pixel_width, :cell_pixel_height, :title

    def self.scrollback_limit
      Echoes.config.scrollback_limit
    end

    def initialize(rows: 24, cols: 80)
      @rows = rows
      @cols = cols
      @cursor = Cursor.new
      @attrs = Cell.new
      @grid = Array.new(rows) { Array.new(cols) { Cell.new } }
      @scroll_top = 0
      @scroll_bottom = rows - 1
      @saved_cursor = nil
      @scrollback = []
      @cell_pixel_width = 8.0
      @cell_pixel_height = 16.0
      @application_cursor_keys = false
      @bracketed_paste_mode = false
      @focus_reporting = false
      @auto_wrap = true
      @mouse_tracking = :off   # :off, :x10, :normal, :button_event, :any_event
      @mouse_encoding = :default  # :default, :sgr
      @origin_mode = false
      @insert_mode = false
      @application_keypad = false
      @cursor_style = 0  # 0=default, 1=blinking block, 2=steady block, 3=blinking underline, 4=steady underline, 5=blinking bar, 6=steady bar
      @using_alt_screen = false
      @charset_g0 = :ascii  # :ascii or :dec_special
      @charset_g1 = :ascii
      @active_charset = 0   # 0 = G0, 1 = G1
      @tab_stops = default_tab_stops
      @main_grid = nil
      @main_cursor = nil
      @main_scroll_top = nil
      @main_scroll_bottom = nil
      @main_saved_cursor = nil
      @main_scrollback = nil
      @pending_wrap = false
      @last_char = nil
    end

    DEC_SPECIAL = {
      '`' => "\u{25C6}", 'a' => "\u{2592}", 'b' => "\u{2409}", 'c' => "\u{240C}",
      'd' => "\u{240D}", 'e' => "\u{240A}", 'f' => "\u{00B0}", 'g' => "\u{00B1}",
      'h' => "\u{2424}", 'i' => "\u{240B}", 'j' => "\u{2518}", 'k' => "\u{2510}",
      'l' => "\u{250C}", 'm' => "\u{2514}", 'n' => "\u{253C}", 'o' => "\u{23BA}",
      'p' => "\u{23BB}", 'q' => "\u{2500}", 'r' => "\u{23BC}", 's' => "\u{23BD}",
      't' => "\u{251C}", 'u' => "\u{2524}", 'v' => "\u{2534}", 'w' => "\u{252C}",
      'x' => "\u{2502}", 'y' => "\u{2264}", 'z' => "\u{2265}", '{' => "\u{03C0}",
      '|' => "\u{2260}", '}' => "\u{00A3}", '~' => "\u{00B7}",
    }.freeze

    def put_char(c)
      if c.bytesize == 1
        cs = @active_charset == 0 ? @charset_g0 : @charset_g1
        if cs == :dec_special
          c = DEC_SPECIAL.fetch(c, c)
        end
      end

      w = char_width(c)

      if @auto_wrap
        # Deferred wrap: if the previous character set the flag, wrap now
        if @pending_wrap
          @pending_wrap = false
          @cursor.col = 0
          line_feed
        end

        # Wide char at last column: doesn't fit, wrap first
        if w == 2 && @cursor.col == @cols - 1
          @grid[@cursor.row][@cursor.col].reset!
          @cursor.col = 0
          line_feed
        end
      else
        # No wrap: clamp cursor to last column
        if w == 2 && @cursor.col >= @cols - 1
          @cursor.col = @cols - 2
        elsif @cursor.col >= @cols
          @cursor.col = @cols - 1
        end
      end

      erase_multicell_at(@cursor.row, @cursor.col)

      if @insert_mode
        row = @grid[@cursor.row]
        w.times { row.pop; row.insert(@cursor.col, Cell.new) }
      end

      cell = @grid[@cursor.row][@cursor.col]
      cell.copy_from(@attrs)
      cell.char = c
      cell.width = w

      if w == 2 && @cursor.col + 1 < @cols
        # Mark the next cell as a continuation (width 0)
        next_cell = @grid[@cursor.row][@cursor.col + 1]
        next_cell.reset!
        next_cell.width = 0
      end

      @cursor.col += w
      if @cursor.col >= @cols
        @cursor.col = @cols - 1
        @pending_wrap = true if @auto_wrap
      end

      @last_char = c
    end

    def repeat_char(n = 1)
      return unless @last_char

      n.times { put_char(@last_char) }
    end

    def put_multicell(text, scale:, width:, frac_n:, frac_d:, valign:, halign:)
      mc_rows = scale

      if width > 0
        # Explicit width: entire text in one block of scale*width cols × scale rows
        place_multicell_block(text, scale * width, mc_rows, scale, frac_n, frac_d, valign, halign)
      else
        # Auto width: each grapheme gets its own block
        text.each_grapheme_cluster do |grapheme|
          cw = char_width(grapheme)
          mc_cols = scale * cw
          place_multicell_block(grapheme, mc_cols, mc_rows, scale, frac_n, frac_d, valign, halign)
        end
      end
    end

    def put_sixel(data, params)
      decoder = SixelDecoder.new(params).decode(data)
      return if decoder.width == 0 || decoder.height == 0

      mc_cols = (decoder.width / @cell_pixel_width).ceil
      mc_rows = (decoder.height / @cell_pixel_height).ceil

      return if mc_cols > @cols || mc_rows > @rows

      # Wrap if it doesn't fit on current line
      if @cursor.col + mc_cols > @cols
        @cursor.col = 0
        line_feed
      end

      # Scroll if block doesn't fit vertically
      while @cursor.row + mc_rows > @rows
        scroll_up(1)
        @cursor.row = [@cursor.row - 1, 0].max
      end

      anchor_row = @cursor.row
      anchor_col = @cursor.col

      # Erase existing cells in the block area
      mc_rows.times do |dr|
        mc_cols.times do |dc|
          erase_multicell_at(anchor_row + dr, anchor_col + dc)
        end
      end

      # Set anchor cell with sixel data
      anchor = @grid[anchor_row][anchor_col]
      anchor.reset!
      anchor.char = " "
      anchor.width = 1
      anchor.multicell = {
        cols: mc_cols, rows: mc_rows, scale: 1,
        frac_n: 0, frac_d: 0, valign: 0, halign: 0,
        sixel: { width: decoder.width, height: decoder.height, rgba: decoder.to_rgba }
      }

      # Mark continuation cells
      mc_rows.times do |dr|
        mc_cols.times do |dc|
          next if dr == 0 && dc == 0
          cont = @grid[anchor_row + dr][anchor_col + dc]
          cont.reset!
          cont.multicell = :cont
        end
      end

      @cursor.col = 0
      @cursor.row = [anchor_row + mc_rows, @rows - 1].min
    end

    def move_cursor(row, col)
      @pending_wrap = false
      if @origin_mode
        @cursor.row = (row + @scroll_top).clamp(@scroll_top, @scroll_bottom)
      else
        @cursor.row = clamp_row(row)
      end
      @cursor.col = clamp_col(col)
    end

    def move_cursor_up(n = 1)
      @pending_wrap = false
      top = @cursor.row >= @scroll_top ? @scroll_top : 0
      @cursor.row = [top, @cursor.row - n].max
    end

    def move_cursor_down(n = 1)
      @pending_wrap = false
      bottom = @cursor.row <= @scroll_bottom ? @scroll_bottom : @rows - 1
      @cursor.row = [bottom, @cursor.row + n].min
    end

    def move_cursor_next_line(n = 1)
      @pending_wrap = false
      bottom = @cursor.row <= @scroll_bottom ? @scroll_bottom : @rows - 1
      @cursor.row = [bottom, @cursor.row + n].min
      @cursor.col = 0
    end

    def move_cursor_prev_line(n = 1)
      @pending_wrap = false
      top = @cursor.row >= @scroll_top ? @scroll_top : 0
      @cursor.row = [top, @cursor.row - n].max
      @cursor.col = 0
    end

    def move_cursor_forward(n = 1)
      @pending_wrap = false
      @cursor.col = [@cols - 1, @cursor.col + n].min
    end

    def move_cursor_backward(n = 1)
      @pending_wrap = false
      @cursor.col = [0, @cursor.col - n].max
    end

    def carriage_return
      @pending_wrap = false
      @cursor.col = 0
    end

    def line_feed
      @pending_wrap = false
      if @cursor.row == @scroll_bottom
        scroll_up(1)
      else
        @cursor.row = [@cursor.row + 1, @rows - 1].min
      end
    end

    def reverse_index
      @pending_wrap = false
      if @cursor.row == @scroll_top
        scroll_down(1)
      else
        @cursor.row = [0, @cursor.row - 1].max
      end
    end

    def tab
      @pending_wrap = false
      next_stop = @tab_stops.find { |s| s > @cursor.col }
      @cursor.col = next_stop ? [next_stop, @cols - 1].min : @cols - 1
    end

    def backward_tab(n = 1)
      @pending_wrap = false
      n.times do
        prev_stop = @tab_stops.reverse.find { |s| s < @cursor.col }
        @cursor.col = prev_stop || 0
      end
    end

    def set_tab_stop
      @tab_stops << @cursor.col unless @tab_stops.include?(@cursor.col)
      @tab_stops.sort!
    end

    def clear_tab_stop(mode = 0)
      case mode
      when 0
        @tab_stops.delete(@cursor.col)
      when 3
        @tab_stops.clear
      end
    end

    def backspace
      @pending_wrap = false
      @cursor.col = [0, @cursor.col - 1].max
    end

    def erase_in_display(mode = 0)
      @pending_wrap = false
      case mode
      when 0
        erase_in_line(0)
        ((@cursor.row + 1)...@rows).each { |r| clear_row(r) }
      when 1
        erase_in_line(1)
        (0...@cursor.row).each { |r| clear_row(r) }
      when 2
        (0...@rows).each { |r| clear_row(r) }
      when 3
        @scrollback.clear
      end
    end

    def erase_in_line(mode = 0)
      @pending_wrap = false
      case mode
      when 0
        (@cursor.col...@cols).each { |c| @grid[@cursor.row][c].reset! }
      when 1
        (0..@cursor.col).each { |c| @grid[@cursor.row][c].reset! }
      when 2
        clear_row(@cursor.row)
      end
    end

    def insert_lines(n = 1)
      @pending_wrap = false
      return unless @cursor.row >= @scroll_top && @cursor.row <= @scroll_bottom

      n.times do
        @grid.insert(@cursor.row, Array.new(@cols) { Cell.new })
        @grid.delete_at(@scroll_bottom + 1)
      end
    end

    def delete_lines(n = 1)
      @pending_wrap = false
      return unless @cursor.row >= @scroll_top && @cursor.row <= @scroll_bottom

      n.times do
        @grid.delete_at(@cursor.row)
        @grid.insert(@scroll_bottom, Array.new(@cols) { Cell.new })
      end
    end

    def delete_chars(n = 1)
      @pending_wrap = false
      row = @grid[@cursor.row]
      n.times do
        row.delete_at(@cursor.col)
        row.push(Cell.new)
      end
    end

    def insert_chars(n = 1)
      @pending_wrap = false
      row = @grid[@cursor.row]
      n.times do
        row.pop
        row.insert(@cursor.col, Cell.new)
      end
    end

    def erase_chars(n = 1)
      n.times do |i|
        col = @cursor.col + i
        break if col >= @cols
        @grid[@cursor.row][col].reset!
      end
    end

    def scroll_up(n = 1)
      @pending_wrap = false
      n.times do
        if @scroll_top == 0
          row = @grid[@scroll_top]
          @scrollback << row.map { |cell| c = Cell.new; c.copy_from(cell); c.width = cell.width; c.multicell = cell.multicell; c }
          @scrollback.shift if @scrollback.size > self.class.scrollback_limit
        end
        @grid.delete_at(@scroll_top)
        @grid.insert(@scroll_bottom, Array.new(@cols) { Cell.new })
      end
    end

    def scroll_down(n = 1)
      @pending_wrap = false
      n.times do
        @grid.delete_at(@scroll_bottom)
        @grid.insert(@scroll_top, Array.new(@cols) { Cell.new })
      end
    end

    def set_scroll_region(top, bottom)
      @pending_wrap = false
      @scroll_top = clamp_row(top)
      @scroll_bottom = clamp_row(bottom)
      @cursor.row = 0
      @cursor.col = 0
    end

    def set_graphics(params)
      params = [0] if params.empty?
      i = 0
      while i < params.length
        case params[i]
        when 0
          @attrs.reset!
        when 1
          @attrs.bold = true
        when 2
          @attrs.faint = true
        when 3
          @attrs.italic = true
        when 4
          @attrs.underline = true
        when 7
          @attrs.inverse = true
        when 5, 6
          @attrs.blink = true
        when 8
          @attrs.concealed = true
        when 9
          @attrs.strikethrough = true
        when 22
          @attrs.bold = false
          @attrs.faint = false
        when 23
          @attrs.italic = false
        when 24
          @attrs.underline = false
        when 27
          @attrs.inverse = false
        when 25
          @attrs.blink = false
        when 28
          @attrs.concealed = false
        when 29
          @attrs.strikethrough = false
        when 30..37
          @attrs.fg = params[i] - 30
        when 38
          if params[i + 1] == 2 && params[i + 2] && params[i + 3] && params[i + 4]
            @attrs.fg = [params[i + 2], params[i + 3], params[i + 4]]
            i += 4
          elsif params[i + 1] == 5 && params[i + 2]
            @attrs.fg = params[i + 2]
            i += 2
          end
        when 39
          @attrs.fg = nil
        when 40..47
          @attrs.bg = params[i] - 40
        when 48
          if params[i + 1] == 2 && params[i + 2] && params[i + 3] && params[i + 4]
            @attrs.bg = [params[i + 2], params[i + 3], params[i + 4]]
            i += 4
          elsif params[i + 1] == 5 && params[i + 2]
            @attrs.bg = params[i + 2]
            i += 2
          end
        when 49
          @attrs.bg = nil
        when 90..97
          @attrs.fg = params[i] - 90 + 8
        when 100..107
          @attrs.bg = params[i] - 100 + 8
        end
        i += 1
      end
    end

    def save_cursor
      saved_attrs = Cell.new
      saved_attrs.copy_from(@attrs)
      @saved_cursor = {
        row: @cursor.row, col: @cursor.col,
        attrs: saved_attrs,
        origin_mode: @origin_mode,
        auto_wrap: @auto_wrap,
        charset_g0: @charset_g0,
        charset_g1: @charset_g1,
        active_charset: @active_charset,
        pending_wrap: @pending_wrap,
      }
    end

    def restore_cursor
      if @saved_cursor
        @cursor.row = @saved_cursor[:row]
        @cursor.col = @saved_cursor[:col]
        @attrs.copy_from(@saved_cursor[:attrs])
        @origin_mode = @saved_cursor[:origin_mode]
        @auto_wrap = @saved_cursor[:auto_wrap]
        @charset_g0 = @saved_cursor[:charset_g0]
        @charset_g1 = @saved_cursor[:charset_g1]
        @active_charset = @saved_cursor[:active_charset]
        @pending_wrap = @saved_cursor[:pending_wrap] || false
      end
    end

    def application_cursor_keys?
      @application_cursor_keys
    end

    def application_cursor_keys=(val)
      @application_cursor_keys = val
    end

    def bracketed_paste_mode?
      @bracketed_paste_mode
    end

    def bracketed_paste_mode=(val)
      @bracketed_paste_mode = val
    end

    def focus_reporting?
      @focus_reporting
    end

    def focus_reporting=(val)
      @focus_reporting = val
    end

    def auto_wrap?
      @auto_wrap
    end

    def auto_wrap=(val)
      @auto_wrap = val
      @pending_wrap = false
    end

    attr_accessor :mouse_tracking, :mouse_encoding, :insert_mode, :active_charset, :application_keypad, :cursor_style, :bell

    def set_hyperlink(uri)
      @attrs.hyperlink = uri
    end

    attr_accessor :clipboard_handler

    def set_clipboard(text)
      @clipboard_handler&.call(:set, text)
    end

    def clipboard_content
      @clipboard_handler&.call(:get, nil)
    end

    def designate_charset(g, charset)
      case g
      when 0 then @charset_g0 = charset
      when 1 then @charset_g1 = charset
      end
    end

    def origin_mode?
      @origin_mode
    end

    def origin_mode=(val)
      @origin_mode = val
      @pending_wrap = false
      if val
        @cursor.row = @scroll_top
        @cursor.col = 0
      end
    end

    def using_alt_screen?
      @using_alt_screen
    end

    def switch_to_alt_screen
      return if @using_alt_screen

      @main_grid = @grid
      @main_cursor = [@cursor.row, @cursor.col, @cursor.visible]
      @main_scroll_top = @scroll_top
      @main_scroll_bottom = @scroll_bottom
      @main_saved_cursor = @saved_cursor
      @main_scrollback = @scrollback

      @grid = Array.new(@rows) { Array.new(@cols) { Cell.new } }
      @cursor = Cursor.new
      @attrs = Cell.new
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @saved_cursor = nil
      @scrollback = []
      @pending_wrap = false
      @using_alt_screen = true
    end

    def switch_to_main_screen
      return unless @using_alt_screen

      @grid = @main_grid
      @cursor = Cursor.new
      @cursor.row, @cursor.col, @cursor.visible = @main_cursor
      @scroll_top = @main_scroll_top
      @scroll_bottom = @main_scroll_bottom
      @saved_cursor = @main_saved_cursor
      @scrollback = @main_scrollback
      @attrs = Cell.new

      @main_grid = nil
      @main_cursor = nil
      @main_scroll_top = nil
      @main_scroll_bottom = nil
      @main_saved_cursor = nil
      @main_scrollback = nil
      @pending_wrap = false
      @using_alt_screen = false
    end

    def show_cursor
      @cursor.visible = true
    end

    def hide_cursor
      @cursor.visible = false
    end

    def to_text
      @grid.map { |row| row.map { |cell| cell.char }.join.rstrip }.join("\n").rstrip
    end

    def selected_text(sr, sc, er, ec)
      lines = []
      (sr..er).each do |r|
        from = (r == sr) ? sc : 0
        to = (r == er) ? ec : @cols - 1
        lines << @grid[r][from..to].map { |cell| cell.char }.join.rstrip
      end
      lines.join("\n")
    end

    def word_boundaries_at(row, col)
      return nil if row < 0 || row >= @rows || col < 0 || col >= @cols

      line = @grid[row]
      cls = char_class(line[col].char)

      start_col = col
      start_col -= 1 while start_col > 0 && char_class(line[start_col - 1].char) == cls

      end_col = col
      end_col += 1 while end_col < @cols - 1 && char_class(line[end_col + 1].char) == cls

      [start_col, end_col]
    end

    def soft_reset
      @attrs = Cell.new
      @cursor.visible = true
      @saved_cursor = nil
      @origin_mode = false
      @auto_wrap = true
      @insert_mode = false
      @application_cursor_keys = false
      @bracketed_paste_mode = false
      @focus_reporting = false
      @charset_g0 = :ascii
      @charset_g1 = :ascii
      @active_charset = 0
      @cursor_style = 0
      @tab_stops = default_tab_stops
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @pending_wrap = false
    end

    def reset
      @cursor = Cursor.new
      @attrs = Cell.new
      @grid = Array.new(@rows) { Array.new(@cols) { Cell.new } }
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @saved_cursor = nil
      @scrollback = []
      @tab_stops = default_tab_stops
      @pending_wrap = false
    end

    def resize(new_rows, new_cols)
      old_rows = @rows
      old_cols = @cols
      @rows = new_rows
      @cols = new_cols

      # Adjust grid rows
      if new_rows > old_rows
        (new_rows - old_rows).times { @grid.push(Array.new(new_cols) { Cell.new }) }
      elsif new_rows < old_rows
        @grid.slice!(new_rows..)
      end

      # Adjust grid cols
      @grid.each do |row|
        if new_cols > old_cols
          (new_cols - old_cols).times { row.push(Cell.new) }
        elsif new_cols < old_cols
          row.slice!(new_cols..)
        end
      end

      @scroll_top = 0
      @scroll_bottom = new_rows - 1
      @cursor.row = clamp_row(@cursor.row)
      @cursor.col = clamp_col(@cursor.col)
      @pending_wrap = false
    end

    private

    def default_tab_stops
      (8...@cols).step(8).to_a
    end

    def clamp_row(row)
      [[row, 0].max, @rows - 1].min
    end

    def clamp_col(col)
      [[col, 0].max, @cols - 1].min
    end

    def clear_row(r)
      @grid[r].each(&:reset!)
    end

    def char_class(c)
      if c =~ /\s/
        :space
      elsif c =~ /\w/
        :word
      else
        :other
      end
    end

    def place_multicell_block(text, mc_cols, mc_rows, scale, frac_n, frac_d, valign, halign)
      # Discard if block is larger than screen
      return if mc_cols > @cols || mc_rows > @rows

      # Wrap if it doesn't fit on current line
      if @cursor.col + mc_cols > @cols
        @cursor.col = 0
        line_feed
      end

      # Scroll if block doesn't fit vertically from cursor
      while @cursor.row + mc_rows > @rows
        scroll_up(1)
        @cursor.row = [@cursor.row - 1, 0].max
      end

      anchor_row = @cursor.row
      anchor_col = @cursor.col

      # Erase any existing multicells in the block area
      mc_rows.times do |dr|
        mc_cols.times do |dc|
          erase_multicell_at(anchor_row + dr, anchor_col + dc)
        end
      end

      # Set anchor cell
      anchor = @grid[anchor_row][anchor_col]
      anchor.copy_from(@attrs)
      anchor.char = text
      anchor.width = 1
      anchor.multicell = {
        cols: mc_cols, rows: mc_rows, scale: scale,
        frac_n: frac_n, frac_d: frac_d, valign: valign, halign: halign
      }

      # Mark continuation cells
      mc_rows.times do |dr|
        mc_cols.times do |dc|
          next if dr == 0 && dc == 0
          cont = @grid[anchor_row + dr][anchor_col + dc]
          cont.reset!
          cont.multicell = :cont
        end
      end

      @cursor.col += mc_cols
    end

    def erase_multicell_at(row, col)
      cell = @grid[row][col]
      return unless cell.multicell

      if cell.multicell.is_a?(Hash)
        # This is the anchor — erase the whole block
        mc = cell.multicell
        mc[:rows].times do |dr|
          mc[:cols].times do |dc|
            @grid[row + dr][col + dc].reset!
          end
        end
      elsif cell.multicell == :cont
        # Find the anchor by scanning up and left
        find_multicell_anchor(row, col)&.then do |ar, ac|
          erase_multicell_at(ar, ac)
        end
      end
    end

    def find_multicell_anchor(row, col)
      # Scan backwards to find the anchor cell
      (row).downto(0) do |r|
        start_col = (r == row) ? col : @cols - 1
        start_col.downto(0) do |c|
          cell = @grid[r][c]
          if cell.multicell.is_a?(Hash)
            mc = cell.multicell
            # Check if (row, col) falls within this anchor's block
            if row < r + mc[:rows] && col >= c && col < c + mc[:cols]
              return [r, c]
            end
          end
        end
      end
      nil
    end

    def char_width(c)
      cp = c.ord
      return 2 if (cp >= 0x1100 && cp <= 0x115F) ||   # Hangul Jamo
                  cp == 0x2329 || cp == 0x232A ||       # angle brackets
                  (cp >= 0x2E80 && cp <= 0x303E) ||     # CJK Radicals..CJK Symbols
                  (cp >= 0x3040 && cp <= 0x33BF) ||     # Hiragana..CJK Compat
                  (cp >= 0x3400 && cp <= 0x4DBF) ||     # CJK Unified Ext A
                  (cp >= 0x4E00 && cp <= 0xA4CF) ||     # CJK Unified..Yi
                  (cp >= 0xA960 && cp <= 0xA97C) ||     # Hangul Jamo Extended-A
                  (cp >= 0xAC00 && cp <= 0xD7A3) ||     # Hangul Syllables
                  (cp >= 0xF900 && cp <= 0xFAFF) ||     # CJK Compat Ideographs
                  (cp >= 0xFE10 && cp <= 0xFE6F) ||     # Vertical forms..CJK Compat Forms
                  (cp >= 0xFF01 && cp <= 0xFF60) ||     # Fullwidth Forms
                  (cp >= 0xFFE0 && cp <= 0xFFE6) ||     # Fullwidth Signs
                  (cp >= 0x1F000 && cp <= 0x1FBFF) ||   # Emoji & symbols
                  (cp >= 0x20000 && cp <= 0x3FFFF)      # CJK Unified Ext B-G
      1
    end
  end
end
