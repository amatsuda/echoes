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
