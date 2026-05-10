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
