# frozen_string_literal: true

require "test_helper"
require "echoes/svg_cg_renderer"

class Echoes::SvgCgRendererTest < Test::Unit::TestCase
  R = Echoes::SvgCgRenderer

  # Sample a single RGBA pixel out of the returned buffer.
  def pixel_at(image, x, y)
    w = image[:width]
    offset = (y * w + x) * 4
    image[:rgba].byteslice(offset, 4).bytes
  end

  # ---- bail criteria ----

  def test_bail_on_text_element
    svg = %(<svg width="10" height="10"><text x="0" y="0">hi</text></svg>)
    assert_nil R.rasterize(svg, width: 10, height: 10)
  end

  def test_bail_on_filter
    svg = %(<svg><filter id="f"/><rect width="10" height="10"/></svg>)
    assert_nil R.rasterize(svg, width: 10, height: 10)
  end

  def test_bail_on_use
    svg = %(<svg><use href="#x"/></svg>)
    assert_nil R.rasterize(svg, width: 10, height: 10)
  end

  def test_bail_on_linear_gradient
    svg = %(<svg><linearGradient/><rect/></svg>)
    assert_nil R.rasterize(svg, width: 10, height: 10)
  end

  def test_bail_on_animate
    svg = %(<svg><rect><animate attributeName="x"/></rect></svg>)
    assert_nil R.rasterize(svg, width: 10, height: 10)
  end

  def test_bail_on_unparseable_path_data
    svg = %(<svg width="10" height="10"><path d="X 0 0 L 1 1"/></svg>)
    assert_nil R.rasterize(svg, width: 10, height: 10)
  end

  # ---- basic renders ----

  def test_renders_red_rect_filling_canvas
    svg = %(<svg width="10" height="10"><rect width="10" height="10" fill="red"/></svg>)
    img = R.rasterize(svg, width: 10, height: 10)
    refute_nil img
    assert_equal 10, img[:width]
    assert_equal 10, img[:height]
    assert_equal 10 * 10 * 4, img[:rgba].bytesize
    # Middle pixel should be roughly opaque red. Premultiplied RGBA,
    # so the channels are r*a, g*a, b*a, a — for solid red (a=1) the
    # red channel is 255.
    r, g, b, a = pixel_at(img, 5, 5)
    assert_in_delta 255, r, 2
    assert_in_delta 0, g, 2
    assert_in_delta 0, b, 2
    assert_in_delta 255, a, 2
  end

  def test_renders_circle
    svg = %(<svg width="20" height="20"><circle cx="10" cy="10" r="9" fill="blue"/></svg>)
    img = R.rasterize(svg, width: 20, height: 20)
    refute_nil img
    # Center pixel of the circle should be blue.
    _, _, b, a = pixel_at(img, 10, 10)
    assert_in_delta 255, b, 4
    assert_in_delta 255, a, 4
    # A pixel well outside the circle's bounding box should be transparent.
    _, _, _, corner_a = pixel_at(img, 0, 0)
    assert_in_delta 0, corner_a, 4
  end

  def test_renders_path
    # Filled square via a path, centered at the canvas.
    svg = %(<svg width="20" height="20"><path d="M5 5 L15 5 L15 15 L5 15 Z" fill="lime"/></svg>)
    img = R.rasterize(svg, width: 20, height: 20)
    refute_nil img
    _, g, _, a = pixel_at(img, 10, 10)
    assert_in_delta 255, g, 4
    assert_in_delta 255, a, 4
    # Outside the path → transparent.
    _, _, _, outside_a = pixel_at(img, 2, 2)
    assert_in_delta 0, outside_a, 4
  end

  # ---- inheritance ----

  def test_fill_inherits_from_group
    svg = %(<svg width="10" height="10"><g fill="red"><rect width="10" height="10"/></g></svg>)
    img = R.rasterize(svg, width: 10, height: 10)
    refute_nil img
    r, _, _, _ = pixel_at(img, 5, 5)
    assert_in_delta 255, r, 2
  end

  def test_element_fill_overrides_group_fill
    svg = %(<svg width="10" height="10"><g fill="red"><rect width="10" height="10" fill="blue"/></g></svg>)
    img = R.rasterize(svg, width: 10, height: 10)
    refute_nil img
    r, _, b, _ = pixel_at(img, 5, 5)
    assert_in_delta 0, r, 2
    assert_in_delta 255, b, 2
  end

  def test_style_overrides_attribute
    svg = %(<svg width="10" height="10"><rect width="10" height="10" fill="red" style="fill:blue"/></svg>)
    img = R.rasterize(svg, width: 10, height: 10)
    refute_nil img
    r, _, b, _ = pixel_at(img, 5, 5)
    assert_in_delta 0, r, 2
    assert_in_delta 255, b, 2
  end

  # ---- viewBox ----

  def test_viewbox_scales_geometry_to_target
    # viewBox is 10×10; target is 100×100. A 10×10 rect should fill
    # the whole 100×100 buffer.
    svg = %(<svg viewBox="0 0 10 10" width="100" height="100"><rect width="10" height="10" fill="white"/></svg>)
    img = R.rasterize(svg, width: 100, height: 100)
    refute_nil img
    _, _, _, a = pixel_at(img, 50, 50)
    assert_in_delta 255, a, 2
    _, _, _, edge_a = pixel_at(img, 99, 99)
    assert_in_delta 255, edge_a, 2
  end

  # ---- transforms ----

  def test_group_transform_translates_children
    # Move a 10×10 rect from (0,0) to (10,10) via group translate.
    svg = %(<svg width="20" height="20"><g transform="translate(10 10)"><rect width="10" height="10" fill="red"/></g></svg>)
    img = R.rasterize(svg, width: 20, height: 20)
    refute_nil img
    # Pixel at (5,5) — original rect position — should be transparent.
    _, _, _, a_origin = pixel_at(img, 5, 5)
    assert_in_delta 0, a_origin, 4
    # Pixel at (15,15) — translated position — should be red.
    r, _, _, a_moved = pixel_at(img, 15, 15)
    assert_in_delta 255, r, 4
    assert_in_delta 255, a_moved, 4
  end

  # ---- input validation ----

  def test_nil_or_empty_returns_nil
    assert_nil R.rasterize(nil, width: 10, height: 10)
    assert_nil R.rasterize('', width: 10, height: 10)
  end

  def test_non_positive_size_returns_nil
    assert_nil R.rasterize('<svg/>', width: 0,  height: 10)
    assert_nil R.rasterize('<svg/>', width: 10, height: -1)
  end

  def test_no_svg_root_returns_nil
    # Walker yields events but there's no root <svg>.
    assert_nil R.rasterize('<div/>', width: 10, height: 10)
  end
end
