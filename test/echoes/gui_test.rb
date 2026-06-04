# frozen_string_literal: true

require "test_helper"
require "shellwords"
require "tmpdir"

class Echoes::GUIFileDropTest < Test::Unit::TestCase
  def create_pasteboard_with_file_urls(*paths)
    pb = ObjC::MSG_PTR_1.call(
      ObjC.cls('NSPasteboard'),
      ObjC.sel('pasteboardWithName:'),
      ObjC.nsstring("com.echoes.test.#{object_id}")
    )

    urls = paths.map do |path|
      ObjC::MSG_PTR_1.call(
        ObjC.cls('NSURL'),
        ObjC.sel('fileURLWithPath:'),
        ObjC.nsstring(path)
      )
    end

    ns_array = ObjC::MSG_PTR.call(ObjC.cls('NSMutableArray'), ObjC.sel('array'))
    urls.each do |url|
      ObjC::MSG_VOID_1.call(ns_array, ObjC.sel('addObject:'), url)
    end

    ObjC::MSG_VOID.call(pb, ObjC.sel('clearContents'))
    ObjC::MSG_PTR_1.call(pb, ObjC.sel('writeObjects:'), ns_array)

    pb
  end

  ObjC = Echoes::ObjC

  test "file_paths_from_pasteboard returns shell-escaped path for a single file" do
    pb = create_pasteboard_with_file_urls("/tmp/hello.txt")
    result = Echoes::GUI.file_paths_from_pasteboard(pb)
    assert_equal("/tmp/hello.txt", result)
  end

  test "file_paths_from_pasteboard escapes spaces in paths" do
    pb = create_pasteboard_with_file_urls("/tmp/my file.txt")
    result = Echoes::GUI.file_paths_from_pasteboard(pb)
    assert_equal("/tmp/my\\ file.txt", result)
  end

  test "file_paths_from_pasteboard joins multiple files with spaces" do
    pb = create_pasteboard_with_file_urls("/tmp/a.txt", "/tmp/b.txt")
    result = Echoes::GUI.file_paths_from_pasteboard(pb)
    assert_equal("/tmp/a.txt /tmp/b.txt", result)
  end

  test "file_paths_from_pasteboard handles multiple files with spaces" do
    pb = create_pasteboard_with_file_urls("/tmp/my file.txt", "/tmp/other file.txt")
    result = Echoes::GUI.file_paths_from_pasteboard(pb)
    assert_equal("/tmp/my\\ file.txt /tmp/other\\ file.txt", result)
  end

  test "file_paths_from_pasteboard returns nil for empty pasteboard" do
    pb = ObjC::MSG_PTR_1.call(
      ObjC.cls('NSPasteboard'),
      ObjC.sel('pasteboardWithName:'),
      ObjC.nsstring("com.echoes.test.empty.#{object_id}")
    )
    ObjC::MSG_VOID.call(pb, ObjC.sel('clearContents'))
    result = Echoes::GUI.file_paths_from_pasteboard(pb)
    assert_nil(result)
  end

  test "file_paths_from_pasteboard escapes special shell characters" do
    pb = create_pasteboard_with_file_urls("/tmp/file(1).txt")
    result = Echoes::GUI.file_paths_from_pasteboard(pb)
    assert_equal("/tmp/file\\(1\\).txt", result)
  end
end

