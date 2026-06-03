# frozen_string_literal: true

require "test_helper"
require "echoes/svg_sniffer"

class Echoes::SvgSnifferTest < Test::Unit::TestCase
  S = Echoes::SvgSniffer

  # ---- svg? ---------------------------------------------------------

  def test_svg_bare_root_element
    assert S.svg?("<svg></svg>")
    assert S.svg?(%(<svg xmlns="http://www.w3.org/2000/svg"/>))
  end

  def test_svg_with_xml_prologue
    assert S.svg?(%(<?xml version="1.0"?><svg/>))
    assert S.svg?(%(<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n<svg/>))
  end

  def test_svg_with_doctype
    assert S.svg?(<<~SVG)
      <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
      <svg/>
    SVG
  end

  def test_svg_with_xml_prologue_and_doctype
    assert S.svg?(%(<?xml version="1.0"?>\n<!DOCTYPE svg>\n<svg/>))
  end

  def test_svg_with_utf8_bom
    assert S.svg?("\xEF\xBB\xBF<svg/>".b)
  end

  def test_svg_with_leading_whitespace
    assert S.svg?("   \n\t<svg/>")
  end

  def test_svg_case_insensitive
    assert S.svg?("<SVG></SVG>")
    assert S.svg?("<Svg/>")
  end

  def test_not_svg_png_magic
    assert_false S.svg?("\x89PNG\r\n\x1A\n".b)
  end

  def test_not_svg_html
    assert_false S.svg?("<!DOCTYPE html><html><body><svg/></body></html>")
  end

  def test_not_svg_json
    assert_false S.svg?('{"svg": true}')
  end

  def test_not_svg_plain_text
    assert_false S.svg?("hello world")
  end

  def test_not_svg_empty
    assert_false S.svg?("")
    assert_false S.svg?(nil)
  end

  # The sniffer only inspects the first 4 KiB. A payload that buries
  # the <svg> tag past that window is treated as non-SVG (an attacker
  # can't smuggle huge JS chunks before our SVG and expect us to render).
  def test_not_svg_when_tag_past_4kb
    junk = "<!-- #{'x' * 4100} -->"
    assert_false S.svg?(junk + "<svg/>")
  end

  # ---- intrinsic_size ----------------------------------------------

  def test_intrinsic_size_width_height_unitless
    assert_equal [100, 50], S.intrinsic_size(%(<svg width="100" height="50"/>))
  end

  def test_intrinsic_size_px_suffix
    assert_equal [200, 150], S.intrinsic_size(%(<svg width="200px" height="150px"/>))
  end

  def test_intrinsic_size_pt_suffix_treated_as_pixels
    assert_equal [12, 18], S.intrinsic_size(%(<svg width="12pt" height="18pt"/>))
  end

  def test_intrinsic_size_single_quoted_attrs
    assert_equal [40, 30], S.intrinsic_size(%(<svg width='40' height='30'/>))
  end

  def test_intrinsic_size_decimal_values
    assert_equal [10, 21], S.intrinsic_size(%(<svg width="10.4" height="20.6"/>))
  end

  def test_intrinsic_size_viewbox_fallback
    assert_equal [400, 300], S.intrinsic_size(%(<svg viewBox="0 0 400 300"/>))
  end

  def test_intrinsic_size_viewbox_comma_separated
    assert_equal [400, 300], S.intrinsic_size(%(<svg viewBox="0,0,400,300"/>))
  end

  def test_intrinsic_size_width_present_height_from_viewbox
    # Mixed: width attr wins for w, viewBox supplies missing h.
    # We do not rescale the viewBox height proportionally — the caller
    # decides whether to enforce aspect ratio.
    assert_equal [80, 300], S.intrinsic_size(%(<svg width="80" viewBox="0 0 400 300"/>))
  end

  def test_intrinsic_size_em_unit_returns_nil
    # em needs layout context we don't have; skip rather than guess.
    assert_nil S.intrinsic_size(%(<svg width="2em" height="2em"/>))
  end

  def test_intrinsic_size_percent_returns_nil
    assert_nil S.intrinsic_size(%(<svg width="100%" height="100%"/>))
  end

  def test_intrinsic_size_missing_returns_nil
    assert_nil S.intrinsic_size("<svg/>")
  end

  def test_intrinsic_size_non_svg_returns_nil
    assert_nil S.intrinsic_size("hello world")
    assert_nil S.intrinsic_size("")
    assert_nil S.intrinsic_size(nil)
  end

  def test_intrinsic_size_caps_search_at_4kb
    # Pathological input: <svg ...> opens far past the sniff window.
    big = "<!-- #{'x' * 5000} -->" + %(<svg width="10" height="10"/>)
    assert_nil S.intrinsic_size(big)
  end
end
