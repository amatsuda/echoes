# frozen_string_literal: true

require "test_helper"

class Echoes::CellTest < Test::Unit::TestCase
  test "default values" do
    cell = Echoes::Cell.new
    assert_equal(" ", cell.char)
    assert_nil(cell.fg)
    assert_nil(cell.bg)
    assert_equal(false, cell.bold)
    assert_equal(false, cell.underline)
    assert_equal(false, cell.inverse)
  end

  test "initialize with char" do
    cell = Echoes::Cell.new("A")
    assert_equal("A", cell.char)
  end

  test "reset!" do
    cell = Echoes::Cell.new("X", fg: 1, bg: 2, bold: true, underline: true, inverse: true)
    cell.reset!
    assert_equal(" ", cell.char)
    assert_nil(cell.fg)
    assert_nil(cell.bg)
    assert_equal(false, cell.bold)
    assert_equal(false, cell.underline)
    assert_equal(false, cell.inverse)
  end

  test "copy_from" do
    src = Echoes::Cell.new("A", fg: 3, bg: 4, bold: true, underline: false, inverse: true)
    dst = Echoes::Cell.new
    dst.copy_from(src)
    assert_equal("A", dst.char)
    assert_equal(3, dst.fg)
    assert_equal(4, dst.bg)
    assert_equal(true, dst.bold)
    assert_equal(false, dst.underline)
    assert_equal(true, dst.inverse)
  end
end
