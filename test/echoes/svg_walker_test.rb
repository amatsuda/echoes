# frozen_string_literal: true

require "test_helper"
require "echoes/svg_walker"

class Echoes::SvgWalkerTest < Test::Unit::TestCase
  W = Echoes::SvgWalker

  def collect(bytes)
    W.events(bytes).to_a
  end

  # ---- basic events ----

  def test_open_close_pair
    e = collect('<svg></svg>')
    assert_equal [
      [:open,  'svg', {}],
      [:close, 'svg', {}],
    ], e
  end

  def test_self_close
    e = collect('<rect/>')
    assert_equal [[:self_close, 'rect', {}]], e
  end

  def test_self_close_with_attrs
    e = collect(%(<rect x="10" y="20" width="30" height="40"/>))
    assert_equal [
      [:self_close, 'rect', {
        'x' => '10', 'y' => '20', 'width' => '30', 'height' => '40',
      }],
    ], e
  end

  def test_open_with_attrs_then_close
    e = collect(%(<g fill="red"><rect/></g>))
    assert_equal [
      [:open,       'g',    {'fill' => 'red'}],
      [:self_close, 'rect', {}],
      [:close,      'g',    {}],
    ], e
  end

  def test_nested_groups
    e = collect('<g><g><g></g></g></g>')
    assert_equal [
      [:open,  'g', {}], [:open,  'g', {}], [:open,  'g', {}],
      [:close, 'g', {}], [:close, 'g', {}], [:close, 'g', {}],
    ], e
  end

  def test_mixed_quote_styles
    e = collect(%(<g fill="red" stroke='blue'/>))
    assert_equal [[:self_close, 'g', {'fill' => 'red', 'stroke' => 'blue'}]], e
  end

  # ---- skipped constructs ----

  def test_skips_xml_prologue
    e = collect(%(<?xml version="1.0"?><svg/>))
    assert_equal [[:self_close, 'svg', {}]], e
  end

  def test_skips_doctype
    e = collect(%(<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "x.dtd"><svg/>))
    assert_equal [[:self_close, 'svg', {}]], e
  end

  def test_skips_comments
    e = collect('<svg><!-- hi --><rect/></svg>')
    assert_equal [
      [:open,       'svg',  {}],
      [:self_close, 'rect', {}],
      [:close,      'svg',  {}],
    ], e
  end

  def test_skips_cdata
    e = collect('<svg><![CDATA[<garbage>]]><rect/></svg>')
    assert_equal [
      [:open,       'svg',  {}],
      [:self_close, 'rect', {}],
      [:close,      'svg',  {}],
    ], e
  end

  # ---- text between tags is ignored ----

  def test_text_between_tags_is_ignored
    e = collect('<svg> some text <rect/> more text </svg>')
    assert_equal [
      [:open,       'svg',  {}],
      [:self_close, 'rect', {}],
      [:close,      'svg',  {}],
    ], e
  end

  # ---- malformed input stops cleanly ----

  def test_unclosed_tag_stops_walker
    # No matching `>` after <svg
    e = collect('<svg')
    assert_equal [], e
  end

  def test_unclosed_comment_stops_walker
    e = collect('<svg><!-- broken')
    assert_equal [[:open, 'svg', {}]], e
  end

  def test_empty_input
    assert_equal [], collect('')
    assert_equal [], collect(nil)
  end

  # ---- attribute edge cases ----

  def test_attr_with_whitespace_around_equals
    e = collect('<rect x = "10" y = "20"/>')
    assert_equal [[:self_close, 'rect', {'x' => '10', 'y' => '20'}]], e
  end

  def test_namespaced_attr
    e = collect(%(<svg xmlns:xlink="http://www.w3.org/1999/xlink"/>))
    assert_equal [[:self_close, 'svg',
                   {'xmlns:xlink' => 'http://www.w3.org/1999/xlink'}]], e
  end

  def test_hyphenated_attr
    e = collect(%(<path stroke-width="2"/>))
    assert_equal [[:self_close, 'path', {'stroke-width' => '2'}]], e
  end
end
