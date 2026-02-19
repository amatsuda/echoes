# frozen_string_literal: true

require "test_helper"

class EchoesTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Echoes.const_defined?(:VERSION)
    end
  end

  test "has all components" do
    assert { ::Echoes.const_defined?(:Cell) }
    assert { ::Echoes.const_defined?(:Cursor) }
    assert { ::Echoes.const_defined?(:Screen) }
    assert { ::Echoes.const_defined?(:Parser) }
    assert { ::Echoes.const_defined?(:Terminal) }
  end
end
