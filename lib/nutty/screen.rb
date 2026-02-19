# frozen_string_literal: true

module Nutty
  class Screen
    attr_reader :rows, :cols, :cursor, :grid

    def initialize(rows: 24, cols: 80)
      @rows = rows
      @cols = cols
      @cursor = Cursor.new
      @attrs = Cell.new
      @grid = Array.new(rows) { Array.new(cols) { Cell.new } }
      @scroll_top = 0
      @scroll_bottom = rows - 1
      @saved_cursor = nil
    end

    def put_char(c)
      if @cursor.col >= @cols
        @cursor.col = 0
        line_feed
      end
      cell = @grid[@cursor.row][@cursor.col]
      cell.char = c
      cell.copy_from(@attrs)
      cell.char = c
      @cursor.col += 1
    end

    def move_cursor(row, col)
      @cursor.row = clamp_row(row)
      @cursor.col = clamp_col(col)
    end

    def move_cursor_up(n = 1)
      @cursor.row = [0, @cursor.row - n].max
    end

    def move_cursor_down(n = 1)
      @cursor.row = [@rows - 1, @cursor.row + n].min
    end

    def move_cursor_forward(n = 1)
      @cursor.col = [@cols - 1, @cursor.col + n].min
    end

    def move_cursor_backward(n = 1)
      @cursor.col = [0, @cursor.col - n].max
    end

    def carriage_return
      @cursor.col = 0
    end

    def line_feed
      if @cursor.row == @scroll_bottom
        scroll_up(1)
      else
        @cursor.row = [@cursor.row + 1, @rows - 1].min
      end
    end

    def reverse_index
      if @cursor.row == @scroll_top
        scroll_down(1)
      else
        @cursor.row = [0, @cursor.row - 1].max
      end
    end

    def tab
      @cursor.col = [(@cursor.col / 8 + 1) * 8, @cols - 1].min
    end

    def backspace
      @cursor.col = [0, @cursor.col - 1].max
    end

    def erase_in_display(mode = 0)
      case mode
      when 0
        erase_in_line(0)
        ((@cursor.row + 1)...@rows).each { |r| clear_row(r) }
      when 1
        erase_in_line(1)
        (0...@cursor.row).each { |r| clear_row(r) }
      when 2
        (0...@rows).each { |r| clear_row(r) }
      end
    end

    def erase_in_line(mode = 0)
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
      return unless @cursor.row >= @scroll_top && @cursor.row <= @scroll_bottom

      n.times do
        @grid.insert(@cursor.row, Array.new(@cols) { Cell.new })
        @grid.delete_at(@scroll_bottom + 1)
      end
    end

    def delete_lines(n = 1)
      return unless @cursor.row >= @scroll_top && @cursor.row <= @scroll_bottom

      n.times do
        @grid.delete_at(@cursor.row)
        @grid.insert(@scroll_bottom, Array.new(@cols) { Cell.new })
      end
    end

    def delete_chars(n = 1)
      row = @grid[@cursor.row]
      n.times do
        row.delete_at(@cursor.col)
        row.push(Cell.new)
      end
    end

    def scroll_up(n = 1)
      n.times do
        @grid.delete_at(@scroll_top)
        @grid.insert(@scroll_bottom, Array.new(@cols) { Cell.new })
      end
    end

    def scroll_down(n = 1)
      n.times do
        @grid.delete_at(@scroll_bottom)
        @grid.insert(@scroll_top, Array.new(@cols) { Cell.new })
      end
    end

    def set_scroll_region(top, bottom)
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
        when 4
          @attrs.underline = true
        when 7
          @attrs.inverse = true
        when 22
          @attrs.bold = false
        when 24
          @attrs.underline = false
        when 27
          @attrs.inverse = false
        when 30..37
          @attrs.fg = params[i] - 30
        when 38
          if params[i + 1] == 5 && params[i + 2]
            @attrs.fg = params[i + 2]
            i += 2
          end
        when 39
          @attrs.fg = nil
        when 40..47
          @attrs.bg = params[i] - 40
        when 48
          if params[i + 1] == 5 && params[i + 2]
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
      @saved_cursor = [@cursor.row, @cursor.col]
    end

    def restore_cursor
      if @saved_cursor
        @cursor.row, @cursor.col = @saved_cursor
      end
    end

    def show_cursor
      @cursor.visible = true
    end

    def hide_cursor
      @cursor.visible = false
    end

    def reset
      @cursor = Cursor.new
      @attrs = Cell.new
      @grid = Array.new(@rows) { Array.new(@cols) { Cell.new } }
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @saved_cursor = nil
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
    end

    private

    def clamp_row(row)
      [[row, 0].max, @rows - 1].min
    end

    def clamp_col(col)
      [[col, 0].max, @cols - 1].min
    end

    def clear_row(r)
      @grid[r].each(&:reset!)
    end
  end
end
