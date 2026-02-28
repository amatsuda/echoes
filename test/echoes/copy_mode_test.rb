# frozen_string_literal: true

require "test_helper"

class Echoes::CopyModeTest < Test::Unit::TestCase
  setup do
    @screen = Echoes::Screen.new(rows: 24, cols: 80)
    # Put some text on the screen
    "Hello World".each_char { |c| @screen.put_char(c) }
    @screen.line_feed
    @screen.carriage_return
    "  Second line".each_char { |c| @screen.put_char(c) }
    @screen.line_feed
    @screen.carriage_return
    @screen.line_feed
    @screen.carriage_return
    "foo.bar(baz)".each_char { |c| @screen.put_char(c) }
    @copy_mode = Echoes::CopyMode.new(@screen)
  end

  # --- Basic lifecycle ---

  test "initial state is inactive" do
    assert_equal(false, @copy_mode.active)
  end

  test "enter activates copy mode" do
    @copy_mode.enter
    assert_equal(true, @copy_mode.active)
  end

  test "enter sets cursor to screen cursor position" do
    @screen.move_cursor(5, 10)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    assert_equal(5, cm.cursor_row)
    assert_equal(10, cm.cursor_col)
  end

  test "exit deactivates copy mode" do
    @copy_mode.enter
    @copy_mode.exit
    assert_equal(false, @copy_mode.active)
  end

  test "exit clears selection" do
    @copy_mode.enter
    @copy_mode.handle_key('v')
    assert_equal(true, @copy_mode.selecting?)
    @copy_mode.exit
    assert_equal(false, @copy_mode.selecting?)
  end

  # --- h/j/k/l ---

  test "h moves cursor left" do
    @copy_mode.enter
    initial_col = @copy_mode.cursor_col
    @copy_mode.handle_key('l')
    @copy_mode.handle_key('h')
    assert_equal(initial_col, @copy_mode.cursor_col)
  end

  test "j moves cursor down" do
    @copy_mode.enter
    initial_row = @copy_mode.cursor_row
    @copy_mode.handle_key('j')
    assert_equal(initial_row + 1, @copy_mode.cursor_row)
  end

  test "k moves cursor up" do
    @copy_mode.enter
    @copy_mode.handle_key('j')
    @copy_mode.handle_key('j')
    row_after = @copy_mode.cursor_row
    @copy_mode.handle_key('k')
    assert_equal(row_after - 1, @copy_mode.cursor_row)
  end

  test "l moves cursor right" do
    @copy_mode.enter
    initial_col = @copy_mode.cursor_col
    @copy_mode.handle_key('l')
    assert_equal(initial_col + 1, @copy_mode.cursor_col)
  end

  # --- Line positions ---

  test "0 moves to beginning of line" do
    @copy_mode.enter
    @copy_mode.handle_key('l')
    @copy_mode.handle_key('l')
    @copy_mode.handle_key('0')
    assert_equal(0, @copy_mode.cursor_col)
  end

  test "^ moves to first non-blank" do
    @screen.move_cursor(1, 5)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    cm.handle_key('^')
    # Row 1 is "  Second line" — first non-blank at col 2
    assert_equal(2, cm.cursor_col)
  end

  test "$ moves to end of line content" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    cm.handle_key('$')
    # "Hello World" has length 11, last char at col 10
    assert_equal(10, cm.cursor_col)
  end

  # --- Document jumps ---

  test "g moves to top of scrollback" do
    @copy_mode.enter
    @copy_mode.handle_key('g')
    assert_equal(-@screen.scrollback.size, @copy_mode.cursor_row)
    assert_equal(0, @copy_mode.cursor_col)
  end

  test "G moves to bottom of screen" do
    @copy_mode.enter
    @copy_mode.handle_key('G')
    assert_equal(23, @copy_mode.cursor_row)
    assert_equal(0, @copy_mode.cursor_col)
  end

  # --- Word motions (w/e/b) ---

  test "w moves to start of next word" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # "Hello World"
    cm.handle_key('w')
    assert_equal(6, cm.cursor_col) # "World"
  end

  test "w skips punctuation as separate word" do
    @screen.move_cursor(3, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # "foo.bar(baz)"
    cm.handle_key('w')
    # "foo" is a word, "." is a separator — next word starts at "."
    assert_equal(3, cm.cursor_col)
  end

  test "e moves to end of current word" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # "Hello World" — end of "Hello" is col 4
    cm.handle_key('e')
    assert_equal(4, cm.cursor_col)
  end

  test "b moves to beginning of previous word" do
    @screen.move_cursor(0, 8)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # At col 8 in "Hello World", b should go to "World" start (col 6)
    cm.handle_key('b')
    assert_equal(6, cm.cursor_col)
  end

  test "b from word start moves to previous word start" do
    @screen.move_cursor(0, 6)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # At "World" start (col 6), b should go to "Hello" start (col 0)
    cm.handle_key('b')
    assert_equal(0, cm.cursor_col)
  end

  # --- Big WORD motions (W/E/B) ---

  test "W moves to start of next WORD" do
    @screen.move_cursor(3, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # "foo.bar(baz)" — W skips everything until whitespace
    cm.handle_key('W')
    # No whitespace in this line, so should go to end
    assert_equal(12, cm.cursor_col)
  end

  test "E moves to end of current WORD" do
    @screen.move_cursor(3, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # "foo.bar(baz)" — E goes to end of WORD (whitespace-delimited)
    cm.handle_key('E')
    assert_equal(11, cm.cursor_col) # ')' at col 11
  end

  test "B moves to beginning of previous WORD" do
    @screen.move_cursor(0, 8)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # At col 8 in "Hello World", B should go to "World" start (col 6)
    cm.handle_key('B')
    assert_equal(6, cm.cursor_col)
  end

  # --- Find in line (f/F/t/T) ---

  test "f finds next occurrence of character" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # "Hello World" — find 'o'
    cm.handle_key('f')
    cm.handle_key('o')
    assert_equal(4, cm.cursor_col) # first 'o' in "Hello"
  end

  test "F finds previous occurrence of character" do
    @screen.move_cursor(0, 10)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # At col 10 in "Hello World", F 'o' should find col 7
    cm.handle_key('F')
    cm.handle_key('o')
    assert_equal(7, cm.cursor_col)
  end

  test "t moves to just before next occurrence" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # "Hello World" — t 'W' should land at col 5 (space before W)
    cm.handle_key('t')
    cm.handle_key('W')
    assert_equal(5, cm.cursor_col)
  end

  test "T moves to just after previous occurrence" do
    @screen.move_cursor(0, 10)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # At col 10 in "Hello World", T ' ' (space at col 5) → col 6
    cm.handle_key('T')
    cm.handle_key(' ')
    assert_equal(6, cm.cursor_col)
  end

  test "; repeats last find" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    cm.handle_key('f')
    cm.handle_key('l')
    first = cm.cursor_col  # first 'l' at col 2
    cm.handle_key(';')
    assert_operator cm.cursor_col, :>, first # next 'l'
  end

  test ", repeats last find in reverse" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    cm.handle_key('f')
    cm.handle_key('l')
    cm.handle_key(';')
    second = cm.cursor_col
    cm.handle_key(',')
    assert_operator cm.cursor_col, :<, second
  end

  # --- Paragraph motions ---

  test "} moves to next blank line" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    # Row 0: "Hello World", Row 1: "  Second line", Row 2: blank, Row 3: "foo.bar(baz)"
    cm.handle_key('}')
    # Should land on or past the blank line at row 2, then on row 3
    assert_equal(3, cm.cursor_row)
  end

  test "{ moves to previous blank line" do
    @screen.move_cursor(3, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    cm.handle_key('{')
    # Should move back past blank line
    assert_operator cm.cursor_row, :<, 3
  end

  # --- H/M/L (screen-relative) ---

  test "H moves to top of visible screen" do
    @screen.move_cursor(10, 5)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    cm.handle_key('H')
    assert_equal(0, cm.cursor_row)
  end

  test "M moves to middle of visible screen" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    cm.handle_key('M')
    assert_equal(12, cm.cursor_row)
  end

  test "L moves to bottom of visible screen" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    cm.handle_key('L')
    assert_equal(23, cm.cursor_row)
  end

  # --- Scrolling ---

  test "Ctrl-D moves half page down" do
    @copy_mode.enter
    @copy_mode.handle_key('g')
    initial = @copy_mode.cursor_row
    @copy_mode.handle_key("\x04")
    assert_equal(initial + 12, @copy_mode.cursor_row)
  end

  test "Ctrl-U moves half page up" do
    @copy_mode.enter
    @copy_mode.handle_key('G')
    initial = @copy_mode.cursor_row
    @copy_mode.handle_key("\x15")
    assert_equal(initial - 12, @copy_mode.cursor_row)
  end

  test "Ctrl-F moves full page down" do
    @copy_mode.enter
    @copy_mode.handle_key('g')
    initial = @copy_mode.cursor_row
    @copy_mode.handle_key("\x06")
    # Clamped to max row (23) since no scrollback
    assert_equal([initial + 24, 23].min, @copy_mode.cursor_row)
  end

  test "Ctrl-B moves full page up" do
    @copy_mode.enter
    @copy_mode.handle_key('G')
    initial = @copy_mode.cursor_row
    @copy_mode.handle_key("\x02")
    # Clamped to min row (0) since no scrollback
    assert_equal([initial - 24, -@screen.scrollback.size].max, @copy_mode.cursor_row)
  end

  # --- Selection ---

  test "v toggles selection mode" do
    @copy_mode.enter
    assert_equal(false, @copy_mode.selecting?)
    @copy_mode.handle_key('v')
    assert_equal(true, @copy_mode.selecting?)
    @copy_mode.handle_key('v')
    assert_equal(false, @copy_mode.selecting?)
  end

  test "V starts line selection" do
    @screen.move_cursor(0, 5)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    cm.handle_key('V')
    assert_equal(true, cm.selecting?)
    assert_equal([0, 0], cm.selection_start)
    assert_equal([0, 79], cm.selection_end)
  end

  # --- Yank & exit ---

  test "q exits copy mode" do
    @copy_mode.enter
    result = @copy_mode.handle_key('q')
    assert_equal(:exit, result)
    assert_equal(false, @copy_mode.active)
  end

  test "escape exits copy mode" do
    @copy_mode.enter
    result = @copy_mode.handle_key("\e")
    assert_equal(:exit, result)
    assert_equal(false, @copy_mode.active)
  end

  test "y returns :yank when selection active" do
    @copy_mode.enter
    @copy_mode.handle_key('0')
    @copy_mode.handle_key('v')
    @copy_mode.handle_key('l')
    @copy_mode.handle_key('l')
    @copy_mode.handle_key('l')
    @copy_mode.handle_key('l')
    result = @copy_mode.handle_key('y')
    assert_equal(:yank, result)
  end

  test "y does nothing when no selection" do
    @copy_mode.enter
    result = @copy_mode.handle_key('y')
    assert_nil(result)
  end

  test "selected_text returns text within selection" do
    @screen.move_cursor(0, 0)
    cm = Echoes::CopyMode.new(@screen)
    cm.enter
    assert_equal(0, cm.cursor_row)
    assert_equal(0, cm.cursor_col)
    cm.handle_key('v')
    cm.handle_key('l')
    cm.handle_key('l')
    cm.handle_key('l')
    cm.handle_key('l')
    text = cm.selected_text
    assert_equal("Hello", text)
  end

  # --- Bounds ---

  test "cursor clamps to screen bounds" do
    @copy_mode.enter
    20.times { @copy_mode.handle_key('h') }
    assert_equal(0, @copy_mode.cursor_col)

    100.times { @copy_mode.handle_key('l') }
    assert_equal(79, @copy_mode.cursor_col)
  end

  test "cursor clamps to screen rows" do
    @copy_mode.enter
    50.times { @copy_mode.handle_key('j') }
    assert_equal(23, @copy_mode.cursor_row)
  end

  # --- Search ---

  test "n/N do nothing without a search query" do
    @copy_mode.enter
    initial_row = @copy_mode.cursor_row
    initial_col = @copy_mode.cursor_col
    @copy_mode.handle_key('n')
    assert_equal(initial_row, @copy_mode.cursor_row)
    assert_equal(initial_col, @copy_mode.cursor_col)
  end
end
