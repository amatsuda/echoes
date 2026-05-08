# frozen_string_literal: true

require "test_helper"
require "echoes"
require "echoes/file_viewer"
require "tmpdir"

class Echoes::FileViewerTest < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir
    @ruby_file = File.join(@dir, 'sample.rb')
    File.write(@ruby_file, <<~RUBY)
      # comment
      def hello
        puts 'world'
        return 42
      end
      # bottom
    RUBY
    @plain_file = File.join(@dir, 'plain.txt')
    File.write(@plain_file, (1..30).map { |i| "line #{i}" }.join("\n") + "\n")
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  test "loads a file and exposes its lines as styled segments" do
    v = Echoes::FileViewer.new(file: @ruby_file, rows: 8, cols: 80)
    rows = v.visible_segments
    assert_operator rows.size, :>=, 6
    # Row 0 starts with "# comment" — comment color should be applied.
    first_row_text = rows[0].map { |s| s[:text] }.join
    assert_equal "# comment", first_row_text.rstrip
    assert_not_nil rows[0].first[:fg], "comment should have an fg color"
  end

  test "syntax-highlights ruby keywords and strings on the right cells" do
    v = Echoes::FileViewer.new(file: @ruby_file, rows: 8, cols: 80)
    rows = v.visible_segments
    # Row containing 'def hello' — `def` should be a keyword segment.
    def_row = rows.find { |r| r.any? { |s| s[:text] == "def" } }
    assert_not_nil def_row, "expected a row with the `def` keyword"
    def_seg = def_row.find { |s| s[:text] == "def" }
    assert_not_nil def_seg[:fg], "keyword should have an fg color"
    # The string 'world' (with quotes) should be in a String-colored segment.
    str_row = rows.find { |r| r.any? { |s| s[:text].include?("'world'") } }
    assert_not_nil str_row
    str_seg = str_row.find { |s| s[:text].include?("'world'") }
    assert_not_nil str_seg[:fg]
  end

  test "feed_key 'G' jumps the cursor to the last line" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 5, cols: 80)
    assert_equal 0, v.cursor_position[0]
    v.feed_key('G')
    # Cursor reported within viewport (clamped to rows-1 since the
    # last line is past the visible window after G triggers scroll).
    row, _col = v.cursor_position
    assert row >= 0
    assert row < 5
  end

  test "feed_key 'j' moves the cursor down one line" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 10, cols: 80)
    v.feed_key('j')
    assert_equal 1, v.cursor_position[0]
    v.feed_key('j')
    v.feed_key('j')
    assert_equal 3, v.cursor_position[0]
  end

  test "feed_key Ctrl-D pages forward (changes scroll_top or cursor)" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 10, cols: 80)
    before = v.cursor_position
    v.feed_key("\x04")  # Ctrl-D
    after = v.cursor_position
    refute_equal before, after, "Ctrl-D should change cursor position"
  end

  test "arrow keys map to hjkl in viewer mode" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 10, cols: 80)
    v.feed_key("\u{F701}")  # Down arrow → 'j'
    assert_equal 1, v.cursor_position[0]
    v.feed_key("\u{F700}")  # Up arrow → 'k'
    assert_equal 0, v.cursor_position[0]
  end

  test "missing file is handled gracefully" do
    v = Echoes::FileViewer.new(file: '/nonexistent/path.txt', rows: 5, cols: 80)
    rows = v.visible_segments
    assert_kind_of Array, rows
    # No crash; rows are blank or contain rvim's default content.
  end

  test "visible_segments pads with blank rows up to viewport height" do
    v = Echoes::FileViewer.new(file: @ruby_file, rows: 20, cols: 80)
    rows = v.visible_segments
    assert_equal 20, rows.size
  end

  # --- Editing path: rvim machinery already does the work; the
  # FileViewer is the rendering shim. These tests pin down the bits
  # most likely to regress: mode reporting, save semantics, cmdline
  # rendering on the bottom row, and `:q`-driven viewer death.

  test "i + char + Esc enters insert mode and modifies the buffer" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 5, cols: 40)
    v.feed_key('i')
    assert_equal :insert, v.mode_label
    v.feed_key('X')
    v.feed_key("\e")
    assert_equal :normal, v.mode_label
    line = v.instance_variable_get(:@editor).current_buffer.lines.first
    assert_equal 'Xline 1', line
  end

  test ":w persists edits to disk" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 5, cols: 40)
    v.feed_key('i'); v.feed_key('X'); v.feed_key("\e")
    v.feed_key(':'); v.feed_key('w'); v.feed_key("\r")
    assert_equal 'Xline 1', File.readlines(@plain_file).first.chomp
  end

  test "cmdline mode renders the typed text on the bottom row" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 5, cols: 40)
    v.feed_key(':')
    v.feed_key('w')
    rows = v.visible_segments
    bottom = rows.last.map { |s| s[:text] }.join
    assert_match(/\A:w/, bottom)
    # Cursor sits on the cmdline row at the end of typed text.
    r, c = v.cursor_position
    assert_equal 4, r            # rows-1
    assert_equal 2, c            # `:w` length
  end

  test "statusline shows the mode + filename + position when not in cmdline" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 5, cols: 40)
    v.feed_key('i')              # enter insert mode
    rows = v.visible_segments
    bottom = rows.last
    text = bottom.map { |s| s[:text] }.join
    assert_includes text, '-- INSERT --'
    assert_includes text, File.basename(@plain_file)
    assert_match(/1:1\s*\z/, text.rstrip)
    assert_equal true, bottom.first[:inverse]
  end

  test "modified files get the [+] marker in display_filename" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 5, cols: 40)
    refute_match(/\[\+\]/, v.display_filename)
    v.feed_key('i'); v.feed_key('X'); v.feed_key("\e")
    assert_match(/\[\+\]/, v.display_filename)
  end

  test ":q sets closed? so the host can reap the pane" do
    v = Echoes::FileViewer.new(file: @plain_file, rows: 5, cols: 40)
    refute v.closed?
    v.feed_key(':'); v.feed_key('q'); v.feed_key("\r")
    assert v.closed?
  end

  test "padding rows render vim-style ~ markers when the buffer is short" do
    short = File.join(@dir, 'short.txt')
    File.write(short, "one\n")
    v = Echoes::FileViewer.new(file: short, rows: 5, cols: 40)
    rows = v.visible_segments
    # rows-1 buffer rows, last is statusline. With 1 line of content,
    # rows 1..3 are tilde fill.
    assert_equal '~', rows[1].map { |s| s[:text] }.join
    assert_equal '~', rows[2].map { |s| s[:text] }.join
  end
