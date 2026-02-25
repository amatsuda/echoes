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

  test "cursor next line CSI E" do
    @parser.feed("\e[3;5H")  # row 2, col 4
    @parser.feed("\e[2E")
    assert_equal(4, @screen.cursor.row)
    assert_equal(0, @screen.cursor.col)
  end

  test "cursor prev line CSI F" do
    @parser.feed("\e[4;5H")  # row 3, col 4
    @parser.feed("\e[2F")
    assert_equal(1, @screen.cursor.row)
    assert_equal(0, @screen.cursor.col)
  end

  test "SGR italic" do
    @parser.feed("\e[3mX\e[23mY")
    assert_true(@screen.grid[0][0].italic)
    assert_false(@screen.grid[0][1].italic)
  end

  test "SGR faint" do
    @parser.feed("\e[2mX\e[22mY")
    assert_true(@screen.grid[0][0].faint)
    assert_false(@screen.grid[0][1].faint)
  end

  test "SGR strikethrough" do
    @parser.feed("\e[9mX\e[29mY")
    assert_true(@screen.grid[0][0].strikethrough)
    assert_false(@screen.grid[0][1].strikethrough)
  end

  test "SGR 22 resets both bold and faint" do
    @parser.feed("\e[1;2mX\e[22mY")
    x = @screen.grid[0][0]
    y = @screen.grid[0][1]
    assert_true(x.bold)
    assert_true(x.faint)
    assert_false(y.bold)
    assert_false(y.faint)
  end

  test "insert mode CSI 4h pushes chars right" do
    @parser.feed("ABCDE")
    @parser.feed("\e[1;3H")  # cursor at col 2
    @parser.feed("\e[4h")     # enable insert mode
    @parser.feed("XY")
    assert_equal("ABXYCDE", row_text(0))
  end

  test "insert mode CSI 4l disables" do
    @parser.feed("\e[4h")
    @parser.feed("\e[4l")
    @parser.feed("ABCDE")
    @parser.feed("\e[1;3H")
    @parser.feed("X")
    assert_equal("ABXDE", row_text(0))  # overwrites, not inserts
  end

  test "origin mode ?6h makes CUP relative to scroll region" do
    @parser.feed("\e[2;4r")   # scroll region rows 2-4 (1-indexed)
    @parser.feed("\e[?6h")    # enable origin mode, cursor goes to scroll top
    assert_equal(1, @screen.cursor.row)  # scroll_top = row 1
    @parser.feed("\e[2;1H")   # CUP row 2 in origin = absolute row 2
    assert_equal(2, @screen.cursor.row)
  end

  test "origin mode ?6h clamps cursor to scroll region" do
    @parser.feed("\e[2;4r")
    @parser.feed("\e[?6h")
    @parser.feed("\e[10;1H")  # row 10 exceeds scroll region
    assert_equal(3, @screen.cursor.row)  # clamped to scroll_bottom
  end

  test "origin mode ?6l disables" do
    @parser.feed("\e[2;4r")
    @parser.feed("\e[?6h")
    @parser.feed("\e[?6l")
    assert_false(@screen.origin_mode?)
    @parser.feed("\e[1;1H")
    assert_equal(0, @screen.cursor.row)  # absolute again
  end

  test "mouse tracking ?1000h enables normal mode" do
    @parser.feed("\e[?1000h")
    assert_equal(:normal, @screen.mouse_tracking)
  end

  test "mouse tracking ?1000l disables" do
    @parser.feed("\e[?1000h")
    @parser.feed("\e[?1000l")
    assert_equal(:off, @screen.mouse_tracking)
  end

  test "mouse SGR encoding ?1006h enables" do
    @parser.feed("\e[?1006h")
    assert_equal(:sgr, @screen.mouse_encoding)
  end

  test "mouse tracking modes" do
    @parser.feed("\e[?9h")
    assert_equal(:x10, @screen.mouse_tracking)
    @parser.feed("\e[?1002h")
    assert_equal(:button_event, @screen.mouse_tracking)
    @parser.feed("\e[?1003h")
    assert_equal(:any_event, @screen.mouse_tracking)
  end

  test "auto-wrap disabled prevents line wrap" do
    @parser.feed("\e[?7l")
    @parser.feed("ABCDEFGHIJKLM")  # 13 chars on 10-col screen
    assert_equal(0, @screen.cursor.row)  # stayed on row 0
    assert_equal(9, @screen.cursor.col)  # clamped to last col
    assert_equal("ABCDEFGHIM", row_text(0))  # last char overwrites at col 9
  end

  test "auto-wrap re-enabled resumes wrapping" do
    @parser.feed("\e[?7l")
    @parser.feed("\e[?7h")
    @parser.feed("ABCDEFGHIJK")  # 11 chars wraps on 10-col screen
    assert_equal(1, @screen.cursor.row)
    assert_equal("K", row_text(1))
  end

  test "insert characters CSI @" do
    @parser.feed("ABCDE")
    @parser.feed("\e[1;3H")  # cursor at col 2
    @parser.feed("\e[2@")     # insert 2 blanks
    assert_equal("AB  CDE", row_text(0))
    assert_equal(2, @screen.cursor.col)  # cursor doesn't move
  end

  test "erase characters CSI X" do
    @parser.feed("ABCDE")
    @parser.feed("\e[1;2H")  # cursor at col 1
    @parser.feed("\e[3X")     # erase 3 chars
    assert_equal("A   E", row_text(0))
    assert_equal(1, @screen.cursor.col)  # cursor doesn't move
  end

  test "OSC 0 sets screen title" do
    @parser.feed("\e]0;my title\x07")
    assert_equal("my title", @screen.title)
  end

  test "OSC 2 sets screen title" do
    @parser.feed("\e]2;window title\x07")
    assert_equal("window title", @screen.title)
  end

  test "OSC 0 with ESC ST terminator" do
    @parser.feed("\e]0;test title\e\\")
    assert_equal("test title", @screen.title)
  end

  test "SGR 24-bit true color foreground" do
    @parser.feed("\e[38;2;255;128;0mX")
    cell = @screen.grid[0][0]
    assert_equal([255, 128, 0], cell.fg)
  end

  test "SGR 24-bit true color background" do
    @parser.feed("\e[48;2;0;128;255mX")
    cell = @screen.grid[0][0]
    assert_equal([0, 128, 255], cell.bg)
  end

  test "SGR 24-bit true color fg and bg combined" do
    @parser.feed("\e[38;2;255;0;0;48;2;0;0;255mX")
    cell = @screen.grid[0][0]
    assert_equal([255, 0, 0], cell.fg)
    assert_equal([0, 0, 255], cell.bg)
  end

  test "SGR 24-bit true color reset by SGR 0" do
    @parser.feed("\e[38;2;255;0;0mA\e[0mB")
    a = @screen.grid[0][0]
    b = @screen.grid[0][1]
    assert_equal([255, 0, 0], a.fg)
    assert_nil(b.fg)
  end

  test "DA1 CSI c responds with device attributes" do
    responses = []
    parser = Echoes::Parser.new(@screen, writer: ->(s) { responses << s })
    parser.feed("\e[c")
    assert_equal(["\e[?62;22c"], responses)
  end

  test "DA1 CSI 0c responds with device attributes" do
    responses = []
    parser = Echoes::Parser.new(@screen, writer: ->(s) { responses << s })
    parser.feed("\e[0c")
    assert_equal(["\e[?62;22c"], responses)
  end

  test "DSR CSI 6n responds with cursor position report" do
    responses = []
    parser = Echoes::Parser.new(@screen, writer: ->(s) { responses << s })
    parser.feed("\e[3;5H")  # cursor at row 2, col 4
    parser.feed("\e[6n")
    assert_equal(["\e[3;5R"], responses)
  end

  test "DSR CSI 5n responds with device OK" do
    responses = []
    parser = Echoes::Parser.new(@screen, writer: ->(s) { responses << s })
    parser.feed("\e[5n")
    assert_equal(["\e[0n"], responses)
  end

  test "DSR CSI 6n without writer does not crash" do
    @parser.feed("\e[6n")  # default parser has no writer
    # Should not raise
  end

  test "bracketed paste mode ?2004h enables" do
    @parser.feed("\e[?2004h")
    assert_true(@screen.bracketed_paste_mode?)
  end

  test "bracketed paste mode ?2004l disables" do
    @parser.feed("\e[?2004h")
    @parser.feed("\e[?2004l")
    assert_false(@screen.bracketed_paste_mode?)
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

  test "soft reset CSI ! p resets modes but preserves screen" do
    @parser.feed("Hello")
    @parser.feed("\e[?1h")   # DECCKM on
    @parser.feed("\e[?7l")   # auto-wrap off
    @parser.feed("\e[4h")    # insert mode on
    @parser.feed("\e[?25l")  # hide cursor
    @parser.feed("\e[2;4r")  # scroll region
    @parser.feed("\e[!p")    # soft reset
    assert_false(@screen.application_cursor_keys?)
    assert_true(@screen.auto_wrap?)
    assert_false(@screen.insert_mode)
    assert_true(@screen.cursor.visible)
    assert_equal("Hello", row_text(0))  # screen content preserved
  end

  test "soft reset preserves cursor position" do
    @parser.feed("\e[3;5H")
    @parser.feed("\e[!p")
    assert_equal(2, @screen.cursor.row)
    assert_equal(4, @screen.cursor.col)
  end

  test "HTS ESC H sets tab stop at current column" do
    @parser.feed("\e[1;5H")  # cursor at col 4
    @parser.feed("\eH")       # set tab stop
    @parser.feed("\e[1;1H")  # cursor at col 0
    @parser.feed("\t")        # should tab to col 4
    assert_equal(4, @screen.cursor.col)
  end

  test "TBC CSI 0g clears tab stop at current column" do
    @parser.feed("\e[1;9H")  # cursor at col 8 (default tab stop)
    @parser.feed("\e[0g")     # clear tab stop at col 8
    @parser.feed("\e[1;1H")  # back to col 0
    @parser.feed("\t")        # should skip to col 16 (next default stop) or 9 (col limit)
    assert_not_equal(8, @screen.cursor.col)
  end

  test "TBC CSI 3g clears all tab stops" do
    @parser.feed("\e[3g")     # clear all tab stops
    @parser.feed("\t")        # no stops, go to end of line
    assert_equal(9, @screen.cursor.col)  # last col (10-col screen)
  end

  test "ESC ( 0 activates DEC Special Graphics for G0" do
    @parser.feed("\e(0")
    @parser.feed("lqqk")  # ┌──┐ in DEC Special
    assert_equal("\u{250C}\u{2500}\u{2500}\u{2510}", row_text(0))
  end

  test "ESC ( B restores ASCII for G0" do
    @parser.feed("\e(0")
    @parser.feed("q")     # horizontal line
    @parser.feed("\e(B")
    @parser.feed("q")     # now ASCII 'q'
    assert_equal("\u{2500}q", row_text(0))
  end

  test "SO/SI switches between G0 and G1" do
    @parser.feed("\e)0")   # designate DEC Special to G1
    @parser.feed("\x0E")   # SO: activate G1
    @parser.feed("q")      # should be ─
    @parser.feed("\x0F")   # SI: activate G0
    @parser.feed("q")      # should be ASCII q
    assert_equal("\u{2500}q", row_text(0))
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
