# frozen_string_literal: true

require "test_helper"

class Echoes::ScreenTest < Test::Unit::TestCase
  setup do
    @screen = Echoes::Screen.new(rows: 5, cols: 10)
  end

  test "initial state" do
    assert_equal(5, @screen.rows)
    assert_equal(10, @screen.cols)
    assert_equal(0, @screen.cursor.row)
    assert_equal(0, @screen.cursor.col)
  end

  test "put_char writes and advances cursor" do
    @screen.put_char("A")
    assert_equal("A", @screen.grid[0][0].char)
    assert_equal(0, @screen.cursor.row)
    assert_equal(1, @screen.cursor.col)
  end

  test "put_char wraps at end of line" do
    10.times { |i| @screen.put_char(("A".ord + i).chr) }
    assert_equal(0, @screen.cursor.row)
    assert_equal(10, @screen.cursor.col)

    # Next char triggers wrap
    @screen.put_char("Z")
    assert_equal(1, @screen.cursor.row)
    assert_equal(1, @screen.cursor.col)
    assert_equal("Z", @screen.grid[1][0].char)
  end

  test "carriage_return" do
    @screen.put_char("A")
    @screen.put_char("B")
    @screen.carriage_return
    assert_equal(0, @screen.cursor.col)
    assert_equal(0, @screen.cursor.row)
  end

  test "line_feed" do
    @screen.line_feed
    assert_equal(1, @screen.cursor.row)
  end

  test "line_feed scrolls at bottom" do
    @screen.put_char("X")
    @screen.cursor.row = 4 # last row
    @screen.line_feed
    assert_equal(4, @screen.cursor.row)
    # First row should now be blank (scrolled away)
    assert_equal(" ", @screen.grid[0][0].char)
  end

  test "move_cursor" do
    @screen.move_cursor(2, 5)
    assert_equal(2, @screen.cursor.row)
    assert_equal(5, @screen.cursor.col)
  end

  test "move_cursor clamps to bounds" do
    @screen.move_cursor(100, 100)
    assert_equal(4, @screen.cursor.row)
    assert_equal(9, @screen.cursor.col)

    @screen.move_cursor(-1, -1)
    assert_equal(0, @screen.cursor.row)
    assert_equal(0, @screen.cursor.col)
  end

  test "move_cursor_up" do
    @screen.cursor.row = 3
    @screen.move_cursor_up(2)
    assert_equal(1, @screen.cursor.row)
  end

  test "move_cursor_up clamps at 0" do
    @screen.cursor.row = 1
    @screen.move_cursor_up(5)
    assert_equal(0, @screen.cursor.row)
  end

  test "move_cursor_down" do
    @screen.move_cursor_down(2)
    assert_equal(2, @screen.cursor.row)
  end

  test "move_cursor_forward" do
    @screen.move_cursor_forward(3)
    assert_equal(3, @screen.cursor.col)
  end

  test "move_cursor_backward" do
    @screen.cursor.col = 5
    @screen.move_cursor_backward(2)
    assert_equal(3, @screen.cursor.col)
  end

  test "tab" do
    @screen.cursor.col = 1
    @screen.tab
    assert_equal(8, @screen.cursor.col)
  end

  test "backspace" do
    @screen.cursor.col = 3
    @screen.backspace
    assert_equal(2, @screen.cursor.col)
  end

  test "backspace at col 0 stays" do
    @screen.backspace
    assert_equal(0, @screen.cursor.col)
  end

  test "erase_in_display 0 (below)" do
    5.times { |r| @screen.grid[r].each { |c| c.char = "X" } }
    @screen.cursor.row = 2
    @screen.cursor.col = 5
    @screen.erase_in_display(0)

    # Row 2, cols 5-9 should be erased
    assert_equal("X", @screen.grid[2][4].char)
    assert_equal(" ", @screen.grid[2][5].char)
    # Rows 3-4 should be fully erased
    assert_equal(" ", @screen.grid[3][0].char)
    assert_equal(" ", @screen.grid[4][0].char)
    # Rows 0-1 should be untouched
    assert_equal("X", @screen.grid[0][0].char)
    assert_equal("X", @screen.grid[1][0].char)
  end

  test "erase_in_display 2 (all)" do
    5.times { |r| @screen.grid[r].each { |c| c.char = "X" } }
    @screen.erase_in_display(2)
    @screen.grid.each do |row|
      row.each { |cell| assert_equal(" ", cell.char) }
    end
  end

  test "erase_in_line 0 (to right)" do
    @screen.grid[0].each { |c| c.char = "X" }
    @screen.cursor.col = 3
    @screen.erase_in_line(0)
    assert_equal("X", @screen.grid[0][2].char)
    assert_equal(" ", @screen.grid[0][3].char)
    assert_equal(" ", @screen.grid[0][9].char)
  end

  test "erase_in_line 2 (whole line)" do
    @screen.grid[0].each { |c| c.char = "X" }
    @screen.erase_in_line(2)
    @screen.grid[0].each { |cell| assert_equal(" ", cell.char) }
  end

  test "set_graphics SGR reset" do
    @screen.set_graphics([1]) # bold
    @screen.set_graphics([0]) # reset
    @screen.put_char("A")
    assert_equal(false, @screen.grid[0][0].bold)
  end

  test "set_graphics SGR colors" do
    @screen.set_graphics([1, 31, 42]) # bold, fg red, bg green
    @screen.put_char("A")
    cell = @screen.grid[0][0]
    assert_equal(true, cell.bold)
    assert_equal(1, cell.fg)
    assert_equal(2, cell.bg)
  end

  test "set_graphics SGR bright colors" do
    @screen.set_graphics([91, 102]) # bright red fg, bright green bg
    @screen.put_char("A")
    cell = @screen.grid[0][0]
    assert_equal(9, cell.fg)   # 91-90+8 = 9
    assert_equal(10, cell.bg)  # 102-100+8 = 10
  end

  test "set_graphics SGR 256-color" do
    @screen.set_graphics([38, 5, 196]) # fg 256-color
    @screen.put_char("A")
    assert_equal(196, @screen.grid[0][0].fg)
  end

  test "scroll_up" do
    @screen.grid[0][0].char = "A"
    @screen.grid[1][0].char = "B"
    @screen.scroll_up(1)
    assert_equal("B", @screen.grid[0][0].char)
    assert_equal(" ", @screen.grid[4][0].char)
  end

  test "scroll_down" do
    @screen.grid[0][0].char = "A"
    @screen.grid[4][0].char = "Z"
    @screen.scroll_down(1)
    assert_equal(" ", @screen.grid[0][0].char)
    assert_equal("A", @screen.grid[1][0].char)
  end

  test "save_cursor and restore_cursor" do
    @screen.cursor.row = 2
    @screen.cursor.col = 5
    @screen.save_cursor
    @screen.cursor.row = 0
    @screen.cursor.col = 0
    @screen.restore_cursor
    assert_equal(2, @screen.cursor.row)
    assert_equal(5, @screen.cursor.col)
  end

  test "show_cursor and hide_cursor" do
    @screen.hide_cursor
    assert_equal(false, @screen.cursor.visible)
    @screen.show_cursor
    assert_equal(true, @screen.cursor.visible)
  end

  test "reset" do
    @screen.put_char("X")
    @screen.set_graphics([1])
    @screen.reset
    assert_equal(0, @screen.cursor.row)
    assert_equal(0, @screen.cursor.col)
    assert_equal(" ", @screen.grid[0][0].char)
  end

  test "resize grows" do
    @screen.put_char("A")
    @screen.resize(8, 15)
    assert_equal(8, @screen.rows)
    assert_equal(15, @screen.cols)
    assert_equal(8, @screen.grid.size)
    assert_equal(15, @screen.grid[0].size)
    assert_equal("A", @screen.grid[0][0].char)
  end

  test "resize shrinks" do
    @screen.resize(3, 5)
    assert_equal(3, @screen.rows)
    assert_equal(5, @screen.cols)
    assert_equal(3, @screen.grid.size)
    assert_equal(5, @screen.grid[0].size)
  end

  test "insert_lines" do
    @screen.grid[0][0].char = "A"
    @screen.grid[1][0].char = "B"
    @screen.cursor.row = 0
    @screen.insert_lines(1)
    assert_equal(" ", @screen.grid[0][0].char)
    assert_equal("A", @screen.grid[1][0].char)
    assert_equal("B", @screen.grid[2][0].char)
  end

  test "delete_lines" do
    @screen.grid[0][0].char = "A"
    @screen.grid[1][0].char = "B"
    @screen.grid[2][0].char = "C"
    @screen.cursor.row = 0
    @screen.delete_lines(1)
    assert_equal("B", @screen.grid[0][0].char)
    assert_equal("C", @screen.grid[1][0].char)
  end

  test "delete_chars" do
    @screen.grid[0][0].char = "A"
    @screen.grid[0][1].char = "B"
    @screen.grid[0][2].char = "C"
    @screen.cursor.row = 0
    @screen.cursor.col = 0
    @screen.delete_chars(1)
    assert_equal("B", @screen.grid[0][0].char)
    assert_equal("C", @screen.grid[0][1].char)
  end

  test "reverse_index" do
    @screen.cursor.row = 0
    @screen.grid[0][0].char = "A"
    @screen.reverse_index
    assert_equal(0, @screen.cursor.row)
    # Row 0 should now be blank (scrolled down), A moved to row 1
    assert_equal(" ", @screen.grid[0][0].char)
    assert_equal("A", @screen.grid[1][0].char)
  end

  # --- Multicell (OSC 66 text sizing) ---

  test "put_multicell auto width" do
    @screen.put_multicell("A", scale: 2, width: 0, frac_n: 0, frac_d: 0, valign: 0, halign: 0)
    anchor = @screen.grid[0][0]
    assert_equal("A", anchor.char)
    assert_equal(2, anchor.multicell[:cols])
    assert_equal(2, anchor.multicell[:rows])
    assert_equal(:cont, @screen.grid[0][1].multicell)
    assert_equal(:cont, @screen.grid[1][0].multicell)
    assert_equal(:cont, @screen.grid[1][1].multicell)
    assert_equal(2, @screen.cursor.col)
  end

  test "put_multicell explicit width" do
    @screen.put_multicell("Hi", scale: 2, width: 3, frac_n: 0, frac_d: 0, valign: 0, halign: 0)
    anchor = @screen.grid[0][0]
    assert_equal("Hi", anchor.char)
    assert_equal(6, anchor.multicell[:cols])
    assert_equal(2, anchor.multicell[:rows])
    assert_equal(6, @screen.cursor.col)
  end

  test "put_multicell wraps when not enough columns" do
    @screen.cursor.col = 9
    @screen.put_multicell("A", scale: 2, width: 0, frac_n: 0, frac_d: 0, valign: 0, halign: 0)
    # Should have wrapped to next line
    assert_nil(@screen.grid[0][0].multicell)  # row 0 untouched
    assert_equal("A", @screen.grid[1][0].char)
    assert_equal(2, @screen.cursor.col)
  end

  test "put_multicell discards block larger than screen" do
    @screen.put_multicell("A", scale: 6, width: 2, frac_n: 0, frac_d: 0, valign: 0, halign: 0)
    # 6*2=12 cols > 10, should be discarded
    assert_nil(@screen.grid[0][0].multicell)
  end

  test "put_char erases multicell" do
    @screen.put_multicell("A", scale: 2, width: 0, frac_n: 0, frac_d: 0, valign: 0, halign: 0)
    # Overwrite a cell within the multicell block
    @screen.cursor.row = 0
    @screen.cursor.col = 1
    @screen.put_char("X")
    # Entire multicell should be erased
    assert_nil(@screen.grid[0][0].multicell)
    assert_nil(@screen.grid[1][0].multicell)
    assert_nil(@screen.grid[1][1].multicell)
    # The overwritten cell has the new char
    assert_equal("X", @screen.grid[0][1].char)
  end

  test "put_multicell multiple graphemes in auto width" do
    @screen.put_multicell("AB", scale: 2, width: 0, frac_n: 0, frac_d: 0, valign: 0, halign: 0)
    # A at (0,0), B at (0,2)
    assert_equal("A", @screen.grid[0][0].char)
    assert_equal(2, @screen.grid[0][0].multicell[:cols])
    assert_equal("B", @screen.grid[0][2].char)
    assert_equal(2, @screen.grid[0][2].multicell[:cols])
    assert_equal(4, @screen.cursor.col)
  end

  # --- to_text ---

  test "to_text on empty screen" do
    assert_equal("", @screen.to_text)
  end

  test "to_text with single line" do
    "Hello".each_char { |c| @screen.put_char(c) }
    assert_equal("Hello", @screen.to_text)
  end

  test "to_text with multiple lines" do
    "AB".each_char { |c| @screen.put_char(c) }
    @screen.carriage_return
    @screen.line_feed
    "CD".each_char { |c| @screen.put_char(c) }
    assert_equal("AB\nCD", @screen.to_text)
  end

  test "to_text strips trailing spaces per line" do
    @screen.put_char("A")
    # rest of row 0 is spaces — should be stripped
    assert_equal("A", @screen.to_text)
  end

  test "to_text strips trailing blank lines" do
    @screen.put_char("X")
    # rows 1-4 are all blank — should be stripped
    text = @screen.to_text
    assert_false(text.end_with?("\n"))
    assert_equal("X", text)
  end

  test "to_text with wide characters" do
    @screen.put_char("\u{3042}") # あ (width 2)
    @screen.put_char("B")
    assert_equal("\u{3042} B", @screen.to_text)
  end

  # --- selected_text ---

  test "selected_text single line" do
    "Hello World".each_char { |c| @screen.put_char(c) }
    # row 0 is "Hello Worl" (10 cols), row 1 is "d"
    assert_equal("llo W", @screen.selected_text(0, 2, 0, 6))
  end

  test "selected_text multi-line" do
    "ABCDEFGHIJ".each_char { |c| @screen.put_char(c) }
    @screen.carriage_return
    @screen.line_feed
    "KLMNOPQRST".each_char { |c| @screen.put_char(c) }
    @screen.carriage_return
    @screen.line_feed
    "UVWXYZ".each_char { |c| @screen.put_char(c) }
    # row 0: "ABCDEFGHIJ", row 1: "KLMNOPQRST", row 2: "UVWXYZ    "
    text = @screen.selected_text(0, 5, 2, 3)
    assert_equal("FGHIJ\nKLMNOPQRST\nUVWX", text)
  end

  test "selected_text single cell" do
    "ABC".each_char { |c| @screen.put_char(c) }
    assert_equal("B", @screen.selected_text(0, 1, 0, 1))
  end

  test "selected_text strips trailing spaces" do
    "Hi".each_char { |c| @screen.put_char(c) }
    @screen.carriage_return
    @screen.line_feed
    "Bye".each_char { |c| @screen.put_char(c) }
    # Select from col 0 to col 9 (full lines)
    text = @screen.selected_text(0, 0, 1, 9)
    assert_equal("Hi\nBye", text)
  end

  test "selected_text entire row" do
    "ABCDEFGHIJ".each_char { |c| @screen.put_char(c) }
    assert_equal("ABCDEFGHIJ", @screen.selected_text(0, 0, 0, 9))
  end

  # --- word_boundaries_at ---

  test "word_boundaries_at selects word" do
    "foo bar".each_char { |c| @screen.put_char(c) }
    assert_equal([0, 2], @screen.word_boundaries_at(0, 1))
  end

  test "word_boundaries_at at word start" do
    "foo bar".each_char { |c| @screen.put_char(c) }
    assert_equal([0, 2], @screen.word_boundaries_at(0, 0))
  end

  test "word_boundaries_at at word end" do
    "foo bar".each_char { |c| @screen.put_char(c) }
    assert_equal([0, 2], @screen.word_boundaries_at(0, 2))
  end

  test "word_boundaries_at second word" do
    "foo bar".each_char { |c| @screen.put_char(c) }
    assert_equal([4, 6], @screen.word_boundaries_at(0, 5))
  end

  test "word_boundaries_at on space between words" do
    "foo bar".each_char { |c| @screen.put_char(c) }
    # Single space at col 3, bounded by word chars on both sides
    assert_equal([3, 3], @screen.word_boundaries_at(0, 3))
  end

  test "word_boundaries_at on trailing spaces" do
    "foo".each_char { |c| @screen.put_char(c) }
    # Cols 3-9 are all default spaces
    assert_equal([3, 9], @screen.word_boundaries_at(0, 5))
  end

  test "word_boundaries_at with punctuation" do
    "foo(bar)".each_char { |c| @screen.put_char(c) }
    # "foo" is word class, "(" is other class, "bar" is word, ")" is other
    assert_equal([0, 2], @screen.word_boundaries_at(0, 0))
    assert_equal([3, 3], @screen.word_boundaries_at(0, 3))
    assert_equal([4, 6], @screen.word_boundaries_at(0, 4))
    assert_equal([7, 7], @screen.word_boundaries_at(0, 7))
  end

  test "word_boundaries_at with underscore" do
    "foo_bar x".each_char { |c| @screen.put_char(c) }
    # underscore is a word char
    assert_equal([0, 6], @screen.word_boundaries_at(0, 3))
  end

  test "word_boundaries_at out of bounds" do
    assert_nil(@screen.word_boundaries_at(-1, 0))
    assert_nil(@screen.word_boundaries_at(0, 20))
  end
end
