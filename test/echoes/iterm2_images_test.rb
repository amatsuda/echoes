# frozen_string_literal: true

require "test_helper"
require "echoes/iterm2_images"

class Echoes::Iterm2ImagesTest < Test::Unit::TestCase
  # --- parse_params ---

  test "parse_params splits semicolon-separated key=value pairs" do
    out = Echoes::Iterm2Images.parse_params('name=Zm9v;size=42;inline=1')
    assert_equal 'Zm9v', out['name']
    assert_equal '42',   out['size']
    assert_equal '1',    out['inline']
  end

  test "parse_params is empty for empty input" do
    assert_equal({}, Echoes::Iterm2Images.parse_params(''))
  end

  test "parse_params keeps the value verbatim (no decoding)" do
    out = Echoes::Iterm2Images.parse_params('width=100px')
    assert_equal '100px', out['width']
  end

  # --- parse_dim ---

  test "parse_dim returns nil for nil / empty / 'auto'" do
    [nil, '', 'auto'].each do |v|
      assert_nil Echoes::Iterm2Images.parse_dim(v, natural_px: 200, cell_px: 8.0, screen_size: 80)
    end
  end

  test "parse_dim treats a bare integer as a cell count" do
    assert_equal 20,
      Echoes::Iterm2Images.parse_dim('20', natural_px: 200, cell_px: 8.0, screen_size: 80)
  end

  test "parse_dim rounds Npx up to whole cells" do
    # 100px / 8px-per-cell = 12.5 → 13.
    assert_equal 13,
      Echoes::Iterm2Images.parse_dim('100px', natural_px: 999, cell_px: 8.0, screen_size: 80)
  end

  test "parse_dim handles N%" do
    # 25% of 80 cols = 20.
    assert_equal 20,
      Echoes::Iterm2Images.parse_dim('25%', natural_px: 999, cell_px: 8.0, screen_size: 80)
  end

  test "parse_dim is defensive against zero cell_px on 'Npx'" do
    assert_nil Echoes::Iterm2Images.parse_dim('50px', natural_px: 999, cell_px: 0.0, screen_size: 80)
  end

  # --- handle (end-to-end through a stubbed decoder + stub screen) ---

  def setup
    @screen = StubScreen.new
  end

  def b64(s)
    [s].pack('m0')
  end

  test "handle decodes payload and calls put_kitty_image with natural sizing" do
    Echoes::Iterm2Images.stub_decoder do |bytes|
      assert_equal 'PNGBYTES', bytes
      {rgba: 'X' * 200, width: 40, height: 30}
    end

    osc_rest = "File=inline=1:#{b64('PNGBYTES')}"
    assert Echoes::Iterm2Images.handle(osc_rest, screen: @screen)

    assert_equal 1, @screen.images.size
    img = @screen.images.first
    assert_equal 40,    img[:width]
    assert_equal 30,    img[:height]
    assert_nil          img[:cells_w]   # natural sizing
    assert_nil          img[:cells_h]
  end

  test "handle honors explicit width / height in cells" do
    Echoes::Iterm2Images.stub_decoder do |_|
      {rgba: '', width: 100, height: 100}
    end
    Echoes::Iterm2Images.handle("File=inline=1;width=24;height=8:#{b64('x')}",
                                 screen: @screen)
    assert_equal 24, @screen.images.first[:cells_w]
    assert_equal 8,  @screen.images.first[:cells_h]
  end

  test "handle ignores inline=0 (file-save mode)" do
    Echoes::Iterm2Images.stub_decoder do |_|
      flunk "decoder shouldn't run for inline=0"
    end
    refute Echoes::Iterm2Images.handle("File=inline=0:#{b64('x')}", screen: @screen)
    assert_empty @screen.images
  end

  test "handle is a no-op without a payload" do
    Echoes::Iterm2Images.stub_decoder do |_|
      flunk "decoder shouldn't run for missing payload"
    end
    refute Echoes::Iterm2Images.handle("File=inline=1", screen: @screen)
  end

  test "handle is a no-op without the File= verb prefix" do
    Echoes::Iterm2Images.stub_decoder do |_|
      flunk "decoder shouldn't run for non-File verbs"
    end
    refute Echoes::Iterm2Images.handle("CursorShape=1:#{b64('x')}", screen: @screen)
  end

  test "handle silently bails when the decoder returns nil" do
    Echoes::Iterm2Images.stub_decoder { |_| nil }
    refute Echoes::Iterm2Images.handle("File=inline=1:#{b64('garbage')}", screen: @screen)
    assert_empty @screen.images
  end

  test "handle bails on malformed base64 payload" do
    Echoes::Iterm2Images.stub_decoder do |_|
      flunk "decoder shouldn't see malformed input"
    end
    refute Echoes::Iterm2Images.handle("File=inline=1:!!!not-base64",
                                        screen: @screen)
  end

  # --- SVG path (dispatch only — rendering is stubbed) ---

  test "handle routes SVG payload through SvgRenderer using cell-based dims" do
    captured = nil
    svg = %(<svg xmlns="http://www.w3.org/2000/svg"/>).b
    with_svg_renderer_stub(->(bytes, width:, height:) {
      captured = [bytes, width, height]
      {rgba: ('R' * width * height * 4).b, width: width, height: height}
    }) do
      assert Echoes::Iterm2Images.handle(
        "File=inline=1;width=10;height=5:#{b64(svg)}", screen: @screen)
    end
    # 10 cells × 8.0 cell_w = 80; 5 × 16.0 = 80.
    assert_equal [svg, 80, 80], captured
    assert_equal 1, @screen.images.size
  end

  test "handle SVG with width=Npx uses literal pixel target" do
    captured = nil
    svg = %(<svg xmlns="http://www.w3.org/2000/svg"/>).b
    with_svg_renderer_stub(->(_bytes, width:, height:) {
      captured = [width, height]
      {rgba: ('X' * width * height * 4).b, width: width, height: height}
    }) do
      Echoes::Iterm2Images.handle(
        "File=inline=1;width=300px;height=200px:#{b64(svg)}", screen: @screen)
    end
    assert_equal [300, 200], captured
  end

  test "handle SVG without client dims falls back to intrinsic size" do
    captured = nil
    svg = %(<svg width="120" height="80" xmlns="http://www.w3.org/2000/svg"/>).b
    with_svg_renderer_stub(->(_bytes, width:, height:) {
      captured = [width, height]
      {rgba: ('X' * width * height * 4).b, width: width, height: height}
    }) do
      Echoes::Iterm2Images.handle("File=inline=1:#{b64(svg)}", screen: @screen)
    end
    assert_equal [120, 80], captured
  end

  test "handle SVG with no client dims and no intrinsic falls back to 512²" do
    captured = nil
    svg = %(<svg xmlns="http://www.w3.org/2000/svg"/>).b
    with_svg_renderer_stub(->(_bytes, width:, height:) {
      captured = [width, height]
      {rgba: ('X' * width * height * 4).b, width: width, height: height}
    }) do
      Echoes::Iterm2Images.handle("File=inline=1:#{b64(svg)}", screen: @screen)
    end
    assert_equal [512, 512], captured
  end

  def with_svg_renderer_stub(stub)
    require 'echoes/svg_renderer'
    real = Echoes::SvgRenderer.method(:rasterize)
    TestHelpers.replace_singleton_method(Echoes::SvgRenderer, :rasterize, &stub)
    yield
  ensure
    TestHelpers.replace_singleton_method(Echoes::SvgRenderer, :rasterize, &real) if real
  end

  # --- end-to-end through the CG fast path (no SvgRenderer stub) ---

  test "path-only SVG renders through the CG fast path end-to-end" do
    # No `with_svg_renderer_stub`: SvgRenderer dispatches to the real
    # SvgCgRenderer, which actually rasterizes via CoreGraphics.
    svg = %(<svg width="20" height="20"><rect width="20" height="20" fill="red"/></svg>).b
    osc_rest = "File=inline=1;width=20px;height=20px:#{b64(svg)}"
    assert Echoes::Iterm2Images.handle(osc_rest, screen: @screen)
    assert_equal 1, @screen.images.size
    img = @screen.images.first
    assert_equal 20, img[:width]
    assert_equal 20, img[:height]
    assert_equal 20 * 20 * 4, img[:rgba].bytesize
    # Premultiplied red, alpha 0xff.
    r, _, _, a = img[:rgba].byteslice(0, 4).bytes
    assert_in_delta 255, r, 4
    assert_in_delta 255, a, 4
  end

  test "SVG with text bails CG fast path and reaches the WKWebView backend" do
    # SvgCgRenderer returns nil for <text>; we stub it to a sentinel
    # tracker and stub the WKWebView entry too so the test stays
    # headless (no real WebContent process).
    require 'echoes/svg_cg_renderer'
    require 'echoes/svg_renderer'

    cg_called = false
    wk_called = false
    cg_real = Echoes::SvgCgRenderer.method(:rasterize)
    TestHelpers.replace_singleton_method(Echoes::SvgCgRenderer, :rasterize) do |bytes, width:, height:|
      cg_called = true
      cg_real.call(bytes, width: width, height: height)  # returns nil (bails on <text>)
    end

    # Replace the whole SvgRenderer.rasterize so we can detect the
    # WebKit-path attempt without actually spinning up WKWebView.
    # We re-implement the fast-path-first / fallback dispatch.
    sr_real = Echoes::SvgRenderer.method(:rasterize)
    TestHelpers.replace_singleton_method(Echoes::SvgRenderer, :rasterize) do |bytes, width:, height:|
      fast = Echoes::SvgCgRenderer.rasterize(bytes, width: width, height: height)
      next fast if fast
      wk_called = true
      {rgba: ("\xFF" * (width * height * 4)).b, width: width, height: height}
    end

    begin
      svg = %(<svg width="10" height="10"><text>hi</text></svg>).b
      osc_rest = "File=inline=1;width=10px;height=10px:#{b64(svg)}"
      assert Echoes::Iterm2Images.handle(osc_rest, screen: @screen)
    ensure
      TestHelpers.replace_singleton_method(Echoes::SvgCgRenderer, :rasterize, &cg_real)
      TestHelpers.replace_singleton_method(Echoes::SvgRenderer, :rasterize, &sr_real)
    end

    assert cg_called, "CG fast path should have been attempted first"
    assert wk_called, "WKWebView fallback should have been reached after CG returned nil"
  end

  # --- helpers ---

  class StubScreen
    attr_reader :images

    def initialize
      @images = []
      @cols = 80
      @rows = 24
    end

    attr_reader :cols, :rows

    def cell_pixel_width;  8.0  end
    def cell_pixel_height; 16.0 end

    def put_kitty_image(rgba:, width:, height:, cells_w: nil, cells_h: nil, **)
      @images << {rgba: rgba, width: width, height: height,
                  cells_w: cells_w, cells_h: cells_h}
    end
  end
end

# Lightweight monkey-patch — same shape as the Kitty test's
# stub_decoder — lets dispatch tests skip AppKit PNG decode.
module Echoes::Iterm2Images
  def self.stub_decoder(&block)
    @stubbed = block
  end

  class << self
    alias_method :_orig_decode_image, :decode_image

    def decode_image(bytes)
      if @stubbed
        @stubbed.call(bytes)
      else
        _orig_decode_image(bytes)
      end
    end
  end
end
