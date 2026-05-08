# frozen_string_literal: true

require "test_helper"
require "stringio"
require "echoes/client"

class Echoes::ClientTest < Test::Unit::TestCase
  def setup
    @io = StringIO.new
  end

  test "bg_gradient writes a well-formed OSC 7772 sequence" do
    Echoes::Client.bg_gradient(from: '#1a1a2e', to: '#16213e', angle: 90, io: @io)
    assert_equal "\e]7772;bg-gradient;type=linear:angle=90:colors=#1a1a2e,#16213e\a",
                 @io.string
  end

  test "bg_gradient accepts a colors: array" do
    Echoes::Client.bg_gradient(colors: ['#000000', '#ffffff'], angle: 45, io: @io)
    assert_equal "\e]7772;bg-gradient;type=linear:angle=45:colors=#000000,#ffffff\a",
                 @io.string
  end

  test "bg_gradient roundtrips through the parser" do
    Echoes::Client.bg_gradient(from: '#102030', to: '#405060', angle: 135, io: @io)
    screen = Echoes::Screen.new(rows: 5, cols: 10)
    parser = Echoes::Parser.new(screen)
    parser.feed(@io.string)
    assert_equal :linear, screen.background[:type]
    assert_in_delta 135.0, screen.background[:angle], 0.001
    assert_equal 2, screen.background[:colors].size
  end

  test "bg_gradient raises when given fewer than 2 colors" do
    assert_raises(ArgumentError) do
      Echoes::Client.bg_gradient(colors: ['#abc'], io: @io)
    end
  end

  test "bg_clear emits the bg-clear command" do
    Echoes::Client.bg_clear(io: @io)
    assert_equal "\e]7772;bg-clear\a", @io.string
  end

  test "bg_color writes a well-formed OSC 7772 sequence" do
    Echoes::Client.bg_color('#1a1a2e', io: @io)
    assert_equal "\e]7772;bg-color;#1a1a2e\a", @io.string
  end

  test "bg_color roundtrips through the parser as a flat background" do
    Echoes::Client.bg_color('#1a1a2e', io: @io)
    screen = Echoes::Screen.new(rows: 5, cols: 10)
    parser = Echoes::Parser.new(screen)
    parser.feed(@io.string)
    assert_equal :flat, screen.background[:type]
    assert_equal 1, screen.background[:colors].size
  end

  test "bg_fill emits an OSC 7772 sequence with color and rect" do
    Echoes::Client.bg_fill('#1a1a2e', row1: 0, col1: 0, row2: 2, col2: 9, io: @io)
    assert_equal "\e]7772;bg-fill;color=#1a1a2e:rect=0,0,2,9\a", @io.string
  end

  test "bg_fill roundtrips through the parser, appending a region" do
    Echoes::Client.bg_fill('#1a1a2e', row1: 1, col1: 2, row2: 3, col2: 7, io: @io)
    screen = Echoes::Screen.new(rows: 5, cols: 10)
    parser = Echoes::Parser.new(screen)
    parser.feed(@io.string)
    assert_equal 1, screen.bg_fills.size
    assert_equal [1, 2, 3, 7], screen.bg_fills[0][:rect]
  end

  test "bg_clear roundtrips through the parser" do
    screen = Echoes::Screen.new(rows: 5, cols: 10)
    screen.background = {type: :linear, angle: 0.0, colors: [[0, 0, 0, 1.0], [1.0, 1.0, 1.0, 1.0]]}
    parser = Echoes::Parser.new(screen)
    Echoes::Client.bg_clear(io: @io)
    parser.feed(@io.string)
    assert_nil screen.background
  end

  test "styled_text emits OSC 66 with scale only" do
    Echoes::Client.styled_text("Hi", scale: 2, io: @io)
    assert_equal "\e]66;s=2;Hi\a", @io.string
  end

  test "styled_text includes family when given" do
    Echoes::Client.styled_text("Title", scale: 3, family: "Helvetica Neue", io: @io)
    assert_equal "\e]66;s=3:f=Helvetica Neue;Title\a", @io.string
  end

  test "styled_text roundtrips through the parser carrying family" do
    Echoes::Client.styled_text("X", scale: 2, family: "Menlo", io: @io)
    screen = Echoes::Screen.new(rows: 5, cols: 10)
    parser = Echoes::Parser.new(screen)
    parser.feed(@io.string)
    mc = screen.grid[0][0].multicell
    assert_equal "Menlo", mc[:family]
    assert_equal 2, mc[:scale]
  end
end
