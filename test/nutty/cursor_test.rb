# frozen_string_literal: true

require "test_helper"

class Nutty::CursorTest < Test::Unit::TestCase
  test "default position" do
    cursor = Nutty::Cursor.new
    assert_equal(0, cursor.row)
    assert_equal(0, cursor.col)
    assert_equal(true, cursor.visible)
  end

  test "initialize with position" do
    cursor = Nutty::Cursor.new(row: 5, col: 10)
    assert_equal(5, cursor.row)
    assert_equal(10, cursor.col)
  end

  test "move_to" do
    cursor = Nutty::Cursor.new
    cursor.move_to(3, 7)
    assert_equal(3, cursor.row)
    assert_equal(7, cursor.col)
  end
end
