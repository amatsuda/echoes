# frozen_string_literal: true

require "test_helper"

class Echoes::TabTest < Test::Unit::TestCase
  setup do
    @tab = Echoes::Tab.new(command: "/bin/cat", rows: 24, cols: 80)
  end

  teardown do
    @tab.close
  end

  test "initialize creates screen with given dimensions" do
    assert_instance_of(Echoes::Screen, @tab.screen)
    assert_equal(24, @tab.screen.rows)
    assert_equal(80, @tab.screen.cols)
  end

  test "initialize creates parser" do
    assert_instance_of(Echoes::Parser, @tab.parser)
  end

  test "initialize spawns pty" do
    assert_not_nil(@tab.pty_read)
    assert_not_nil(@tab.pty_write)
    assert_not_nil(@tab.pty_pid)
  end

  test "initialize sets winsize" do
    assert_equal([24, 80], @tab.pty_read.winsize)
  end

  test "initialize sets scroll defaults" do
    assert_equal(0, @tab.scroll_offset)
    assert_equal(0.0, @tab.scroll_accum)
  end

  test "initialize sets title from command basename" do
    assert_equal("cat", @tab.title)
  end

  test "initialize with path sets title to basename" do
    tab = Echoes::Tab.new(command: "/usr/bin/env", rows: 5, cols: 10)
    assert_equal("env", tab.title)
    tab.close
  end

  test "alive? returns true for running process" do
    assert_equal(true, @tab.alive?)
  end

  test "alive? returns false after process exits" do
    tab = Echoes::Tab.new(command: "/usr/bin/true", rows: 5, cols: 10)
    sleep 0.2
    assert_equal(false, tab.alive?)
    tab.close
  end

  test "resize changes screen dimensions" do
    @tab.resize(30, 100)
    assert_equal(30, @tab.screen.rows)
    assert_equal(100, @tab.screen.cols)
  end

  test "resize updates pty winsize" do
    @tab.resize(30, 100)
    assert_equal([30, 100], @tab.pty_read.winsize)
  end

  test "resize does not raise after close" do
    @tab.close
    assert_nothing_raised do
      @tab.resize(30, 100)
    end
  end

  test "close closes pty streams" do
    @tab.close
    assert_equal(true, @tab.pty_write.closed?)
    assert_equal(true, @tab.pty_read.closed?)
  end

  test "close can be called multiple times" do
    assert_nothing_raised do
      @tab.close
      @tab.close
    end
  end

  test "pty communication" do
    @tab.pty_write.print("hello")
    output = @tab.pty_read.readpartial(1024)
    assert_equal("hello", output)
  end

  # --- PaneTree integration ---

  test "has a pane_tree" do
    assert_instance_of(Echoes::PaneTree, @tab.pane_tree)
  end

  test "active_pane returns the active pane" do
    assert_instance_of(Echoes::Pane, @tab.active_pane)
  end

  test "panes returns all panes" do
    assert_equal(1, @tab.panes.size)
    assert_instance_of(Echoes::Pane, @tab.panes.first)
  end

  test "split_vertical creates two panes" do
    @tab.split_vertical
    assert_equal(2, @tab.panes.size)
    assert_equal(false, @tab.pane_tree.single_pane?)
  end

  test "split_horizontal creates two panes" do
    @tab.split_horizontal
    assert_equal(2, @tab.panes.size)
    assert_equal(false, @tab.pane_tree.single_pane?)
  end

  test "split_vertical sets new pane as active" do
    original = @tab.active_pane
    @tab.split_vertical
    assert_not_equal(original, @tab.active_pane)
  end

  test "close_active_pane returns false for single pane" do
    assert_equal(false, @tab.close_active_pane)
    assert_equal(1, @tab.panes.size)
  end

  test "close_active_pane removes pane and returns true" do
    @tab.split_vertical
    assert_equal(2, @tab.panes.size)
    result = @tab.close_active_pane
    assert_equal(true, result)
    assert_equal(1, @tab.panes.size)
  end

  test "next_pane cycles to next" do
    @tab.split_vertical
    pane1 = @tab.panes[0]
    pane2 = @tab.panes[1]
    @tab.pane_tree.active_pane = pane1
    @tab.next_pane
    assert_equal(pane2, @tab.active_pane)
  end

  test "prev_pane cycles to previous" do
    @tab.split_vertical
    pane1 = @tab.panes[0]
    pane2 = @tab.panes[1]
    @tab.pane_tree.active_pane = pane2
    @tab.prev_pane
    assert_equal(pane1, @tab.active_pane)
  end

  test "screen delegates to active pane" do
    assert_equal(@tab.active_pane.screen, @tab.screen)
  end

  test "parser delegates to active pane" do
    assert_equal(@tab.active_pane.parser, @tab.parser)
  end

  test "resize resizes all panes" do
    @tab.split_vertical
    @tab.resize(30, 100)
    # All panes should have been resized to fit within the new dimensions
    @tab.panes.each do |pane|
      assert(pane.screen.rows > 0)
      assert(pane.screen.cols > 0)
    end
  end
end
