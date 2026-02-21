# frozen_string_literal: true

require "test_helper"

class Echoes::SixelDecoderTest < Test::Unit::TestCase
  test "empty data produces zero dimensions" do
    dec = Echoes::SixelDecoder.new.decode("".b)
    assert_equal(0, dec.width)
    assert_equal(0, dec.height)
  end

  test "single sixel character sets correct pixels" do
    # '?' (0x3F) means bits = 0, no pixels set
    dec = Echoes::SixelDecoder.new.decode("?".b)
    assert_equal(1, dec.width)
    assert_equal(0, dec.height)
  end

  test "sixel @ sets bottom pixel" do
    # '@' = 0x40, bits = 1, only bit 0 set
    dec = Echoes::SixelDecoder.new.decode("@".b)
    assert_equal(1, dec.width)
    assert_equal(1, dec.height)
  end

  test "sixel ~ sets all 6 pixels" do
    # '~' = 0x7E, bits = 0x3F = 0b111111
    dec = Echoes::SixelDecoder.new.decode("~".b)
    assert_equal(1, dec.width)
    assert_equal(6, dec.height)
  end

  test "repeat operator" do
    # !3~ means repeat '~' 3 times
    dec = Echoes::SixelDecoder.new.decode("!3~".b)
    assert_equal(3, dec.width)
    assert_equal(6, dec.height)
  end

  test "graphics newline advances by 6 rows" do
    dec = Echoes::SixelDecoder.new.decode("~-~".b)
    assert_equal(1, dec.width)
    assert_equal(12, dec.height)
  end

  test "graphics carriage return resets x" do
    dec = Echoes::SixelDecoder.new.decode("~~$~".b)
    assert_equal(2, dec.width)
    assert_equal(6, dec.height)
  end

  test "color selection" do
    dec = Echoes::SixelDecoder.new.decode("#1@".b)
    assert_equal(1, dec.width)
    assert_equal(1, dec.height)
  end

  test "color definition RGB" do
    # #0;2;100;0;0 defines color 0 as red, then paint
    dec = Echoes::SixelDecoder.new.decode("#0;2;100;0;0@".b)
    rgba = dec.to_rgba
    # First pixel should be red
    assert_equal(255, rgba.getbyte(0))  # R
    assert_equal(0,   rgba.getbyte(1))  # G
    assert_equal(0,   rgba.getbyte(2))  # B
    assert_equal(255, rgba.getbyte(3))  # A
  end

  test "raster attributes set declared dimensions" do
    dec = Echoes::SixelDecoder.new.decode('"1;1;10;12~'.b)
    assert_equal(10, dec.width)
    assert_equal(12, dec.height)
  end

  test "to_rgba produces correct buffer size" do
    dec = Echoes::SixelDecoder.new.decode("!4~".b)
    rgba = dec.to_rgba
    assert_equal(4 * 6 * 4, rgba.bytesize)
  end

  test "background mode 1 leaves unset pixels transparent" do
    dec = Echoes::SixelDecoder.new([0, 1]).decode("@".b)
    rgba = dec.to_rgba
    # pixel (0,0) is set
    assert_equal(255, rgba.getbyte(3))
  end

  test "default background mode fills unset pixels opaque" do
    dec = Echoes::SixelDecoder.new.decode('"1;1;2;2@'.b)
    rgba = dec.to_rgba
    # pixel (1,1) is unset but should be opaque (alpha=255)
    offset = (1 * 2 + 1) * 4
    assert_equal(255, rgba.getbyte(offset + 3))
  end

  test "color definition HLS" do
    # #0;1;0;50;0 defines color 0 as HLS (gray 50%)
    dec = Echoes::SixelDecoder.new.decode("#0;1;0;50;0@".b)
    rgba = dec.to_rgba
    # Should be gray ~128
    r = rgba.getbyte(0)
    assert(r >= 126 && r <= 130, "Expected gray ~128, got #{r}")
  end
end
