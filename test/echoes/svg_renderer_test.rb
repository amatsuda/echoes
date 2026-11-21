# frozen_string_literal: true

require "test_helper"
require "echoes/svg_renderer"

class Echoes::SvgRendererTest < Test::Unit::TestCase
  test "the WebKit fallback page forbids every network load" do
    html = Echoes::SvgRenderer.send(:build_html, '<svg><image href="https://evil/beacon"/></svg>')
    head, body = html.split('<body>', 2)
    assert_match(/<meta http-equiv="Content-Security-Policy" content="default-src 'none'/, head)
    assert_includes body, 'https://evil/beacon'
  end

  test "build_html scrubs invalid UTF-8 rather than crashing" do
    html = Echoes::SvgRenderer.send(:build_html, "<svg>\xFF</svg>".b)
    assert html.valid_encoding?
    assert_includes html, '<svg></svg>'
  end
end