class Echoes::GUIOpenNewWindowTest < Test::Unit::TestCase
  # Regression: pressing cmd+n used to open a blank window with no shell
  # rendering. makeKeyAndOrderFront: on the new window synchronously fires
  # NSWindowDidResignKeyNotification on the previously-key window, whose
  # observer is its NSView. That handler called activate_for_view, which
  # reset @view back to the old window's view mid-construction. The new ws
  # then got registered under the OLD view's pointer, overwriting the
  # existing mapping; the new view was never invalidated, so the window
  # stayed blank.
  test "open_new_window: each new window's view is uniquely registered in @view_to_ws" do
    gui = Echoes::GUI.new(command: '/bin/cat', rows: 24, cols: 80, font_size: 12.0)
    gui.setup_app
    gui.create_fonts
    gui.create_view_class
    gui.send(:open_new_window)
    gui.send(:open_new_window)

    window_states = gui.instance_variable_get(:@window_states)
    view_to_ws = gui.instance_variable_get(:@view_to_ws)

    assert_equal(2, window_states.size, "two open_new_window calls should produce two ws entries")
    assert_equal(2, view_to_ws.size, "two open_new_window calls should produce two view->ws mappings")

    view_ptrs = window_states.map { |ws| ws[:nsview].to_i }
    assert_equal(view_ptrs.size, view_ptrs.uniq.size, "windows must have distinct view pointers")

    window_states.each do |ws|
      assert_equal(ws, view_to_ws[ws[:nsview].to_i],
                   "each ws[:nsview] must map back to the same ws via @view_to_ws")
    end
  ensure
    # Hide windows and reap shell processes so the test doesn't leak PTYs or
    # leave windows on screen.
    if defined?(window_states) && window_states
      window_states.each do |ws|
        ws[:tabs]&.each(&:close)
        if ws[:nswindow]
          Echoes::ObjC::MSG_VOID_1.call(ws[:nswindow], Echoes::ObjC.sel('orderOut:'),
                                         Fiddle::Pointer.new(0)) rescue nil
        end
      end
    end
  end

end

class Echoes::GUICwdFromOsc7UriTest < Test::Unit::TestCase
  test "returns nil for nil or empty input" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri(nil))
    assert_nil(Echoes::GUI.cwd_from_osc7_uri(""))
  end

  test "returns the path for file://localhost/<existing path>" do
    assert_equal("/tmp", Echoes::GUI.cwd_from_osc7_uri("file://localhost/tmp"))
  end

  test "returns the path for file:///<existing path> (empty host)" do
    assert_equal("/tmp", Echoes::GUI.cwd_from_osc7_uri("file:///tmp"))
  end

  test "URL-decodes percent-encoded path components" do
    Dir.mktmpdir("echoes test ") do |dir|
      encoded = "file://localhost" + dir.gsub(' ', '%20')
      assert_equal(dir, Echoes::GUI.cwd_from_osc7_uri(encoded))
    end
  end

  test "returns nil for non-file scheme" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri("http://localhost/tmp"))
  end

  test "returns nil for a remote host" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri("file://other-host.example.com/tmp"))
  end

  test "returns nil for a path that does not exist locally" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri("file:///nonexistent-#{rand(1 << 30)}"))
  end

  test "returns nil for a malformed URI" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri("file://[bad"))
  end
end