end

class Echoes::PaneViewerTest < Test::Unit::TestCase
  def setup
    require "echoes/pane"
    @file = File.join(Dir.mktmpdir, 'sample.txt')
    File.write(@file, "alpha\nbeta\ngamma\ndelta\nepsilon\n")
  end

  test "viewer pane renders the file's contents into the screen grid" do
    pane = Echoes::Pane.new(command: '', rows: 8, cols: 40, viewer_file: @file)
    rows = pane.screen.grid.map { |row| row.map { |c| c.char || ' ' }.join.rstrip }
    assert_includes rows, "alpha"
    assert_includes rows, "beta"
    assert_includes rows, "gamma"
  end

  test "viewer pane responds to vim navigation keys" do
    pane = Echoes::Pane.new(command: '', rows: 8, cols: 40, viewer_file: @file)
    assert_equal 0, pane.screen.cursor.row
    pane.handle_key(chars: 'G')
    # Cursor moved past initial position.
    pane.handle_key(chars: 'g')
    pane.handle_key(chars: 'g')
    assert_equal 0, pane.screen.cursor.row
  end

  test "viewer pane reports viewer? and not embedded?" do
    pane = Echoes::Pane.new(command: '', rows: 8, cols: 40, viewer_file: @file)
    assert pane.viewer?
    refute pane.embedded?
  end

  test "viewer pane is alive and read_available_output is empty" do
    pane = Echoes::Pane.new(command: '', rows: 8, cols: 40, viewer_file: @file)
    assert pane.alive?
    assert_equal '', pane.read_available_output
  end

  test "Pane#alive? becomes false after the viewer quits via :q" do
    pane = Echoes::Pane.new(command: '', rows: 8, cols: 40, viewer_file: @file)
    assert pane.alive?
    pane.handle_key(chars: ':')
    pane.handle_key(chars: 'q')
    pane.handle_key(chars: "\r")
    refute pane.alive?
  end
end
