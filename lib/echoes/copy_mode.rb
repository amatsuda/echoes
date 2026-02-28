# frozen_string_literal: true

module Echoes
  class CopyMode
    attr_reader :active, :cursor_row, :cursor_col
    attr_reader :selection_start, :selection_end

    def initialize(screen)
      @screen = screen
      @active = false
      @cursor_row = 0
      @cursor_col = 0
      @selection_start = nil
      @selection_end = nil
      @search_query = nil
      @search_direction = :forward
      @pending_find = nil   # :f, :F, :t, :T
      @last_find = nil      # [direction, char] for ; and ,
      @line_selection = false
    end

    def enter
      @active = true
      @cursor_row = @screen.cursor.row
      @cursor_col = @screen.cursor.col
      @selection_start = nil
      @selection_end = nil
      @search_query = nil
    end

    def exit
      @active = false
      @selection_start = nil
      @selection_end = nil
      @line_selection = false
      @search_query = nil
    end

    def selecting?
      @selection_start != nil
    end

    # Handle a key in copy mode. Returns :exit if copy mode should end,
    # :yank if text was yanked, nil otherwise.
    def handle_key(key)
      # Pending f/F/t/T — next key is the target character
      if @pending_find
        execute_find(@pending_find, key)
        @pending_find = nil
        update_selection_end if selecting?
        return nil
      end

      case key
      # Basic movement
      when 'h'
        move_cursor(0, -1)
      when 'j'
        move_cursor(1, 0)
      when 'k'
        move_cursor(-1, 0)
      when 'l'
        move_cursor(0, 1)

      # Line positions
      when '0'
        @cursor_col = 0
      when '^'
        move_first_non_blank
      when '$'
        move_end_of_line

      # Word motions (vim-style: word = keyword chars)
      when 'w'
        move_word_forward
      when 'e'
        move_word_end_forward
      when 'b'
        move_word_backward

      # WORD motions (whitespace-delimited)
      when 'W'
        move_bigword_forward
      when 'E'
        move_bigword_end_forward
      when 'B'
        move_bigword_backward

      # Find in line
      when 'f'
        @pending_find = :f
      when 'F'
        @pending_find = :F
      when 't'
        @pending_find = :t
      when 'T'
        @pending_find = :T
      when ';'
        repeat_find(:same)
      when ','
        repeat_find(:reverse)

      # Screen-relative jumps
      when 'H'
        @cursor_row = visible_top_row
      when 'M'
        @cursor_row = visible_top_row + @screen.rows / 2
      when 'L'
        @cursor_row = visible_top_row + @screen.rows - 1

      # Document jumps
      when 'g'
        @cursor_row = -@screen.scrollback.size
        @cursor_col = 0
      when 'G'
        @cursor_row = @screen.rows - 1
        @cursor_col = 0

      # Paragraph motions
      when '{'
        move_paragraph_backward
      when '}'
        move_paragraph_forward

      # Scrolling
      when "\x15" # Ctrl-U
        move_cursor(-(@screen.rows / 2), 0)
      when "\x04" # Ctrl-D
        move_cursor(@screen.rows / 2, 0)
      when "\x02" # Ctrl-B
        move_cursor(-@screen.rows, 0)
      when "\x06" # Ctrl-F
        move_cursor(@screen.rows, 0)

      # Search
      when '/'
        @search_query = +""
        @search_direction = :forward
      when '?'
        @search_query = +""
        @search_direction = :backward
      when 'n'
        search_next
      when 'N'
        search_prev

      # Selection & yank
      when 'v'
        start_selection
      when 'V'
        start_line_selection
      when 'y'
        return :yank if selecting?
      when 'q', "\e"
        self.exit
        return :exit
      end
      update_selection_end if selecting?
      nil
    end

    # Extract text from selection range
    def selected_text
      return "" unless @selection_start && @selection_end

      start_pos, end_pos = [@selection_start, @selection_end].sort_by { |p| [p[0], p[1]] }
      sr, sc = start_pos
      er, ec = end_pos

      lines = []
      (sr..er).each do |row|
        line = row_text(row)
        if row == sr && row == er
          lines << line[sc..ec]
        elsif row == sr
          lines << line[sc..]
        elsif row == er
          lines << line[0..ec]
        else
          lines << line
        end
      end
      lines.join("\n")
    end

    # Scroll offset needed to keep cursor visible
    def scroll_offset_for_cursor
      if @cursor_row < 0
        @cursor_row.abs
      else
        0
      end
    end

    # Absolute row in the combined scrollback+grid buffer
    def absolute_cursor_row
      @screen.scrollback.size + @cursor_row
    end

    private

    def move_cursor(dr, dc)
      new_row = @cursor_row + dr
      new_col = @cursor_col + dc

      min_row = -@screen.scrollback.size
      max_row = @screen.rows - 1

      @cursor_row = new_row.clamp(min_row, max_row)
      @cursor_col = new_col.clamp(0, @screen.cols - 1)
    end

    # --- Character classification ---

    def char_class(c)
      if c.nil? || c.empty? || c == ' '
        :space
      elsif word_separators.include?(c)
        :separator
      else
        :word
      end
    end

    def word_separators
      Echoes.config.word_separators
    end

    # --- Line positions ---

    def move_first_non_blank
      line = row_text(@cursor_row)
      col = 0
      col += 1 while col < @screen.cols && line[col] == ' '
      @cursor_col = col.clamp(0, @screen.cols - 1)
    end

    def move_end_of_line
      line = row_text(@cursor_row)
      col = line.rstrip.length - 1
      @cursor_col = col.clamp(0, @screen.cols - 1)
    end

    # --- Small word motions (vim 'word': same-class sequences) ---

    def move_word_forward
      line = row_text(@cursor_row)
      col = @cursor_col
      max = @screen.cols - 1

      if col < max
        cls = char_class(line[col])
        # Skip rest of current word/separator run
        col += 1 while col < max && char_class(line[col]) == cls
        # Skip whitespace
        col += 1 while col < max && char_class(line[col]) == :space
      end

      if col >= max && @cursor_row < @screen.rows - 1
        # Wrap to next line's first non-blank
        @cursor_row += 1
        line = row_text(@cursor_row)
        col = 0
        col += 1 while col < max && char_class(line[col]) == :space
      end

      @cursor_col = col.clamp(0, max)
    end

    def move_word_end_forward
      line = row_text(@cursor_row)
      col = @cursor_col
      max = @screen.cols - 1

      # Move at least one position
      col += 1 if col < max
      line = row_text(@cursor_row)

      # Skip whitespace
      col += 1 while col < max && char_class(line[col]) == :space

      # Move to end of word
      cls = char_class(line[col])
      col += 1 while col < max && char_class(line[col + 1]) == cls

      @cursor_col = col.clamp(0, max)
    end

    def move_word_backward
      line = row_text(@cursor_row)
      col = @cursor_col

      if col > 0
        col -= 1
        # Skip whitespace
        col -= 1 while col > 0 && char_class(line[col]) == :space
        # Skip to beginning of word
        cls = char_class(line[col])
        col -= 1 while col > 0 && char_class(line[col - 1]) == cls
      end

      if col <= 0 && @cursor_row > -@screen.scrollback.size
        # Wrap to end of previous line
        @cursor_row -= 1
        line = row_text(@cursor_row)
        col = line.rstrip.length - 1
        col = 0 if col < 0
      end

      @cursor_col = col.clamp(0, @screen.cols - 1)
    end

    # --- Big WORD motions (whitespace-delimited) ---

    def move_bigword_forward
      line = row_text(@cursor_row)
      col = @cursor_col
      content_end = line.rstrip.length

      if col < content_end
        # Skip non-space
        col += 1 while col < content_end && line[col] != ' '
        # Skip space
        col += 1 while col < content_end && line[col] == ' '
      end

      @cursor_col = col.clamp(0, @screen.cols - 1)
    end

    def move_bigword_end_forward
      line = row_text(@cursor_row)
      col = @cursor_col
      max = @screen.cols - 1

      col += 1 if col < max
      # Skip space
      col += 1 while col < max && line[col] == ' '
      # Move to end of WORD
      col += 1 while col < max && line[col + 1] && line[col + 1] != ' '

      @cursor_col = col.clamp(0, max)
    end

    def move_bigword_backward
      line = row_text(@cursor_row)
      col = @cursor_col

      col -= 1 if col > 0
      # Skip space
      col -= 1 while col > 0 && line[col] == ' '
      # Skip to beginning of WORD
      col -= 1 while col > 0 && line[col - 1] && line[col - 1] != ' '

      @cursor_col = col.clamp(0, @screen.cols - 1)
    end

    # --- Find in line (f/F/t/T) ---

    def execute_find(direction, char)
      @last_find = [direction, char]
      line = row_text(@cursor_row)

      case direction
      when :f
        idx = line.index(char, @cursor_col + 1)
        @cursor_col = idx if idx
      when :F
        idx = line.rindex(char, [@cursor_col - 1, 0].max)
        @cursor_col = idx if idx && idx < @cursor_col
      when :t
        idx = line.index(char, @cursor_col + 1)
        @cursor_col = idx - 1 if idx && idx > @cursor_col + 1
      when :T
        idx = line.rindex(char, [@cursor_col - 1, 0].max)
        @cursor_col = idx + 1 if idx && idx + 1 < @cursor_col
      end
    end

    def repeat_find(mode)
      return unless @last_find

      direction, char = @last_find
      if mode == :reverse
        direction = {:f => :F, :F => :f, :t => :T, :T => :t}[direction]
      end
      execute_find(direction, char)
    end

    # --- Paragraph motions ---

    def move_paragraph_backward
      row = @cursor_row - 1
      min_row = -@screen.scrollback.size
      # Skip non-blank lines
      row -= 1 while row > min_row && !blank_row?(row)
      # Skip blank lines
      row -= 1 while row > min_row && blank_row?(row)
      @cursor_row = row.clamp(min_row, @screen.rows - 1)
      @cursor_col = 0
    end

    def move_paragraph_forward
      row = @cursor_row + 1
      max_row = @screen.rows - 1
      # Skip non-blank lines
      row += 1 while row < max_row && !blank_row?(row)
      # Skip blank lines
      row += 1 while row < max_row && blank_row?(row)
      @cursor_row = row.clamp(-@screen.scrollback.size, max_row)
      @cursor_col = 0
    end

    def blank_row?(row)
      row_text(row).strip.empty?
    end

    # --- Search ---

    def search_next
      return unless @search_query && !@search_query.empty?
      if @search_direction == :forward
        search_forward
      else
        search_backward
      end
    end

    def search_prev
      return unless @search_query && !@search_query.empty?
      if @search_direction == :forward
        search_backward
      else
        search_forward
      end
    end

    def search_forward
      min_row = -@screen.scrollback.size
      max_row = @screen.rows - 1

      # Search from current position forward
      ((@cursor_row)..max_row).each do |row|
        line = row_text(row)
        start = (row == @cursor_row) ? @cursor_col + 1 : 0
        idx = line.index(@search_query, start)
        if idx
          @cursor_row = row
          @cursor_col = idx
          return
        end
      end

      # Wrap around from top
      (min_row...@cursor_row).each do |row|
        line = row_text(row)
        idx = line.index(@search_query)
        if idx
          @cursor_row = row
          @cursor_col = idx
          return
        end
      end
    end

    def search_backward
      min_row = -@screen.scrollback.size
      max_row = @screen.rows - 1

      # Search from current position backward
      @cursor_row.downto(min_row) do |row|
        line = row_text(row)
        limit = (row == @cursor_row) ? [@cursor_col - 1, 0].max : line.length
        idx = line.rindex(@search_query, limit)
        if idx && (row != @cursor_row || idx < @cursor_col)
          @cursor_row = row
          @cursor_col = idx
          return
        end
      end

      # Wrap around from bottom
      max_row.downto(@cursor_row + 1) do |row|
        line = row_text(row)
        idx = line.rindex(@search_query)
        if idx
          @cursor_row = row
          @cursor_col = idx
          return
        end
      end
    end

    # --- Screen-relative ---

    def visible_top_row
      @cursor_row - @cursor_row.clamp(0, @screen.rows - 1)
    end

    # --- Selection ---

    def start_selection
      if selecting?
        @selection_start = nil
        @selection_end = nil
        @line_selection = false
      else
        @selection_start = [@cursor_row, @cursor_col]
        @selection_end = [@cursor_row, @cursor_col]
        @line_selection = false
      end
    end

    def start_line_selection
      if selecting?
        @selection_start = nil
        @selection_end = nil
        @line_selection = false
      else
        @selection_start = [@cursor_row, 0]
        @selection_end = [@cursor_row, @screen.cols - 1]
        @line_selection = true
      end
    end

    def update_selection_end
      if @line_selection
        @selection_start = [[@selection_start[0], @cursor_row].min, 0]
        @selection_end = [[@selection_end[0], @cursor_row].max, @screen.cols - 1]
      else
        @selection_end = [@cursor_row, @cursor_col]
      end
    end

    def row_text(row)
      if row < 0
        sb_index = @screen.scrollback.size + row
        return "" if sb_index < 0 || sb_index >= @screen.scrollback.size
        @screen.scrollback[sb_index].map(&:char).join
      else
        return "" if row >= @screen.rows
        @screen.grid[row].map(&:char).join
      end
    end
  end
end
