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

  test "decode_payload accepts unpadded base64 (kitty spec lets senders omit padding)" do
    # kitten icat --transfer-mode stream chunks base64 at arbitrary
    # byte boundaries; the assembled payload across m=1 chunks can
    # end mid-quad. Without auto-pad we'd silently EBADPNG every
    # image whose total base64 length isn't a multiple of 4.
    original = "Hello, World!"  # base64-encodes to "SGVsbG8sIFdvcmxkIQ==" (20 chars w/ padding)
    encoded = [original].pack('m0').delete('=')  # 18 chars, no padding
    assert_equal original, Echoes::KittyGraphics.decode_payload(encoded)
    # And the 1-byte-short case (3 extra chars):
    encoded3 = [original + "!"].pack('m0').delete('=')
    assert_equal(original + "!", Echoes::KittyGraphics.decode_payload(encoded3))
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

  test "z= flows through to put_kitty_image as z_index" do
    image_bytes = StubScreen::TINY_PNG_BYTES
    Echoes::KittyGraphics.stub_decoder(image_bytes => {rgba: 'X', width: 1, height: 1}) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,i=1,f=100,z=-1",
                                         b64(image_bytes),
                                         screen: @screen, writer: @writer)
    end
    assert_equal(-1, @screen.images[0][:z_index])
  end

  test "z= absent defaults to z_index 0" do
    image_bytes = StubScreen::TINY_PNG_BYTES
    Echoes::KittyGraphics.stub_decoder(image_bytes => {rgba: 'X', width: 1, height: 1}) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,i=2,f=100",
                                         b64(image_bytes),
                                         screen: @screen, writer: @writer)
    end
    assert_equal 0, @screen.images[0][:z_index]
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

  test "t=f reads the file at the (base64-encoded) path and displays it" do
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      png_path = File.join(dir, 'snap.png')
      File.binwrite(png_path, "PNGBYTES-FROM-FILE")
      Echoes::KittyGraphics.stub_decoder("PNGBYTES-FROM-FILE" => {rgba: 'X', width: 7, height: 5}) do
        Echoes::KittyGraphics.handle_chunk(@state, "a=T,t=f,i=1,f=100",
                                            b64(png_path),
                                            screen: @screen, writer: @writer)
      end
      assert_equal 1, @screen.images.size
      assert_equal 7, @screen.images.first[:width]
      assert File.exist?(png_path), "t=f should leave the file in place"
    end
  end

  test "t=t reads the file then deletes it" do
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      png_path = File.join(dir, 'tmp.png')
      File.binwrite(png_path, "TMP-PNG")
      Echoes::KittyGraphics.stub_decoder("TMP-PNG" => {rgba: 'Y', width: 2, height: 2}) do
        Echoes::KittyGraphics.handle_chunk(@state, "a=T,t=t,i=2,f=100",
                                            b64(png_path),
                                            screen: @screen, writer: @writer)
      end
      assert_equal 1, @screen.images.size
      refute File.exist?(png_path), "t=t should unlink the file after reading"
    end
  end

  test "t=f with a missing path responds with ENOENT" do
    # resolve_transmission returns nil → decode_image never runs, so
    # we don't need a stub here.
    Echoes::KittyGraphics.handle_chunk(@state, "a=T,t=f,i=4,f=100",
                                        b64('/nonexistent/path/to/image.png'),
                                        screen: @screen, writer: @writer)
    assert_empty @screen.images
    assert_includes @writes.first, 'ENOENT'
  end

  test "f=24 (raw RGB) routes to the raw decoder with s= / v= as dimensions" do
    rgb = ("\xFF\x00\x00" * 6).b   # 3x2 red
    captured = nil
    replacement = ->(bytes, format, opts = {}, screen: nil) {
      captured = [bytes, format, opts['s'], opts['v']]
      {rgba: "RGBA" * 6, width: 3, height: 2}
    }
    Echoes::KittyGraphics.with_decoder(replacement) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,f=24,s=3,v=2,i=11",
                                         b64(rgb),
                                         screen: @screen, writer: @writer)
    end
    assert_equal [rgb, '24', '3', '2'], captured
    assert_equal 1, @screen.images.size
    assert_equal 3, @screen.images.first[:width]
  end

  test "f=32 (raw RGBA) routes to the raw decoder with s= / v= as dimensions" do
    rgba = ("\xFF\x00\x00\xFF" * 4).b  # 2x2 red
    captured = nil
    replacement = ->(bytes, format, opts = {}, screen: nil) {
      captured = [bytes, format, opts['s'], opts['v']]
      {rgba: rgba, width: 2, height: 2}
    }
    Echoes::KittyGraphics.with_decoder(replacement) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,f=32,s=2,v=2,i=12",
                                         b64(rgba),
                                         screen: @screen, writer: @writer)
    end
    assert_equal [rgba, '32', '2', '2'], captured
    assert_equal 1, @screen.images.size
    assert_equal 2, @screen.images.first[:width]
  end

  test "t=s (shared memory) is not supported and responds with ENOENT" do
    Echoes::KittyGraphics.handle_chunk(@state, "a=T,t=s,i=5,f=100",
                                        b64('/dev/shm/whatever'),
                                        screen: @screen, writer: @writer)
    assert_empty @screen.images
    assert_includes @writes.first, 'ENOENT'
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

  test "q=2 on the first chunk of a multi-chunk frame still suppresses the reply" do
    # kitten icat declares q=2 once on the first chunk and lets
    # subsequent chunks omit it. Make sure assemble_chunk carries
    # it through so the final dispatch sees the suppression flag.
    image_bytes = StubScreen::TINY_PNG_BYTES
    Echoes::KittyGraphics.stub_decoder(image_bytes => {rgba: 'X', width: 1, height: 1}) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,i=42,q=2,m=1",
                                         b64(image_bytes[0, 4]),
                                         screen: @screen, writer: @writer)
      Echoes::KittyGraphics.handle_chunk(@state, "i=42,m=1",
                                         b64(image_bytes[4..-1] || ''),
                                         screen: @screen, writer: @writer)
      Echoes::KittyGraphics.handle_chunk(@state, "i=42,m=0", '',
                                         screen: @screen, writer: @writer)
    end
    assert_empty @writes, "q=2 from the first chunk must survive assembly"
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

  test "o=z (zlib) inflates the payload before decoding" do
    require 'zlib'
    raw       = ("\xFF\x00\x00" * 6).b   # 3x2 raw RGB
    deflated  = Zlib::Deflate.deflate(raw)
    captured  = nil
    replacement = ->(bytes, format, opts = {}, screen: nil) {
      captured = [bytes, format]
      {rgba: "RGBA" * 6, width: 3, height: 2}
    }
    Echoes::KittyGraphics.with_decoder(replacement) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,f=24,o=z,s=3,v=2,i=21",
                                         b64(deflated),
                                         screen: @screen, writer: @writer)
    end
    assert_equal raw, captured[0], "decoder must see inflated bytes, not deflated"
    assert_equal '24', captured[1]
    assert_equal 1, @screen.images.size
  end

  test "SVG payload routes through SvgRenderer with c=/r= × cell_px as target" do
    captured = nil
    svg = %(<svg xmlns="http://www.w3.org/2000/svg"/>).b
    with_svg_renderer_stub(->(bytes, width:, height:) {
      captured = [bytes, width, height]
      {rgba: ('X' * width * height * 4).b, width: width, height: height}
    }) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,c=10,r=5,i=42",
                                         b64(svg),
                                         screen: @screen, writer: @writer)
    end
    # 10 cells × 8.0 cell_w = 80 px; 5 × 16.0 = 80 px.
    assert_equal [svg, 80, 80], captured
    assert_equal 1, @screen.images.size
  end

  test "SVG payload falls back to intrinsic size when no c=/r= or s=/v= given" do
    captured = nil
    svg = %(<svg width="200" height="100" xmlns="http://www.w3.org/2000/svg"/>).b
    with_svg_renderer_stub(->(_bytes, width:, height:) {
      captured = [width, height]
      {rgba: ('X' * width * height * 4).b, width: width, height: height}
    }) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,i=43", b64(svg),
                                         screen: @screen, writer: @writer)
    end
    assert_equal [200, 100], captured
  end

  test "SVG payload prefers s=/v= explicit pixels over c=/r=" do
    captured = nil
    svg = %(<svg xmlns="http://www.w3.org/2000/svg"/>).b
    with_svg_renderer_stub(->(_bytes, width:, height:) {
      captured = [width, height]
      {rgba: ('X' * width * height * 4).b, width: width, height: height}
    }) do
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,s=300,v=200,c=10,r=5,i=44",
                                         b64(svg),
                                         screen: @screen, writer: @writer)
    end
    assert_equal [300, 200], captured
  end

  def with_svg_renderer_stub(stub)
    require 'echoes/svg_renderer'
    real = Echoes::SvgRenderer.method(:rasterize)
    Echoes::SvgRenderer.define_singleton_method(:rasterize, &stub)
    yield
  ensure
    Echoes::SvgRenderer.define_singleton_method(:rasterize, &real) if real
  end

  test "path-only SVG renders through the CG fast path end-to-end" do
    # No stub: SvgRenderer dispatches to the real SvgCgRenderer.
    svg = %(<svg width="20" height="20"><rect width="20" height="20" fill="red"/></svg>).b
    Echoes::KittyGraphics.handle_chunk(@state, "a=T,s=20,v=20,i=70", b64(svg),
                                       screen: @screen, writer: @writer)
    assert_equal 1, @screen.images.size
    img = @screen.images.first
    assert_equal 20, img[:width]
    assert_equal 20, img[:height]
    assert_equal 20 * 20 * 4, img[:rgba].bytesize
    r, _, _, a = img[:rgba].byteslice(0, 4).bytes
    assert_in_delta 255, r, 4
    assert_in_delta 255, a, 4
  end

  test "SVG with text bails CG fast path and reaches the WKWebView backend" do
    require 'echoes/svg_cg_renderer'
    require 'echoes/svg_renderer'

    cg_called = false
    wk_called = false
    cg_real = Echoes::SvgCgRenderer.method(:rasterize)
    Echoes::SvgCgRenderer.define_singleton_method(:rasterize) do |bytes, width:, height:|
      cg_called = true
      cg_real.call(bytes, width: width, height: height)   # nil on <text>
    end
    sr_real = Echoes::SvgRenderer.method(:rasterize)
    Echoes::SvgRenderer.define_singleton_method(:rasterize) do |bytes, width:, height:|
      fast = Echoes::SvgCgRenderer.rasterize(bytes, width: width, height: height)
      next fast if fast
      wk_called = true
      {rgba: ("\xFF" * (width * height * 4)).b, width: width, height: height}
    end

    begin
      svg = %(<svg width="10" height="10"><text>hi</text></svg>).b
      Echoes::KittyGraphics.handle_chunk(@state, "a=T,s=10,v=10,i=71", b64(svg),
                                         screen: @screen, writer: @writer)
    ensure
      Echoes::SvgCgRenderer.define_singleton_method(:rasterize, &cg_real)
      Echoes::SvgRenderer.define_singleton_method(:rasterize, &sr_real)
    end

    assert cg_called, "CG fast path should have been attempted first"
    assert wk_called, "WKWebView fallback should have been reached after CG returned nil"
  end

  test "o=z with a corrupt stream responds with EBADDATA" do
    Echoes::KittyGraphics.handle_chunk(@state, "a=T,f=24,o=z,s=2,v=1,i=22",
                                       b64("not a zlib stream"),
                                       screen: @screen, writer: @writer)
    assert_empty @screen.images
    assert_includes @writes.first, 'EBADDATA'
  end

  test "a=q (capability probe) replies OK for supported format/transmission" do
    # kitten icat sends roughly this as its detection probe
    Echoes::KittyGraphics.handle_chunk(@state, "a=q,i=31,s=1,v=1,f=24,t=d",
                                       b64("AAA"),
                                       screen: @screen, writer: @writer)
    assert_empty @screen.images, "a=q must not display anything"
    assert_includes @writes.first, 'i=31'
    assert_includes @writes.first, 'OK'
  end

  test "a=q replies EBADF for an unsupported format" do
    Echoes::KittyGraphics.handle_chunk(@state, "a=q,i=7,f=999,t=d",
                                       b64("AAA"),
                                       screen: @screen, writer: @writer)
    assert_includes @writes.first, 'EBADF'
  end

  test "a=q replies EBADF for an unsupported transmission medium" do
    Echoes::KittyGraphics.handle_chunk(@state, "a=q,i=8,f=24,t=s",
                                       b64("/dev/shm/x"),
                                       screen: @screen, writer: @writer)
    assert_includes @writes.first, 'EBADF'
  end

  test "a=q replies EBADF for an unsupported compression method" do
    Echoes::KittyGraphics.handle_chunk(@state, "a=q,i=9,f=24,o=xz",
                                       b64("AAA"),
                                       screen: @screen, writer: @writer)
    assert_includes @writes.first, 'EBADF'
  end

  test "a=d (no d= specifier) clears every placement, keeping the cache" do
    @state[:cache]['7'] = {rgba: 'X', width: 1, height: 1}
    @screen.placements << {image_id: '7', anchor_row: 0, anchor_col: 0,
                            cell_cols: 1, cell_rows: 1, x_off: 0, y_off: 0,
                            image: @state[:cache]['7']}
    @screen.placements << {image_id: '8', anchor_row: 2, anchor_col: 2,
                            cell_cols: 1, cell_rows: 1, x_off: 0, y_off: 0,
                            image: {rgba: 'Y', width: 1, height: 1}}
    Echoes::KittyGraphics.handle_chunk(@state, "a=d", '',
                                       screen: @screen, writer: @writer)
    assert_empty @screen.placements
    assert_includes @state[:cache], '7', "lowercase / default d-selector keeps images"
  end

  test "a=d,d=A clears placements AND drops the bitmap cache" do
    @state[:cache]['7'] = {rgba: 'X', width: 1, height: 1}
    @screen.placements << {image_id: '7', anchor_row: 0, anchor_col: 0,
                            cell_cols: 1, cell_rows: 1, x_off: 0, y_off: 0,
                            image: @state[:cache]['7']}
    Echoes::KittyGraphics.handle_chunk(@state, "a=d,d=A", '',
                                       screen: @screen, writer: @writer)
    assert_empty @screen.placements
    assert_empty @state[:cache]
  end

  test "a=d,d=i selects placements by i= (image id)" do
    @screen.placements << {image_id: '7', anchor_row: 0, anchor_col: 0,
                            cell_cols: 1, cell_rows: 1, x_off: 0, y_off: 0,
                            image: {rgba: 'X', width: 1, height: 1}}
    @screen.placements << {image_id: '8', anchor_row: 1, anchor_col: 0,
                            cell_cols: 1, cell_rows: 1, x_off: 0, y_off: 0,
                            image: {rgba: 'Y', width: 1, height: 1}}
    Echoes::KittyGraphics.handle_chunk(@state, "a=d,d=i,i=7", '',
                                       screen: @screen, writer: @writer)
    assert_equal ['8'], @screen.placements.map { |p| p[:image_id] }
  end

  test "X= / Y= sub-cell offsets propagate to the screen for fine alignment" do
    @state[:cache]['7'] = {rgba: 'X', width: 1, height: 1}
    Echoes::KittyGraphics.handle_chunk(@state, "a=p,i=7,X=3,Y=11", '',
                                       screen: @screen, writer: @writer)
    assert_equal 3,  @screen.images[0][:px_x_offset]
    assert_equal 11, @screen.images[0][:px_y_offset]
  end

  test "missing X= / Y= default to zero" do
    @state[:cache]['8'] = {rgba: 'X', width: 1, height: 1}
    Echoes::KittyGraphics.handle_chunk(@state, "a=p,i=8", '',
                                       screen: @screen, writer: @writer)
    assert_equal 0, @screen.images[0][:px_x_offset]
    assert_equal 0, @screen.images[0][:px_y_offset]
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

    attr_reader :images, :placements

    def initialize
      @images = []
      @placements = []
    end

    def cell_pixel_width;  8.0  end
    def cell_pixel_height; 16.0 end

    def respond_to?(meth, *)
      meth == :put_kitty_image || meth == :placements || super
    end

    def put_kitty_image(rgba:, width:, height:, cells_w:, cells_h:,
                         px_x_offset: 0, px_y_offset: 0,
                         suppress_cursor:, image_id: nil, z_index: 0)
      @images << {rgba: rgba, width: width, height: height,
                   cells_w: cells_w, cells_h: cells_h,
                   px_x_offset: px_x_offset, px_y_offset: px_y_offset,
                   suppress_cursor: suppress_cursor,
                   image_id: image_id, z_index: z_index}
    end
  end
end

# Lightweight monkey-patch so dispatch tests can inject decoded
# images without going through the AppKit-backed PNG decoder.
module Echoes::KittyGraphics
  def self.stub_decoder(mapping)
    real = method(:decode_image)
    define_singleton_method(:decode_image) do |bytes, _format, _opts = {}, screen: nil|
      mapping[bytes]
    end
    yield
  ensure
    define_singleton_method(:decode_image) do |bytes, format, opts = {}, screen: nil|
      real.call(bytes, format, opts, screen: screen)
    end
  end

  # Like stub_decoder, but the replacement is a callable that
  # receives (bytes, format, opts, screen:). Useful for asserting
  # which branch the format dispatch took.
  def self.with_decoder(replacement)
    real = method(:decode_image)
    define_singleton_method(:decode_image, &replacement)
    yield
  ensure
    define_singleton_method(:decode_image) do |bytes, format, opts = {}, screen: nil|
      real.call(bytes, format, opts, screen: screen)
    end
  end
end
