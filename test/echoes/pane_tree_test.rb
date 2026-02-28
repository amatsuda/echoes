# frozen_string_literal: true

require "test_helper"

class Echoes::PaneTreeTest < Test::Unit::TestCase
  setup do
    @pane1 = Echoes::Pane.new(command: "/bin/cat", rows: 24, cols: 80)
    @tree = Echoes::PaneTree.new(@pane1)
  end

  teardown do
    @tree.panes.each(&:close)
  end

  test "initialize creates a single pane tree" do
    assert_equal(true, @tree.single_pane?)
    assert_equal(1, @tree.pane_count)
    assert_equal(@pane1, @tree.active_pane)
  end

  test "panes returns all panes" do
    assert_equal([@pane1], @tree.panes)
  end

  test "layout returns full area for single pane" do
    rects = @tree.layout(0, 0, 80, 24)
    assert_equal(1, rects.size)
    assert_equal({pane: @pane1, x: 0, y: 0, w: 80, h: 24}, rects[0])
  end

  test "split vertical creates two panes side by side" do
    pane2 = Echoes::Pane.new(command: "/bin/cat", rows: 24, cols: 40)
    @tree.split(@pane1, :vertical, pane2)

    assert_equal(false, @tree.single_pane?)
    assert_equal(2, @tree.pane_count)
    assert_equal(pane2, @tree.active_pane)

    rects = @tree.layout(0, 0, 80, 24)
    assert_equal(2, rects.size)
    assert_equal(@pane1, rects[0][:pane])
    assert_equal(pane2, rects[1][:pane])
    # Left pane gets half the width
    assert_equal(0, rects[0][:x])
    assert_equal(40, rects[0][:w])
    # Right pane gets the other half
    assert_equal(40, rects[1][:x])
    assert_equal(40, rects[1][:w])
    # Both have full height
    assert_equal(24, rects[0][:h])
    assert_equal(24, rects[1][:h])
  end

  test "split horizontal creates two panes stacked" do
    pane2 = Echoes::Pane.new(command: "/bin/cat", rows: 12, cols: 80)
    @tree.split(@pane1, :horizontal, pane2)

    rects = @tree.layout(0, 0, 80, 24)
    assert_equal(2, rects.size)
    assert_equal(@pane1, rects[0][:pane])
    assert_equal(pane2, rects[1][:pane])
    # Top pane
    assert_equal(0, rects[0][:y])
    assert_equal(12, rects[0][:h])
    # Bottom pane
    assert_equal(12, rects[1][:y])
    assert_equal(12, rects[1][:h])
    # Both have full width
    assert_equal(80, rects[0][:w])
    assert_equal(80, rects[1][:w])
  end

  test "remove promotes sibling to parent's position" do
    pane2 = Echoes::Pane.new(command: "/bin/cat", rows: 24, cols: 40)
    @tree.split(@pane1, :vertical, pane2)
    @tree.remove(@pane1)
    @pane1.close

    assert_equal(true, @tree.single_pane?)
    assert_equal(1, @tree.pane_count)
    assert_equal([pane2], @tree.panes)
  end

  test "remove does nothing for single pane" do
    result = @tree.remove(@pane1)
    assert_nil(result)
    assert_equal(true, @tree.single_pane?)
  end

  test "remove sets active_pane to first remaining pane when removing active" do
    pane2 = Echoes::Pane.new(command: "/bin/cat", rows: 24, cols: 40)
    @tree.split(@pane1, :vertical, pane2)
    @tree.active_pane = pane2
    @tree.remove(pane2)
    pane2.close

    assert_equal(@pane1, @tree.active_pane)
  end

  test "next_pane cycles forward" do
    pane2 = Echoes::Pane.new(command: "/bin/cat", rows: 24, cols: 40)
    @tree.split(@pane1, :vertical, pane2)

    assert_equal(pane2, @tree.next_pane(@pane1))
    assert_equal(@pane1, @tree.next_pane(pane2))
  end

  test "prev_pane cycles backward" do
    pane2 = Echoes::Pane.new(command: "/bin/cat", rows: 24, cols: 40)
    @tree.split(@pane1, :vertical, pane2)

    assert_equal(@pane1, @tree.prev_pane(pane2))
    assert_equal(pane2, @tree.prev_pane(@pane1))
  end

  test "nested splits produce correct layout" do
    # Split pane1 vertically: pane1 | pane2
    pane2 = Echoes::Pane.new(command: "/bin/cat", rows: 24, cols: 40)
    @tree.split(@pane1, :vertical, pane2)

    # Split pane2 horizontally: pane2_top / pane3
    pane3 = Echoes::Pane.new(command: "/bin/cat", rows: 12, cols: 40)
    @tree.split(pane2, :horizontal, pane3)

    assert_equal(3, @tree.pane_count)
    rects = @tree.layout(0, 0, 80, 24)
    assert_equal(3, rects.size)

    # pane1 is left half
    assert_equal(@pane1, rects[0][:pane])
    assert_equal(0, rects[0][:x])
    assert_equal(40, rects[0][:w])
    assert_equal(24, rects[0][:h])

    # pane2 is right-top
    assert_equal(pane2, rects[1][:pane])
    assert_equal(40, rects[1][:x])
    assert_equal(40, rects[1][:w])
    assert_equal(12, rects[1][:h])

    # pane3 is right-bottom
    assert_equal(pane3, rects[2][:pane])
    assert_equal(40, rects[2][:x])
    assert_equal(40, rects[2][:w])
    assert_equal(12, rects[2][:h])
    assert_equal(12, rects[2][:y])
  end

  test "panes returns in-order traversal" do
    pane2 = Echoes::Pane.new(command: "/bin/cat", rows: 24, cols: 40)
    @tree.split(@pane1, :vertical, pane2)
    pane3 = Echoes::Pane.new(command: "/bin/cat", rows: 12, cols: 40)
    @tree.split(pane2, :horizontal, pane3)

    assert_equal([@pane1, pane2, pane3], @tree.panes)
  end

  test "layout with offset" do
    rects = @tree.layout(5, 10, 80, 24)
    assert_equal(1, rects.size)
    assert_equal(5, rects[0][:x])
    assert_equal(10, rects[0][:y])
  end
end
