# frozen_string_literal: true

require "test_helper"

class Echoes::ObjCTest < Test::Unit::TestCase
  test "to_ruby_string returns UTF-8 encoding" do
    ns = Echoes::ObjC.nsstring("hello")
    str = Echoes::ObjC.to_ruby_string(ns)
    assert_equal(Encoding::UTF_8, str.encoding)
    assert_equal("hello", str)
  end

  test "to_ruby_string round-trips multibyte characters" do
    ns = Echoes::ObjC.nsstring("日本語")
    str = Echoes::ObjC.to_ruby_string(ns)
    assert_equal("日本語", str)
    assert_equal(Encoding::UTF_8, str.encoding)
  end

  test "to_ruby_string round-trips special key codepoints" do
    # Arrow keys use Private Use Area codepoints (U+F700-U+F703)
    # These are multi-byte UTF-8 sequences that failed comparison
    # when to_ruby_string returned ASCII-8BIT encoding
    {
      "\u{F700}" => "Up",
      "\u{F701}" => "Down",
      "\u{F702}" => "Left",
      "\u{F703}" => "Right",
    }.each do |key, name|
      ns = Echoes::ObjC.nsstring(key)
      str = Echoes::ObjC.to_ruby_string(ns)
      assert_equal(key, str, "#{name} arrow key round-trip failed")
    end
  end

  test "to_ruby_string result can be matched in case/when" do
    ns = Echoes::ObjC.nsstring("\u{F700}")
    str = Echoes::ObjC.to_ruby_string(ns)
    matched = case str
              when "\u{F700}" then :up
              when "\u{F701}" then :down
              else :unknown
              end
    assert_equal(:up, matched)
  end

  test "nsstring creates valid NSString" do
    ns = Echoes::ObjC.nsstring("test")
    assert_false(ns.null?)
  end
end
