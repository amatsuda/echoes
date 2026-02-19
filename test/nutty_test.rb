# frozen_string_literal: true

require "test_helper"

class NuttyTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Nutty.const_defined?(:VERSION)
    end
  end

  test "has all components" do
    assert { ::Nutty.const_defined?(:Cell) }
    assert { ::Nutty.const_defined?(:Cursor) }
    assert { ::Nutty.const_defined?(:Screen) }
    assert { ::Nutty.const_defined?(:Parser) }
    assert { ::Nutty.const_defined?(:Terminal) }
  end
end
