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

  test "put_char sets pending wrap at end of line" do
    10.times { |i| @screen.put_char(("A".ord + i).chr) }
    assert_equal(0, @screen.cursor.row)
    assert_equal(9, @screen.cursor.col)  # stays at last col
    assert_true(@screen.pending_wrap)

    # Next char triggers deferred wrap
    @screen.put_char("Z")
    assert_equal(1, @screen.cursor.row)
    assert_equal(1, @screen.cursor.col)
    assert_equal("Z", @screen.grid[1][0].char)
    assert_false(@screen.pending_wrap)
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

  test "move_cursor_up stops at scroll_top when inside scroll region" do
    @screen = Echoes::Screen.new(rows: 10, cols: 10)
    @screen.set_scroll_region(2, 7)
    @screen.cursor.row = 4
    @screen.move_cursor_up(10)
    assert_equal(2, @screen.cursor.row)
  end

  test "move_cursor_up ignores scroll_top when above scroll region" do
    @screen = Echoes::Screen.new(rows: 10, cols: 10)
    @screen.set_scroll_region(2, 7)
    @screen.cursor.row = 1
    @screen.move_cursor_up(10)
    assert_equal(0, @screen.cursor.row)
  end

  test "move_cursor_down stops at scroll_bottom when inside scroll region" do
    @screen = Echoes::Screen.new(rows: 10, cols: 10)
    @screen.set_scroll_region(2, 7)
    @screen.cursor.row = 4
    @screen.move_cursor_down(10)
    assert_equal(7, @screen.cursor.row)
  end

  test "move_cursor_down ignores scroll_bottom when below scroll region" do
    @screen = Echoes::Screen.new(rows: 10, cols: 10)
    @screen.set_scroll_region(2, 5)
    @screen.cursor.row = 7
    @screen.move_cursor_down(10)
    assert_equal(9, @screen.cursor.row)
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

  test "put_multicell stores flip_h / flip_v on the multicell anchor" do
    @screen.put_multicell("A", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                         valign: 0, halign: 0, flip_h: true, flip_v: false)
    mc = @screen.grid[0][0].multicell
    assert_equal true,  mc[:flip_h]
    assert_equal false, mc[:flip_v]
  end

  test "put_multicell defaults flip_h / flip_v to false when not requested" do
    @screen.put_multicell("A", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                         valign: 0, halign: 0)
    mc = @screen.grid[0][0].multicell
    assert_equal false, mc[:flip_h]
    assert_equal false, mc[:flip_v]
  end

  test "put_multicell anchor captures the current paint alpha" do
    # The OSC 7772 cell-alpha path needs the multicell anchor cell to
    # carry @attrs.alpha so the GUI's multicell draw can apply it to
    # the fg colour. Without this, OSC 66 paragraphs (the dominant
    # body-text emit path) bypass the fade entirely.
    @screen.set_paint_alpha(0.4)
    @screen.put_multicell("A", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                         valign: 0, halign: 0)
    assert_in_delta 0.4, @screen.grid[0][0].alpha
  end

  sub_test_case "partial-erase on adjacent-row multicell placements" do
    setup do
      @screen = Echoes::Screen.new(rows: 5, cols: 20)
      @screen.cell_pixel_width = 12.0
      # Stub the host measurer so the family-set-halign-0 branch
      # treats this string as a whole-string proportional anchor
      # (the case the bug occurs on).
      @screen.glyph_measurer = ->(text, _f, scale, _fn, _fd) { text.length * 12.0 * scale }
    end

    test "lower multicell only claims its own cells; upper anchor stays alive" do
      # Upper: whole-string anchor at (0, 0), 8 chars × scale 2 = 16
      # cols × 2 rows. Conts span (0, 1..15) and (1, 0..15).
      @screen.move_cursor(0, 0)
      @screen.put_multicell("12345678", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                            valign: 0, halign: 0, family: "Helvetica")
      # Lower: 3 chars at (1, 0), 6 cols × 2 rows.
      @screen.move_cursor(1, 0)
      @screen.put_multicell("abc", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                            valign: 0, halign: 0, family: "Helvetica")

      upper = @screen.grid[0][0]
      assert_kind_of(Hash, upper.multicell,
                     "upper anchor must survive a partial overlap on its cont row")
      assert_equal("12345678", upper.char)
      assert_equal(16, upper.multicell[:cols])

      lower = @screen.grid[1][0]
      assert_kind_of(Hash, lower.multicell)
      assert_equal("abc", lower.char)
      assert_equal(6, lower.multicell[:cols])

      # Cells the lower anchor genuinely claimed are :cont of the
      # lower placement (it owns row 1 cols 0..5).
      (1..5).each do |col|
        assert_equal(:cont, @screen.grid[1][col].multicell,
                     "row 1 col #{col} should belong to the lower placement")
      end
      # Cells beyond the lower's reach stay :cont of the upper anchor's
      # original rect — its drawAtPoint still paints those pixels.
      (6..15).each do |col|
        assert_equal(:cont, @screen.grid[1][col].multicell,
                     "row 1 col #{col} should still be :cont of the upper anchor")
      end
    end

    test "same-row placement fully erases the prior multicell (full-erase branch)" do
      @screen.move_cursor(0, 0)
      @screen.put_multicell("12345678", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                            valign: 0, halign: 0, family: "Helvetica")
      # Second placement at the same row but offset by 4 cols. Its rect
      # covers cells (0, 4..9) which include the upper's :cont cells on
      # the SAME row as the upper anchor (row 0). Same-row → full erase.
      @screen.move_cursor(0, 4)
      @screen.put_multicell("xy", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                            valign: 0, halign: 0, family: "Helvetica")

      assert_nil(@screen.grid[0][0].multicell,
                 "the upper anchor cell should be fully erased — same-row replacement")
      # The new anchor is what's left at (0, 4).
      assert_kind_of(Hash, @screen.grid[0][4].multicell)
      assert_equal("xy", @screen.grid[0][4].char)
    end

    test "put_char into a continuation still full-erases (no regression for the SGR-write path)" do
      # Establish a wide multicell anchor.
      @screen.move_cursor(0, 0)
      @screen.put_multicell("12345678", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                            valign: 0, halign: 0, family: "Helvetica")
      # Now write a plain char into one of its :cont cells via put_char.
      # put_char calls erase_multicell_at WITHOUT `partial:`, so the
      # full-erase branch should fire — the whole upper string is
      # replaced by the new single character (today's behaviour, kept).
      @screen.move_cursor(0, 5)
      @screen.put_char("X")

      # The upper anchor's hash must be gone.
      assert_nil(@screen.grid[0][0].multicell,
                 "put_char into a cont must trigger full erase of the upper multicell")
      assert_equal("X", @screen.grid[0][5].char)
    end
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

  test "put_multicell with family but no halign reserves cell-grid columns, ignoring measure" do
    # Even with a family + glyph_measurer wired, the halign-not-set
    # branch lays out at `scale × source_chars` — the same cell-grid
    # count the auto-width branch produces. The host's font measure
    # varies by font (CJK fallback advance, space-advance ≠ M-advance,
    # …) and using it directly made code-block bg blocks
    # non-rectangular: lines with CJK measured wider than pure-Latin
    # lines of the same display_width. Cell-grid keeps the bg
    # rectangular and matches the renderer's display_width pad math.
    # Body-text paths that need proportional cells set halign instead
    # (see the halign != 0 branch).
    @screen.cell_pixel_width = 8.0
    @screen.glyph_measurer = ->(text, _family, _scale, _frac_n, _frac_d) { text.length * 12.0 }

    @screen.put_multicell("Hello", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                          valign: 0, halign: 0, family: "Noto Serif")

    anchor = @screen.grid[0][0]
    assert_equal("Hello", anchor.char, "anchor stores the whole string, not per-grapheme")
    assert_equal(10, anchor.multicell[:cols])
    assert_equal(2,  anchor.multicell[:rows])
    assert_equal("Noto Serif", anchor.multicell[:family])
    assert_equal(:cont, @screen.grid[0][1].multicell)
    assert_equal(:cont, @screen.grid[0][9].multicell)
    assert_equal(10, @screen.cursor.col)
  end

  test "put_multicell with family but no glyph_measurer falls back to per-grapheme" do
    # Without a measurer, the proportional path can't run; we keep
    # the legacy monospace cell-reservation per grapheme.
    @screen.put_multicell("AB", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                          valign: 0, halign: 0, family: "Noto Serif")
    assert_equal("A", @screen.grid[0][0].char)
    assert_equal("B", @screen.grid[0][2].char)
    assert_equal(4, @screen.cursor.col)
  end

  test "put_multicell with halign != 0 lays the whole string out as one block" do
    @screen = Echoes::Screen.new(rows: 5, cols: 20)
    @screen.put_multicell("Hi", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                          valign: 0, halign: 2)
    anchor = @screen.grid[0][0]
    # source_chars = 2 ("Hi"), scale = 2 → block 4 cells wide.
    # Without halign this would be two 2-cell blocks; with halign=2
    # the whole string is one block so the renderer has 4 cells of
    # space to center the glyphs in.
    assert_equal("Hi", anchor.char)
    assert_equal(4, anchor.multicell[:cols])
    assert_equal(2, anchor.multicell[:halign])
    assert_equal(:cont, @screen.grid[0][1].multicell)
    assert_equal(:cont, @screen.grid[0][2].multicell)
    assert_equal(:cont, @screen.grid[0][3].multicell)
    assert_equal(4, @screen.cursor.col)
  end

  test "put_multicell with halign + proportional widens block to fit measured glyphs" do
    @screen = Echoes::Screen.new(rows: 5, cols: 30)
    @screen.cell_pixel_width = 8.0
    # Stub: each char measures 30px (wider than 2 cells at scale=2,
    # which would be 16px). source_chars=5 → 5*2=10 cells; measured
    # width = 5*30 = 150px → ceil(150/8) = 19 cells. Block must be
    # max(10, 19) = 19 so the proportional glyphs fit.
    @screen.glyph_measurer = ->(text, _f, _s, _, _) { text.length * 30.0 }

    @screen.put_multicell("Hello", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                          valign: 0, halign: 2, family: "BigFont")
    anchor = @screen.grid[0][0]
    assert_equal("Hello", anchor.char)
    assert_equal(19, anchor.multicell[:cols])
  end

  test "put_multicell with halign + proportional uses s × source_chars when that's wider" do
    @screen = Echoes::Screen.new(rows: 5, cols: 30)
    @screen.cell_pixel_width = 8.0
    # Stub: each char measures only 8px (1 cell). source_chars=5 →
    # s × source_chars = 5*2 = 10 cells; measured = 5*8 = 40px → 5
    # cells. max(10, 5) = 10. Block stays at 10 cells so the
    # narrow glyphs are centered with margins on both sides.
    @screen.glyph_measurer = ->(text, _f, _s, _, _) { text.length * 8.0 }

    @screen.put_multicell("Hello", scale: 2, width: 0, frac_n: 0, frac_d: 0,
                          valign: 0, halign: 2, family: "TightFont")
    anchor = @screen.grid[0][0]
    assert_equal(10, anchor.multicell[:cols])
  end

  # --- put_kitty_image (Kitty graphics protocol → multicell anchor) ---

  test "put_kitty_image reserves a multicell anchor and records a placement" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    rgba = "\xFF".b * (40 * 60 * 4)  # 40×60 px image, junk RGBA
    @screen.put_kitty_image(rgba: rgba, width: 40, height: 60)
    anchor = @screen.grid[0][0]
    # 40px / 10px = 4 cell cols; 60px / 20px = 3 cell rows.
    assert_equal 4, anchor.multicell[:cols]
    assert_equal 3, anchor.multicell[:rows]
    assert_equal :cont, @screen.grid[0][1].multicell
    assert_equal :cont, @screen.grid[2][3].multicell
    # The bitmap itself now lives on screen.placements, not in
    # the cell — the GUI's re-blit pass draws it on top of cells.
    pl = @screen.placements.first
    assert_equal 40, pl[:image][:width]
    assert_equal 60, pl[:image][:height]
  end

  test "put_kitty_image cells_w/cells_h override natural pixel sizing" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    rgba = "\x00".b * (40 * 60 * 4)
    @screen.put_kitty_image(rgba: rgba, width: 40, height: 60,
                            cells_w: 6, cells_h: 2)
    anchor = @screen.grid[0][0]
    assert_equal 6, anchor.multicell[:cols]
    assert_equal 2, anchor.multicell[:rows]
  end

  test "put_kitty_image advances cursor to the row after the image" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    rgba = "\x00".b * (20 * 40 * 4)
    @screen.put_kitty_image(rgba: rgba, width: 20, height: 40)
    # Image is 2x2 cells starting at (0,0); cursor lands at (2, 0).
    assert_equal 2, @screen.cursor.row
    assert_equal 0, @screen.cursor.col
  end

  test "put_kitty_image with suppress_cursor leaves the cursor where it was" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    @screen.cursor.row = 4
    @screen.cursor.col = 5
    rgba = "\x00".b * (20 * 40 * 4)
    @screen.put_kitty_image(rgba: rgba, width: 20, height: 40,
                            suppress_cursor: true)
    assert_equal 4, @screen.cursor.row
    assert_equal 5, @screen.cursor.col
  end

  test "put_kitty_image with suppress_cursor does NOT scroll when image overflows the bottom" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    # Mark row 0 so we can detect if a scroll discarded it.
    @screen.cursor.row = 0
    @screen.cursor.col = 0
    @screen.put_char('A')
    # Now drop a 6-cell-tall image at row 7 — naive math would say
    # 7+6=13 > 10, scroll up 3 rows, dragging 'A' off-screen.
    @screen.cursor.row = 7
    @screen.cursor.col = 0
    rgba = "\x00".b * (30 * 120 * 4)  # 3 cells wide × 6 cells tall
    @screen.put_kitty_image(rgba: rgba, width: 30, height: 120,
                            suppress_cursor: true)
    assert_equal 'A', @screen.grid[0][0].char, "row 0 must survive — no scroll"
    assert_equal 7, @screen.cursor.row, "cursor must not move"
    assert_equal 0, @screen.cursor.col
    # Image IS placed at the cursor; the part that fits gets reserved
    # as multicell, the rest renders via the GUI's blit pass and
    # clips at the pane edge.
    assert_not_nil @screen.grid[7][0].multicell, "image must be placed at the cursor"
    assert_equal 1, @screen.placements.size, "placement must be recorded for the blit pass"
    # Placement entry carries the FULL extent so the GUI draws the
    # unclipped image (overflow pixels fall outside the pane rect).
    assert_equal 6, @screen.placements.first[:cell_rows]
    assert_equal 3, @screen.placements.first[:cell_cols]
  end

  test "put_kitty_image with suppress_cursor only reserves multicell cells inside the grid" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    @screen.cursor.row = 8   # only 2 rows fit before the bottom edge
    @screen.cursor.col = 0
    rgba = "\x00".b * (30 * 120 * 4)  # 3 cells wide × 6 cells tall
    @screen.put_kitty_image(rgba: rgba, width: 30, height: 120,
                            suppress_cursor: true)
    # Rows 8 and 9 are reserved as multicell (anchor + continuations);
    # everything past row 9 doesn't exist in the grid.
    assert_kind_of Hash, @screen.grid[8][0].multicell
    assert_equal :cont,  @screen.grid[9][0].multicell
    assert_equal 2, @screen.grid.size - 8, "grid only has 2 more rows"
  end

  test "put_kitty_image without suppress_cursor still scrolls to fit (slide-mode opt-in only)" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    @screen.cursor.row = 0
    @screen.cursor.col = 0
    @screen.put_char('A')
    @screen.cursor.row = 7
    @screen.cursor.col = 0
    rgba = "\x00".b * (30 * 120 * 4)  # 3 × 6 cells
    @screen.put_kitty_image(rgba: rgba, width: 30, height: 120)
    refute_equal 'A', @screen.grid[0][0].char,
                 "without C=1, the auto-scroll-to-fit should have dragged 'A' off-screen"
  end

  test "put_kitty_image records a placement entry" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    @screen.cursor.row = 2
    @screen.cursor.col = 4
    rgba = "\x00".b * (30 * 60 * 4)  # 3 × 3 cells
    @screen.put_kitty_image(rgba: rgba, width: 30, height: 60,
                            image_id: '42', px_x_offset: 5, px_y_offset: 7,
                            suppress_cursor: true)
    assert_equal 1, @screen.placements.size
    p = @screen.placements.first
    assert_equal '42', p[:image_id]
    assert_equal 2,    p[:anchor_row]
    assert_equal 4,    p[:anchor_col]
    assert_equal 3,    p[:cell_cols]
    assert_equal 3,    p[:cell_rows]
    assert_equal 5,    p[:x_off]
    assert_equal 7,    p[:y_off]
    assert_equal rgba, p[:image][:rgba]
    assert_equal 30,   p[:image][:width]
    assert_equal 60,   p[:image][:height]
    assert_equal 0,    p[:z_index]   # default
  end

  test "put_kitty_image records z_index on the placement entry" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    rgba = "\x00".b * (10 * 20 * 4)
    @screen.put_kitty_image(rgba: rgba, width: 10, height: 20,
                            image_id: 'bg', z_index: -1, suppress_cursor: true)
    assert_equal(-1, @screen.placements.first[:z_index])

    @screen.cursor.col = 5
    @screen.put_kitty_image(rgba: rgba, width: 10, height: 20,
                            image_id: 'fg', z_index: 3, suppress_cursor: true)
    assert_equal 3, @screen.placements.last[:z_index]
  end

  test "scroll_up shifts placement anchor_row and drops fully-offscreen entries" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    @screen.cursor.row = 1
    @screen.cursor.col = 0
    rgba = "\x00".b * (20 * 40 * 4)  # 2 × 2 cells
    @screen.put_kitty_image(rgba: rgba, width: 20, height: 40,
                            image_id: 'A', suppress_cursor: true)
    assert_equal 1, @screen.placements.first[:anchor_row]
    @screen.scroll_up(1)
    assert_equal 0, @screen.placements.first[:anchor_row]
    # Two more rows of scroll → anchor at -2, cell_rows=2, so it
    # fully exits the visible area and should be dropped.
    @screen.scroll_up(2)
    assert_empty @screen.placements
  end

  test "erase_in_display(2) clears the placement list" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    rgba = "\x00".b * (20 * 40 * 4)
    @screen.put_kitty_image(rgba: rgba, width: 20, height: 40,
                            image_id: 'A', suppress_cursor: true)
    assert_equal 1, @screen.placements.size
    @screen.erase_in_display(2)
    assert_empty @screen.placements
  end

  test "reset clears the placement list" do
    @screen = Echoes::Screen.new(rows: 10, cols: 30)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    rgba = "\x00".b * (20 * 40 * 4)
    @screen.put_kitty_image(rgba: rgba, width: 20, height: 40,
                            image_id: 'A', suppress_cursor: true)
    refute_empty @screen.placements
    @screen.reset
    assert_empty @screen.placements
  end

  test "put_kitty_image discards an image that's larger than the screen" do
    @screen = Echoes::Screen.new(rows: 5, cols: 10)
    @screen.cell_pixel_width  = 10.0
    @screen.cell_pixel_height = 20.0
    # 200px wide / 10px-per-cell = 20 cells > 10 col limit.
    rgba = "\x00".b * (200 * 100 * 4)
    @screen.put_kitty_image(rgba: rgba, width: 200, height: 100)
    assert_nil @screen.grid[0][0].multicell
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

  # --- Pending wrap (deferred wrap) ---

  test "pending wrap cleared by cursor movement" do
    10.times { |i| @screen.put_char(("A".ord + i).chr) }
    assert_true(@screen.pending_wrap)

    @screen.move_cursor_backward(1)
    assert_false(@screen.pending_wrap)
    assert_equal(8, @screen.cursor.col)  # moved back from col 9
  end

  test "pending wrap cleared by carriage return" do
    10.times { |i| @screen.put_char(("A".ord + i).chr) }
    assert_true(@screen.pending_wrap)

    @screen.carriage_return
    assert_false(@screen.pending_wrap)
    assert_equal(0, @screen.cursor.col)
    assert_equal(0, @screen.cursor.row)  # no wrap happened
  end

  test "pending wrap cleared by backspace" do
    10.times { |i| @screen.put_char(("A".ord + i).chr) }
    assert_true(@screen.pending_wrap)

    @screen.backspace
    assert_false(@screen.pending_wrap)
    assert_equal(8, @screen.cursor.col)
  end

  test "pending wrap saved and restored with cursor" do
    10.times { |i| @screen.put_char(("A".ord + i).chr) }
    assert_true(@screen.pending_wrap)

    @screen.save_cursor
    @screen.carriage_return  # clears pending_wrap
    assert_false(@screen.pending_wrap)

    @screen.restore_cursor
    assert_true(@screen.pending_wrap)
    assert_equal(9, @screen.cursor.col)
  end

  test "repeat_char repeats the last printed character" do
    @screen = Echoes::Screen.new(rows: 5, cols: 10)
    @screen.put_char('A')
    @screen.repeat_char(3)
    assert_equal('A', @screen.grid[0][0].char)
    assert_equal('A', @screen.grid[0][1].char)
    assert_equal('A', @screen.grid[0][2].char)
    assert_equal('A', @screen.grid[0][3].char)
    assert_equal(4, @screen.cursor.col)
  end

  test "repeat_char does nothing when no character has been printed" do
    @screen = Echoes::Screen.new(rows: 5, cols: 10)
    @screen.repeat_char(3)
    assert_equal(0, @screen.cursor.col)
    assert_equal(' ', @screen.grid[0][0].char)
  end

  test "resize reflows wrapped lines when widening" do
    @screen = Echoes::Screen.new(rows: 5, cols: 5)
    # Write "ABCDEFGH" which wraps at col 5
    "ABCDEFGH".each_char { |c| @screen.put_char(c) }
    assert_equal('A', @screen.grid[0][0].char)
    assert_equal('F', @screen.grid[1][0].char)

    @screen.resize(5, 10)
    # After reflow, "ABCDEFGH" should be on a single row
    assert_equal('A', @screen.grid[0][0].char)
    assert_equal('H', @screen.grid[0][7].char)
    assert_equal(' ', @screen.grid[1][0].char)
  end

  test "resize reflows lines when narrowing" do
    @screen = Echoes::Screen.new(rows: 5, cols: 10)
    "ABCDEFGH".each_char { |c| @screen.put_char(c) }
    assert_equal(0, @screen.cursor.row)

    @screen.resize(5, 4)
    # "ABCDEFGH" rewraps into 2 rows of 4; cursor stays visible
    # First wrapped row may go to scrollback; verify content is preserved
    assert_equal('E', @screen.grid[0][0].char)
    assert_equal('H', @screen.grid[0][3].char)
    # ABCD is in scrollback
    assert_equal('A', @screen.scrollback.last[0].char)
    assert_equal('D', @screen.scrollback.last[3].char)
  end

  test "resize does not reflow hard newlines" do
    @screen = Echoes::Screen.new(rows: 5, cols: 5)
    "AB".each_char { |c| @screen.put_char(c) }
    @screen.carriage_return
    @screen.line_feed
    "CD".each_char { |c| @screen.put_char(c) }

    @screen.resize(5, 10)
    # AB and CD should remain on separate rows (hard newline)
    assert_equal('A', @screen.grid[0][0].char)
    assert_equal('B', @screen.grid[0][1].char)
    assert_equal(' ', @screen.grid[0][2].char)
    assert_equal('C', @screen.grid[1][0].char)
    assert_equal('D', @screen.grid[1][1].char)
  end

  test "combining character merges with preceding cell" do
    @screen = Echoes::Screen.new(rows: 5, cols: 10)
    @screen.put_char('e')
    @screen.put_char("\u{0301}")  # combining acute accent
    assert_equal("e\u{0301}", @screen.grid[0][0].char)
    assert_equal(1, @screen.cursor.col)
  end

  test "multiple combining characters stack on same cell" do
    @screen = Echoes::Screen.new(rows: 5, cols: 10)
    @screen.put_char('o')
    @screen.put_char("\u{0308}")  # combining diaeresis
    @screen.put_char("\u{0301}")  # combining acute accent
    assert_equal("o\u{0308}\u{0301}", @screen.grid[0][0].char)
    assert_equal(1, @screen.cursor.col)
  end

  test "combining character at start of line does not crash" do
    @screen = Echoes::Screen.new(rows: 5, cols: 10)
    @screen.put_char("\u{0301}")  # combining accent with no base
    # Should merge with the space in cell 0
    assert_equal(" \u{0301}", @screen.grid[0][0].char)
    assert_equal(0, @screen.cursor.col)
  end

  test "SGR with no parameters resets attributes" do
    @screen.set_graphics([1])  # bold on
    @screen.put_char('B')
    assert_equal(true, @screen.grid[0][0].bold)

    @screen.set_graphics([nil])  # \e[m — empty param becomes nil
    @screen.put_char('N')
    assert_equal(false, @screen.grid[0][1].bold)
  end

  # --- grid.size == rows invariant (regression: draw_pane_content crash) ---

  test "grid size matches rows after switch to alt screen" do
    @screen.switch_to_alt_screen
    assert_equal(@screen.rows, @screen.grid.size)
  end

  test "grid size matches rows after switch back to main screen" do
    @screen.switch_to_alt_screen
    @screen.switch_to_main_screen
    assert_equal(@screen.rows, @screen.grid.size)
  end

  test "grid size matches rows after resize in alt screen" do
    @screen.switch_to_alt_screen
    @screen.resize(30, 100)
    assert_equal(30, @screen.grid.size)
    assert_equal(@screen.rows, @screen.grid.size)
  end

  test "grid size matches rows after resize then switch to alt screen" do
    @screen.resize(10, 20)
    @screen.switch_to_alt_screen
    assert_equal(10, @screen.grid.size)
    assert_equal(@screen.rows, @screen.grid.size)
  end

  test "grid size matches rows after resize in alt screen then switch back" do
    @screen.switch_to_alt_screen
    @screen.resize(12, 40)
    @screen.switch_to_main_screen
    assert_equal(@screen.rows, @screen.grid.size)
  end

  test "switch to alt screen marks all rows dirty" do
    @screen.clear_dirty
    assert(@screen.dirty_rows.empty?)

    @screen.switch_to_alt_screen
    assert_equal((0...5).to_a.to_set, @screen.dirty_rows)
  end

  test "switch to main screen marks all rows dirty" do
    @screen.switch_to_alt_screen
    @screen.clear_dirty
    assert(@screen.dirty_rows.empty?)

    @screen.switch_to_main_screen
    assert_equal((0...5).to_a.to_set, @screen.dirty_rows)
  end

  # --- put_styled_segments (native prompt rendering) ---

  test "put_styled_segments writes plain text into cells" do
    @screen.put_styled_segments([{text: "hi", fg: nil, bg: nil}])
    assert_equal "h", @screen.grid[0][0].char
    assert_equal "i", @screen.grid[0][1].char
  end

  test "put_styled_segments applies fg/bg/bold/italic/underline/inverse" do
    seg = {text: "X", fg: 1, bg: 2, bold: true, italic: true,
           underline: true, inverse: true}
    @screen.put_styled_segments([seg])
    cell = @screen.grid[0][0]
    assert_equal "X",  cell.char
    assert_equal 1,    cell.fg
    assert_equal 2,    cell.bg
    assert_equal true, cell.bold
    assert_equal true, cell.italic
    assert_equal true, cell.underline
    assert_equal true, cell.inverse
  end

  test "put_styled_segments translates [:rgb, r, g, b] to [r, g, b]" do
    @screen.put_styled_segments([{text: "X", fg: [:rgb, 10, 20, 30], bg: [:rgb, 40, 50, 60]}])
    cell = @screen.grid[0][0]
    assert_equal [10, 20, 30], cell.fg
    assert_equal [40, 50, 60], cell.bg
  end

  test "put_styled_segments restores prior @attrs after writing" do
    # Pre-load some SGR state via the parser path.
    parser = Echoes::Parser.new(@screen)
    parser.feed("\e[31m")  # red fg
    @screen.put_styled_segments([{text: "Y", fg: 4, bold: true}])
    parser.feed("Z")
    assert_equal 4, @screen.grid[0][0].fg
    assert_equal 1, @screen.grid[0][1].fg  # red restored — Z is red
    assert_equal false, @screen.grid[0][1].bold
  end

  test "put_styled_segments handles multiple segments with mixed attrs" do
    segs = [
      {text: "ab",  fg: 1, bold: true},
      {text: "cd",  fg: 2, bold: false},
    ]
    @screen.put_styled_segments(segs)
    assert_equal 1, @screen.grid[0][0].fg
    assert_equal true, @screen.grid[0][0].bold
    assert_equal 2, @screen.grid[0][2].fg
    assert_equal false, @screen.grid[0][2].bold
  end
end
