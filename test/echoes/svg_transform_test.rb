# frozen_string_literal: true

require "test_helper"
require "echoes/svg_transform"

class Echoes::SvgTransformTest < Test::Unit::TestCase
  T = Echoes::SvgTransform

  def test_translate_with_two_args
    assert_equal [[:translate, [10.0, 20.0]]], T.parse('translate(10, 20)')
    assert_equal [[:translate, [10.0, 20.0]]], T.parse('translate(10 20)')
  end

  def test_translate_with_one_arg_defaults_y_to_zero
    assert_equal [[:translate, [10.0, 0.0]]], T.parse('translate(10)')
  end

  def test_scale_with_two_args
    assert_equal [[:scale, [2.0, 3.0]]], T.parse('scale(2, 3)')
  end

  def test_scale_with_one_arg_uniform
    assert_equal [[:scale, [2.0, 2.0]]], T.parse('scale(2)')
  end

  def test_rotate_degrees_only
    assert_equal [[:rotate, [45.0, 0.0, 0.0]]], T.parse('rotate(45)')
  end

  def test_rotate_around_point
    assert_equal [[:rotate, [90.0, 50.0, 50.0]]], T.parse('rotate(90 50 50)')
  end

  def test_rotate_with_two_args_returns_nil
    # Spec disallows 2-arg rotate — it's either 1 or 3.
    assert_nil T.parse('rotate(45 10)')
  end

  def test_matrix
    assert_equal [[:matrix, [1.0, 0.0, 0.0, 1.0, 5.0, 10.0]]],
                 T.parse('matrix(1 0 0 1 5 10)')
  end

  def test_matrix_wrong_arity_returns_nil
    assert_nil T.parse('matrix(1 2 3)')
    assert_nil T.parse('matrix(1 2 3 4 5 6 7)')
  end

  def test_skew
    assert_equal [[:skewx, [15.0]]], T.parse('skewX(15)')
    assert_equal [[:skewy, [15.0]]], T.parse('skewY(15)')
  end

  def test_chained_transforms
    ops = T.parse('translate(10 20) scale(2) rotate(45)')
    assert_equal [
      [:translate, [10.0, 20.0]],
      [:scale, [2.0, 2.0]],
      [:rotate, [45.0, 0.0, 0.0]],
    ], ops
  end

  def test_decimal_and_negative_args
    assert_equal [[:translate, [-1.5, 2.25]]], T.parse('translate(-1.5, 2.25)')
  end

  def test_scientific_notation
    assert_equal [[:scale, [1.0e2, 1.0e2]]], T.parse('scale(1e2)')
  end

  def test_unknown_function_returns_nil
    assert_nil T.parse('warp(1 2)')
    assert_nil T.parse('translate(10) warp(1)')   # one bad fn kills the chain
  end

  def test_empty_returns_nil
    assert_nil T.parse('')
    assert_nil T.parse('   ')
    assert_nil T.parse(nil)
  end
end
