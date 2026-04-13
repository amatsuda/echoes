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