class Echoes::GUISelectedTextTest < Test::Unit::TestCase
  # Regression: copying a region that contained an OSC 66 multicell
  # character (or a wide CJK / emoji glyph) used to include a literal
  # space for each continuation cell. Selecting "Text" rendered via
  # OSC 66 produced "T e x t" in the clipboard. Continuation cells
  # have either width == 0 (CJK second-half) or multicell == :cont
  # (OSC 66 follow-up cells); both must be skipped during extraction.
  #
  # Bypass GUI.new (AppKit setup is unstable when multiple GUIs exist
  # in the same process); set up just the state selected_text_from_buffer
  # actually reads — current_tab.screen and @cols.

  StubTab = Struct.new(:screen)

  def make_gui_with_screen(rows: 5, cols: 30)
    screen = Echoes::Screen.new(rows: rows, cols: cols)
    gui = Echoes::GUI.allocate
    gui.instance_variable_set(:@cols, cols)
    gui.instance_variable_set(:@rows, rows)
    gui.instance_variable_set(:@active_tab, 0)
    gui.instance_variable_set(:@tabs, [StubTab.new(screen)])
    [gui, screen]
  end

  def write(screen, row, col, char, **attrs)
    cell = screen.grid[row][col]
    cell.char = char
    attrs.each { |k, v| cell.send("#{k}=", v) }
  end

  test "skips OSC 66 continuation cells (multicell == :cont)" do
    gui, screen = make_gui_with_screen
    write(screen, 0, 0, 'T', multicell: {cols: 2, rows: 1})
    write(screen, 0, 1, ' ', multicell: :cont)
    write(screen, 0, 2, 'e', multicell: {cols: 2, rows: 1})
    write(screen, 0, 3, ' ', multicell: :cont)
    write(screen, 0, 4, 'x', multicell: {cols: 2, rows: 1})
    write(screen, 0, 5, ' ', multicell: :cont)
    write(screen, 0, 6, 't', multicell: {cols: 2, rows: 1})
    write(screen, 0, 7, ' ', multicell: :cont)
    assert_equal "Text", gui.send(:selected_text_from_buffer, 0, 0, 0, 7)
  end

  test "skips wide-char continuation cells (width == 0)" do
    gui, screen = make_gui_with_screen
    write(screen, 0, 0, '漢', width: 2)
    write(screen, 0, 1, ' ', width: 0)
    write(screen, 0, 2, '字', width: 2)
    write(screen, 0, 3, ' ', width: 0)
    assert_equal "漢字", gui.send(:selected_text_from_buffer, 0, 0, 0, 3)
  end

  test "regular single-cell text still extracts unchanged" do
    gui, screen = make_gui_with_screen
    "hello".chars.each_with_index { |c, i| write(screen, 0, i, c) }
    assert_equal "hello", gui.send(:selected_text_from_buffer, 0, 0, 0, 4)
  end
end

class Echoes::GUICaptureFormatTest < Test::Unit::TestCase
  test ".png paths capture as raster PNG" do
    assert_equal :png, Echoes::GUI.capture_format_for('/tmp/snap.png')
  end

  test ".pdf paths capture as vector PDF" do
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap.pdf')
  end

  test "extension dispatch is case-insensitive" do
    assert_equal :png, Echoes::GUI.capture_format_for('/tmp/snap.PNG')
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap.PDF')
  end

  test "unknown or missing extensions default to PDF" do
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap')
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap.jpg')
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap.tiff')
  end
end

class Echoes::GUISearchMatcherTest < Test::Unit::TestCase
  def make_gui(regex: false, case_insensitive: false)
    gui = Echoes::GUI.allocate
    gui.instance_variable_set(:@search_regex_mode, regex)
    gui.instance_variable_set(:@search_case_insensitive, case_insensitive)
    gui
  end

  def find_all(gui, query, text)
    matcher = gui.send(:build_search_matcher, query)
    return nil if matcher.nil?
    hits = []
    pos = 0
    while pos <= text.length && (hit = matcher.call(text, pos))
      idx, len = hit
      break if idx < pos     # regex returned a stale match — done
      hits << [idx, len]
      pos = idx + [len, 1].max
    end
    hits
  end

  test "substring mode case-sensitive finds every occurrence" do
    gui = make_gui
    assert_equal [[0, 3], [12, 3], [25, 3]],
                 find_all(gui, 'foo', 'foo bar baz foo qux quux foo')
  end

  test "substring mode case-sensitive skips wrong-case matches" do
    gui = make_gui
    assert_equal [[0, 3]],
                 find_all(gui, 'foo', 'foo Foo FOO')
  end

  test "case-insensitive substring mode matches all cases" do
    gui = make_gui(case_insensitive: true)
    assert_equal [[0, 3], [4, 3], [8, 3]],
                 find_all(gui, 'foo', 'foo Foo FOO')
  end

  test "regex mode finds pattern matches" do
    gui = make_gui(regex: true)
    assert_equal [[0, 3], [4, 4], [9, 5]],
                 find_all(gui, '\d+', '123 4567 89012 abc')
  end

  test "regex + case-insensitive folds the regex" do
    gui = make_gui(regex: true, case_insensitive: true)
    hits = find_all(gui, 'foo', 'foo Foo FOO')
    assert_equal [[0, 3], [4, 3], [8, 3]], hits
  end

  test "regex mode returns nil for invalid pattern (no crash)" do
    gui = make_gui(regex: true)
    matcher = gui.send(:build_search_matcher, '[unclosed')
    assert_nil matcher
  end

  test "regex mode with a zero-width match still advances" do
    gui = make_gui(regex: true)
    # `\b` is zero-width — the loop must not infinite-loop on it.
    hits = find_all(gui, '\b', 'hello world')
    assert hits.size <= 'hello world'.length + 1
  end
