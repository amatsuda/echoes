# frozen_string_literal: true

require "test_helper"
require "echoes/svg_color"

class Echoes::SvgColorTest < Test::Unit::TestCase
  C = Echoes::SvgColor

  def assert_rgba(expected, actual, delta: 0.005)
    assert_equal expected.size, actual.size
    expected.each_with_index do |e, i|
      assert_in_delta e, actual[i], delta, "channel #{i}"
    end
  end

  # ---- keywords ----

  def test_none_returns_symbol
    assert_equal :none, C.parse('none')
    assert_equal :none, C.parse('NONE')
    assert_equal :none, C.parse('  none  ')
  end

  def test_current_color_returns_arg
    assert_rgba [0.5, 0.5, 0.5, 1.0],
                C.parse('currentColor', current_color: [0.5, 0.5, 0.5, 1.0])
  end

  def test_transparent_is_all_zero
    assert_rgba [0.0, 0.0, 0.0, 0.0], C.parse('transparent')
  end

  # ---- hex ----

  def test_hex_3_digit
    # #f00 = #ff0000
    assert_rgba [1.0, 0.0, 0.0, 1.0], C.parse('#f00')
  end

  def test_hex_4_digit_with_alpha
    # #f00f = solid red, alpha 1
    assert_rgba [1.0, 0.0, 0.0, 1.0], C.parse('#f00f')
    # #f008 ≈ red, alpha 0x88/0xff
    assert_rgba [1.0, 0.0, 0.0, 0x88 / 255.0], C.parse('#f008')
  end

  def test_hex_6_digit
    assert_rgba [1.0, 0.5019, 0.0, 1.0], C.parse('#ff8000')
  end

  def test_hex_8_digit_with_alpha
    assert_rgba [1.0, 0.0, 0.0, 0x80 / 255.0], C.parse('#ff000080')
  end

  def test_hex_case_insensitive
    assert_rgba C.parse('#AABBCC'), C.parse('#aabbcc')
  end

  def test_hex_wrong_length_returns_nil
    assert_nil C.parse('#ff')
    assert_nil C.parse('#fffff')
    assert_nil C.parse('#fffffffff')
  end

  # ---- rgb() ----

  def test_rgb_integer_components
    assert_rgba [1.0, 0.0, 0.0, 1.0], C.parse('rgb(255, 0, 0)')
  end

  def test_rgb_percent_components
    assert_rgba [1.0, 0.5, 0.0, 1.0], C.parse('rgb(100%, 50%, 0%)')
  end

  def test_rgba_with_alpha
    assert_rgba [0.0, 0.0, 0.0, 0.5], C.parse('rgba(0, 0, 0, 0.5)')
  end

  def test_rgb_handles_whitespace
    assert_rgba [1.0, 0.0, 0.0, 1.0], C.parse('rgb( 255 , 0 , 0 )')
  end

  def test_rgb_wrong_arity_returns_nil
    assert_nil C.parse('rgb(255, 0)')
    assert_nil C.parse('rgb(255, 0, 0, 0.5, extra)')
  end

  def test_rgb_non_numeric_returns_nil
    assert_nil C.parse('rgb(red, 0, 0)')
  end

  # ---- named ----

  def test_named_colors_resolve
    assert_rgba [1.0, 0.0, 0.0, 1.0], C.parse('red')
    assert_rgba [0.0, 0.0, 1.0, 1.0], C.parse('blue')
    assert_rgba [0.0, 0.502, 0.0, 1.0], C.parse('green')   # CSS green != lime
    assert_rgba [0.0, 1.0, 0.0, 1.0],   C.parse('lime')
    assert_rgba [0.502, 0.502, 0.502, 1.0], C.parse('gray')
    assert_rgba C.parse('gray'),  C.parse('grey')           # spelling alias
    assert_rgba C.parse('cyan'),  C.parse('aqua')           # CSS alias
  end

  def test_named_case_insensitive
    assert_rgba C.parse('red'), C.parse('Red')
    assert_rgba C.parse('red'), C.parse('RED')
  end

  def test_unknown_name_returns_nil
    # CSS has rebeccapurple, palegoldenrod, etc. We don't ship those.
    assert_nil C.parse('rebeccapurple')
    assert_nil C.parse('palegoldenrod')
  end

  # ---- bail cases ----

  def test_nil_input
    assert_nil C.parse(nil)
  end

  def test_empty_input
    assert_nil C.parse('')
    assert_nil C.parse('   ')
  end

  def test_malformed_returns_nil
    assert_nil C.parse('not-a-color')
    assert_nil C.parse('#xyz')
    assert_nil C.parse('hsl(0, 100%, 50%)')   # we don't support HSL
    assert_nil C.parse('var(--red)')           # CSS vars unsupported
  end
end
