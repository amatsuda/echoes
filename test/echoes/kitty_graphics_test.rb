# frozen_string_literal: true

require "test_helper"
require "echoes/kitty_graphics"
class Echoes::KittyGraphicsTest < Test::Unit::TestCase
  def setup
    @state  = {chunks: {}, cache: {}}
    @screen = StubScreen.new
    @writer = ->(s) { @writes << s }
    @writes = []
  end

  def b64(s)
    [s].pack('m0')
  end

  # --- option parsing ---

  test "parse_options splits comma-separated key=value pairs" do
    opts = Echoes::KittyGraphics.parse_options('a=T,f=100,i=42')
    assert_equal 'T',   opts['a']
    assert_equal '100', opts['f']
    assert_equal '42',  opts['i']
  end

  test "parse_options keeps later values when keys repeat" do
    opts = Echoes::KittyGraphics.parse_options('a=T,a=p')
    assert_equal 'p', opts['a']
  end

  test "parse_options handles missing values as empty strings" do
    opts = Echoes::KittyGraphics.parse_options('a=T,k')
    assert_equal '', opts['k']
  end

  test "parse_options is empty for empty input" do
    assert_equal({}, Echoes::KittyGraphics.parse_options(''))
  end

  # --- chunk assembly ---

  test "single chunk (no m=) returns immediately" do
    assembled = Echoes::KittyGraphics.assemble_chunk(@state, 'i=1,f=100', 'AAAA')
    refute_nil assembled
    opts, payload = assembled
    assert_equal '1',    opts['i']
    assert_equal 'AAAA', payload
    assert_empty @state[:chunks]
  end

  test "m=1 chunks buffer until m=0 closes the image" do
    a = Echoes::KittyGraphics.assemble_chunk(@state, 'i=7,f=100,m=1', 'AAAA')
    assert_nil a, "first m=1 chunk shouldn't return assembled payload"
    b = Echoes::KittyGraphics.assemble_chunk(@state, 'i=7,m=1', 'BBBB')
    assert_nil b
    c = Echoes::KittyGraphics.assemble_chunk(@state, 'i=7,m=0', 'CCCC')
    refute_nil c
    opts, payload = c
    # Final-options should preserve the first-chunk options like f=
    assert_equal '100', opts['f']
    assert_equal 'AAAABBBBCCCC', payload
    assert_empty @state[:chunks], "chunk buffer should be drained after m=0"
  end

  test "different ids accumulate independently" do
    Echoes::KittyGraphics.assemble_chunk(@state, 'i=1,m=1', 'X')
    Echoes::KittyGraphics.assemble_chunk(@state, 'i=2,m=1', 'Y')
    a = Echoes::KittyGraphics.assemble_chunk(@state, 'i=1,m=0', 'Z')
    refute_nil a
    assert_equal 'XZ', a[1]
    refute_empty @state[:chunks], "id 2 should still be buffering"
  end

  # --- payload decoding (base64) ---

  test "decode_payload base64-decodes valid input" do
    bytes = Echoes::KittyGraphics.decode_payload(b64("hello"))
    assert_equal 'hello', bytes
  end

  test "decode_payload tolerates whitespace from line-wrapped input" do
    encoded = b64("hello world")
    wrapped = encoded.scan(/.{1,4}/).join("\n")
    assert_equal 'hello world', Echoes::KittyGraphics.decode_payload(wrapped)
  end

  test "decode_payload returns empty string for empty input" do
    assert_equal '', Echoes::KittyGraphics.decode_payload('')
  end

  test "decode_payload returns nil on bogus input" do
    assert_nil Echoes::KittyGraphics.decode_payload('!!!not base64!!!')
  end

  # --- dispatch (action handling) ---

  test "a=T with PNG payload caches and displays via screen" do
    image_bytes = StubScreen::TINY_PNG_BYTES  # tiny synthetic image (no real PNG decode in this stub)
    Echoes::KittyGraphics.stub_decoder(image_bytes => {rgba: 'RGBARGBA', width: 2, height: 1}) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,i=9,f=100",
                                         b64(image_bytes),
                                         screen: @screen, writer: @writer)
    end
    assert_equal 1, @screen.images.size
    assert_equal 2, @screen.images[0][:width]
    assert_includes @state[:cache], '9'
    assert_includes @writes.first, 'OK'
  end

  test "a=t caches the image but does not display it" do
    image_bytes = StubScreen::TINY_PNG_BYTES
    Echoes::KittyGraphics.stub_decoder(image_bytes => {rgba: 'RGBA', width: 1, height: 1}) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=t,i=3,f=100",
                                         b64(image_bytes),
                                         screen: @screen, writer: @writer)
    end
    assert_empty @screen.images, "a=t shouldn't push to the screen"
    assert_includes @state[:cache], '3'
  end

  test "a=p displays a cached image without re-decoding" do
    @state[:cache]['5'] = {rgba: 'PIX', width: 4, height: 4}
    Echoes::KittyGraphics.handle_chunk(@state, "a=p,i=5", '',
                                       screen: @screen, writer: @writer)
    assert_equal 1, @screen.images.size
    assert_equal 4, @screen.images[0][:width]
  end

  test "a=p without a cached image responds with ENOENT" do
    Echoes::KittyGraphics.handle_chunk(@state, "a=p,i=99", '',
                                       screen: @screen, writer: @writer)
    assert_empty @screen.images
    assert_includes @writes.first, 'ENOENT'
  end

  test "q=2 suppresses all responses" do
    image_bytes = StubScreen::TINY_PNG_BYTES
    Echoes::KittyGraphics.stub_decoder(image_bytes => {rgba: 'X', width: 1, height: 1}) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,i=1,q=2",
                                         b64(image_bytes),
                                         screen: @screen, writer: @writer)
    end
    assert_empty @writes
  end

  test "q=1 suppresses success but not errors" do
    image_bytes = StubScreen::TINY_PNG_BYTES
    Echoes::KittyGraphics.stub_decoder(image_bytes => {rgba: 'X', width: 1, height: 1}) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,i=1,q=1",
                                         b64(image_bytes),
                                         screen: @screen, writer: @writer)
    end
    assert_empty @writes
    Echoes::KittyGraphics.handle_chunk(@state, "a=p,i=999,q=1", '',
                                       screen: @screen, writer: @writer)
    assert_includes @writes.first, 'ENOENT'
  end

  test "C=1 in display options propagates as suppress_cursor" do
    @state[:cache]['1'] = {rgba: 'X', width: 1, height: 1}
    Echoes::KittyGraphics.handle_chunk(@state, "a=p,i=1,C=1", '',
                                       screen: @screen, writer: @writer)
    assert_equal true, @screen.images[0][:suppress_cursor]
  end

  # --- helper: stub Screen + decode_image ---

  class StubScreen
    TINY_PNG_BYTES = "PNG-STUB".b

    attr_reader :images

    def initialize
      @images = []
    end

    def respond_to?(meth, *)
      meth == :put_kitty_image || super
    end

    def put_kitty_image(rgba:, width:, height:, cells_w:, cells_h:, suppress_cursor:)
      @images << {rgba: rgba, width: width, height: height,
                   cells_w: cells_w, cells_h: cells_h,
                   suppress_cursor: suppress_cursor}
    end
  end
end

# Lightweight monkey-patch so dispatch tests can inject decoded
# images without going through the AppKit-backed PNG decoder.
module Echoes::KittyGraphics
  def self.stub_decoder(mapping)
    real = method(:decode_image)
    define_singleton_method(:decode_image) do |bytes, _format|
      mapping[bytes]
    end
    yield
  ensure
    define_singleton_method(:decode_image) { |bytes, format| real.call(bytes, format) }
  end
end
