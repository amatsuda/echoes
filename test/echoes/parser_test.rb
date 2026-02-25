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

  test "OSC 66 multicell with scale" do
    @parser.feed("\e]66;s=2;A\x07")
    cell = @screen.grid[0][0]
    assert_equal("A", cell.char)
    assert_equal({cols: 2, rows: 2, scale: 2, frac_n: 0, frac_d: 0, valign: 0, halign: 0}, cell.multicell)
    # Continuation cells
    assert_equal(:cont, @screen.grid[0][1].multicell)
    assert_equal(:cont, @screen.grid[1][0].multicell)
    assert_equal(:cont, @screen.grid[1][1].multicell)
    # Cursor advanced by 2 cols
    assert_equal(2, @screen.cursor.col)
  end

  test "OSC 66 multicell with explicit width" do
    @parser.feed("\e]66;s=2:w=3;Hi\x07")
    cell = @screen.grid[0][0]
    assert_equal("Hi", cell.char)
    assert_equal(6, cell.multicell[:cols])  # s*w = 2*3 = 6
    assert_equal(2, cell.multicell[:rows])
    assert_equal(6, @screen.cursor.col)
  end

  test "OSC 66 with ESC ST terminator" do
    @parser.feed("\e]66;s=2;B\e\\")
    cell = @screen.grid[0][0]
    assert_equal("B", cell.char)
    assert_equal(2, cell.multicell[:scale])
  end

  test "OSC 66 with alignment" do
    @parser.feed("\e]66;s=2:v=2:h=1;X\x07")
    mc = @screen.grid[0][0].multicell
    assert_equal(2, mc[:valign])
    assert_equal(1, mc[:halign])
  end

  test "OSC 66 multicell with multibyte UTF-8 text" do
    @parser.feed("\e]66;s=2;\u{3042}\x07")  # あ
    cell = @screen.grid[0][0]
    assert_equal("\u{3042}", cell.char)
    assert_equal(2, cell.multicell[:scale])
  end

  test "OSC 66 multicell with multiple CJK characters" do
    @parser.feed("\e]66;s=2:w=3;\u{3042}\u{3044}\x07")  # あい
    cell = @screen.grid[0][0]
    assert_equal("\u{3042}\u{3044}", cell.char)
  end

  test "OSC 66 with fractional scaling" do
    @parser.feed("\e]66;s=2:n=1:d=4;Y\x07")
    mc = @screen.grid[0][0].multicell
    assert_equal(1, mc[:frac_n])
    assert_equal(4, mc[:frac_d])
  end

  test "DCS sixel sequence creates multicell with sixel data" do
    # ESC P q [sixel] ESC \
    # '~' = all 6 bits set, 1 pixel wide, 6 pixels tall
    @screen.cell_pixel_width = 8.0
    @screen.cell_pixel_height = 8.0
    @parser.feed("\ePq~\e\\")
    cell = @screen.grid[0][0]
    assert_not_nil(cell.multicell)
    assert_true(cell.multicell.is_a?(Hash))
    assert_not_nil(cell.multicell[:sixel])
    assert_equal(1, cell.multicell[:sixel][:width])
    assert_equal(6, cell.multicell[:sixel][:height])
  end

  test "DCS sixel with params" do
    @screen.cell_pixel_width = 8.0
    @screen.cell_pixel_height = 8.0
    @parser.feed("\eP0;1q~\e\\")
    cell = @screen.grid[0][0]
    assert_not_nil(cell.multicell)
    assert_not_nil(cell.multicell[:sixel])
  end

  test "DCS sixel positions cursor after image" do
    @screen.cell_pixel_width = 8.0
    @screen.cell_pixel_height = 8.0
    @parser.feed("\ePq!16~\e\\")
    # 16px wide / 8px cell = 2 cols; 6px tall / 8px cell = 1 row
    # Cursor should be at beginning of next row after image
    assert_equal(0, @screen.cursor.col)
  end

  test "DECCKM ?1h enables application cursor keys" do
    @parser.feed("\e[?1h")
    assert_true(@screen.application_cursor_keys?)
  end

  test "DECCKM ?1l disables application cursor keys" do
    @parser.feed("\e[?1h")
    @parser.feed("\e[?1l")
    assert_false(@screen.application_cursor_keys?)
  end

  test "alt screen ?1049h switches to alt screen and saves cursor" do
    @parser.feed("Hello")
    @parser.feed("\e[2;4H")  # cursor at row 1, col 3
    @parser.feed("\e[?1049h")
    assert_true(@screen.using_alt_screen?)
    assert_equal(0, @screen.cursor.row)
    assert_equal(0, @screen.cursor.col)
    assert_equal("", row_text(0))  # alt screen is blank
  end

  test "alt screen ?1049l restores main screen and cursor" do
    @parser.feed("Hello")
    @parser.feed("\e[2;4H")  # cursor at row 1, col 3
    @parser.feed("\e[?1049h")
    @parser.feed("Alt")
    @parser.feed("\e[?1049l")
    assert_false(@screen.using_alt_screen?)
    assert_equal(1, @screen.cursor.row)
    assert_equal(3, @screen.cursor.col)
    assert_equal("Hello", row_text(0))  # main screen restored
  end

  test "alt screen ?47h/?47l without cursor save/restore" do
    @parser.feed("Main")
    @parser.feed("\e[2;5H")  # cursor at row 1, col 4
    @parser.feed("\e[?47h")
    assert_true(@screen.using_alt_screen?)
    assert_equal("", row_text(0))
    @parser.feed("Alt")
    @parser.feed("\e[?47l")
    assert_false(@screen.using_alt_screen?)
    assert_equal("Main", row_text(0))
  end

  test "alt screen ignores double switch" do
    @parser.feed("Hello")
    @parser.feed("\e[?1049h")
    @parser.feed("Alt1")
    @parser.feed("\e[?1049h")  # second switch should be no-op
    assert_equal("Alt1", row_text(0))  # alt screen preserved
    @parser.feed("\e[?1049l")
    assert_equal("Hello", row_text(0))  # main restored
  end

  test "alt screen has no scrollback" do
    5.times { |i| @parser.feed("Line#{i}\r\n") }
    assert_true(@screen.scrollback.size > 0)
    @parser.feed("\e[?1049h")
    assert_equal(0, @screen.scrollback.size)
    @parser.feed("\e[?1049l")
    assert_true(@screen.scrollback.size > 0)  # main scrollback restored
  end

  test "text after DCS sixel works normally" do
    @screen.cell_pixel_width = 8.0
    @screen.cell_pixel_height = 8.0
    @parser.feed("\ePq~\e\\Hello")
    # After sixel, cursor moves down; "Hello" should appear on subsequent row
    found = false
    @screen.grid.each do |r|
      text = r.map(&:char).join.rstrip
      if text.include?("Hello")
        found = true
        break
      end
    end
    assert_true(found, "Expected 'Hello' to appear in grid after sixel")
  end
end
