# frozen_string_literal: true

require "test_helper"

class Echoes::ParserTest < Test::Unit::TestCase
  setup do
    @screen = Echoes::Screen.new(rows: 5, cols: 10)
    @parser = Echoes::Parser.new(@screen)
  end

  def row_text(r)
    @screen.grid[r].map(&:char).join.rstrip
  end

  test "printable text" do
    @parser.feed("Hello")
    assert_equal("Hello", row_text(0))
    assert_equal(0, @screen.cursor.row)
    assert_equal(5, @screen.cursor.col)
  end

  test "CR LF" do
    @parser.feed("AB\r\nCD")
    assert_equal("AB", row_text(0))
    assert_equal("CD", row_text(1))
  end

  test "cursor position CSI H" do
    @parser.feed("\e[3;5H")
    assert_equal(2, @screen.cursor.row)
    assert_equal(4, @screen.cursor.col)
  end

  test "cursor position default CSI H" do
    @parser.feed("\e[H")
    assert_equal(0, @screen.cursor.row)
    assert_equal(0, @screen.cursor.col)
  end

  test "cursor movement A B C D" do
    @parser.feed("\e[3;5H")
    @parser.feed("\e[1A")
    assert_equal(1, @screen.cursor.row)
    @parser.feed("\e[2B")
    assert_equal(3, @screen.cursor.row)
    @parser.feed("\e[3C")
    assert_equal(7, @screen.cursor.col)
    @parser.feed("\e[2D")
    assert_equal(5, @screen.cursor.col)
  end

  test "erase display CSI 2J" do
    @parser.feed("XXXXX")
    @parser.feed("\e[2J")
    assert_equal("", row_text(0))
  end

  test "erase line CSI K" do
    @parser.feed("ABCDE")
    @parser.feed("\e[1;3H") # cursor at row 0, col 2
    @parser.feed("\e[K")    # erase to right
    assert_equal("AB", row_text(0))
  end

  test "SGR bold and color" do
    @parser.feed("\e[1;31mX\e[0m")
    cell = @screen.grid[0][0]
    assert_equal("X", cell.char)
    assert_equal(true, cell.bold)
    assert_equal(1, cell.fg)
  end

  test "SGR reset" do
    @parser.feed("\e[1;31mA\e[0mB")
    a = @screen.grid[0][0]
    b = @screen.grid[0][1]
    assert_equal(true, a.bold)
    assert_equal(false, b.bold)
    assert_nil(b.fg)
  end

  test "hide and show cursor" do
    @parser.feed("\e[?25l")
    assert_equal(false, @screen.cursor.visible)
    @parser.feed("\e[?25h")
    assert_equal(true, @screen.cursor.visible)
  end

  test "save and restore cursor ESC 7/8" do
    @parser.feed("\e[3;5H")
    @parser.feed("\e7")
    @parser.feed("\e[1;1H")
    @parser.feed("\e8")
    assert_equal(2, @screen.cursor.row)
    assert_equal(4, @screen.cursor.col)
  end

  test "save and restore cursor CSI s/u" do
    @parser.feed("\e[3;5H")
    @parser.feed("\e[s")
    @parser.feed("\e[1;1H")
    @parser.feed("\e[u")
    assert_equal(2, @screen.cursor.row)
    assert_equal(4, @screen.cursor.col)
  end

  test "full reset ESC c" do
    @parser.feed("XXXXX")
    @parser.feed("\ec")
    assert_equal("", row_text(0))
    assert_equal(0, @screen.cursor.row)
    assert_equal(0, @screen.cursor.col)
  end

  test "scroll up CSI S" do
    @parser.feed("AAAAA\r\nBBBBB")
    @parser.feed("\e[1S")
    assert_equal("BBBBB", row_text(0))
  end

  test "scroll down CSI T" do
    @parser.feed("AAAAA\r\nBBBBB")
    @parser.feed("\e[1T")
    assert_equal("", row_text(0))
    assert_equal("AAAAA", row_text(1))
  end

  test "incomplete sequence then complete" do
    @parser.feed("\e[")
    @parser.feed("2J")
    # Should still work as a complete CSI 2J
    @parser.feed("Hello")
    assert_equal("Hello", row_text(0))
  end

  test "line feed scrolls at bottom" do
    4.times { @parser.feed("\n") }
    # Now at row 4 (last row)
    @parser.feed("Z")
    @parser.feed("\n")
    # Should have scrolled
    assert_equal(4, @screen.cursor.row)
  end

  test "CHA cursor horizontal absolute" do
    @parser.feed("ABCDE")
    @parser.feed("\e[3G")
    assert_equal(2, @screen.cursor.col)
  end

  test "VPA vertical position absolute" do
    @parser.feed("\e[4d")
    assert_equal(3, @screen.cursor.row)
  end

  test "insert lines CSI L" do
    @parser.feed("AAAAA\r\nBBBBB")
    @parser.feed("\e[1;1H")
    @parser.feed("\e[1L")
    assert_equal("", row_text(0))
    assert_equal("AAAAA", row_text(1))
  end

  test "delete lines CSI M" do
    @parser.feed("AAAAA\r\nBBBBB\r\nCCCCC")
    @parser.feed("\e[1;1H")
    @parser.feed("\e[1M")
    assert_equal("BBBBB", row_text(0))
    assert_equal("CCCCC", row_text(1))
  end

  test "UTF-8 multibyte character" do
    @parser.feed("café")
    assert_equal("café", row_text(0))
  end

  test "OSC sequence is consumed and ignored" do
    @parser.feed("\e]0;title\x07")
    @parser.feed("OK")
    assert_equal("OK", row_text(0))
  end

  test "reverse index ESC M" do
    @parser.feed("\eM")
    assert_equal(0, @screen.cursor.row)
  end

  test "set scroll region CSI r" do
    @parser.feed("\e[2;4r")
    # Cursor should reset to 0,0 after setting scroll region
    assert_equal(0, @screen.cursor.row)
    assert_equal(0, @screen.cursor.col)
  end
end