end

class Echoes::GUISelectTabTest < Test::Unit::TestCase
  # Same pattern as the other GUI unit tests — bypass GUI.new (which
  # spins up AppKit menus, windows, etc.) and exercise the pure-state
  # tab-switch logic directly.
  def make_gui(num_tabs:, active: 0)
    gui = Echoes::GUI.allocate
    gui.instance_variable_set(:@tabs, Array.new(num_tabs) { Object.new })
    gui.instance_variable_set(:@active_tab, active)
    gui
  end

  def active(gui)
    gui.instance_variable_get(:@active_tab)
  end

  test "Cmd+N selects tab N-1 by index for 1..8" do
    # Pick a starting active tab that's never the same as the target,
    # so every iteration actually triggers a switch.
    [1, 2, 3, 4, 5, 6, 7, 8].each do |n|
      start = (n % 8)
      gui = make_gui(num_tabs: 8, active: start)
      assert gui.select_tab(n), "Cmd+#{n} (start=#{start}) should switch"
      assert_equal n - 1, active(gui)
    end
  end

  test "Cmd+9 always jumps to the last tab regardless of count" do
    # Sizes >= 2 so "active = 0" and "last tab" are distinct.
    [2, 3, 5, 9, 12].each do |size|
      gui = make_gui(num_tabs: size, active: 0)
      assert gui.select_tab(9), "Cmd+9 (size=#{size}) should change to last"
      assert_equal size - 1, active(gui)
    end
  end

  test "Cmd+N for N > num_tabs is a no-op" do
    gui = make_gui(num_tabs: 3, active: 1)
    refute gui.select_tab(5), "Cmd+5 with 3 tabs must report no change"
    refute gui.select_tab(8), "Cmd+8 with 3 tabs must report no change"
    assert_equal 1, active(gui), "active tab must not move"
  end

  test "Cmd+9 with one tab is a no-op (target equals active)" do
    gui = make_gui(num_tabs: 1, active: 0)
    refute gui.select_tab(9), "single-tab Cmd+9 must report no change"
    assert_equal 0, active(gui)
  end

  test "Cmd+9 with zero tabs is a no-op (target index would be -1)" do
    # @tabs.size == 0 yields target = -1; the bounds check must reject it.
    gui = make_gui(num_tabs: 0, active: 0)
    refute gui.select_tab(9), "Cmd+9 with no tabs must report no change"
  end

  test "selecting the already-active tab is a no-op" do
    gui = make_gui(num_tabs: 5, active: 2)
    refute gui.select_tab(3), "Cmd+3 when tab 3 (index 2) is already active"
    assert_equal 2, active(gui)
  end

  test "Cmd+9 in a 9+ tab window picks the last, not literally the 9th" do
    # Verifies the spec-difference between "tab 9" and "last tab" —
    # Cmd+9 must follow the last-tab convention, so a 12-tab window
    # lands on index 11 (not index 8).
    gui = make_gui(num_tabs: 12, active: 0)
    assert gui.select_tab(9)
    assert_equal 11, active(gui)
  end
end
