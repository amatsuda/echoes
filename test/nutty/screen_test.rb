# frozen_string_literal: true

require "test_helper"

class Nutty::ScreenTest < Test::Unit::TestCase
  setup do
    @screen = Nutty::Screen.new(rows: 5, cols: 10)
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
end
