# frozen_string_literal: true

require "test_helper"
require "echoes/svg_path_parser"

class Echoes::SvgPathParserTest < Test::Unit::TestCase
  P = Echoes::SvgPathParser

  # ---- single commands ----

  def test_moveto_absolute
    assert_equal [[:M, [10.0, 20.0]]], P.parse('M 10 20')
  end

  def test_moveto_relative
    assert_equal [[:m, [10.0, 20.0]]], P.parse('m 10 20')
  end

  def test_lineto_absolute
    assert_equal [[:M, [0.0, 0.0]], [:L, [10.0, 10.0]]], P.parse('M 0 0 L 10 10')
  end

  def test_horizontal_vertical_line
    assert_equal [[:M, [0.0, 0.0]], [:H, [50.0]], [:V, [60.0]]],
                 P.parse('M 0 0 H 50 V 60')
  end

  def test_cubic_bezier
    assert_equal [[:M, [0.0, 0.0]], [:C, [10.0, 20.0, 30.0, 40.0, 50.0, 60.0]]],
                 P.parse('M 0 0 C 10 20 30 40 50 60')
  end

  def test_quadratic_bezier
    assert_equal [[:M, [0.0, 0.0]], [:Q, [10.0, 20.0, 30.0, 40.0]]],
                 P.parse('M 0 0 Q 10 20 30 40')
  end

  def test_smooth_curves
    assert_equal [[:M, [0.0, 0.0]], [:S, [10.0, 20.0, 30.0, 40.0]]],
                 P.parse('M 0 0 S 10 20 30 40')
    assert_equal [[:M, [0.0, 0.0]], [:T, [10.0, 20.0]]],
                 P.parse('M 0 0 T 10 20')
  end

  def test_arc
    # rx ry x-axis-rot large-arc-flag sweep-flag x y
    assert_equal [[:M, [0.0, 0.0]], [:A, [25.0, 25.0, 0.0, 0.0, 1.0, 50.0, 50.0]]],
                 P.parse('M 0 0 A 25 25 0 0 1 50 50')
  end

  def test_closepath
    assert_equal [[:M, [0.0, 0.0]], [:L, [10.0, 0.0]], [:Z, []]],
                 P.parse('M 0 0 L 10 0 Z')
    # lowercase z is equivalent
    assert_equal [[:M, [0.0, 0.0]], [:z, []]], P.parse('M 0 0 z')
  end

  # ---- separators ----

  def test_commas_as_separators
    assert_equal [[:M, [0.0, 0.0]], [:L, [10.0, 20.0]]],
                 P.parse('M0,0 L10,20')
  end

  def test_sign_as_separator
    # M 10,-5 with no whitespace.
    assert_equal [[:M, [10.0, -5.0]]], P.parse('M10-5')
    assert_equal [[:M, [0.0, 0.0]], [:l, [-1.0, -1.0]]], P.parse('M0 0l-1-1')
  end

  def test_minimal_whitespace
    # Common-output style: no spaces between command and first number.
    assert_equal [[:M, [1.0, 2.0]], [:L, [3.0, 4.0]]], P.parse('M1 2L3 4')
  end

  # ---- numeric forms ----

  def test_decimal_numbers
    assert_equal [[:M, [1.5, 2.25]]], P.parse('M 1.5 2.25')
  end

  def test_leading_decimal
    assert_equal [[:M, [0.5, 0.25]]], P.parse('M .5 .25')
  end

  def test_negative_numbers
    assert_equal [[:M, [-1.0, -2.5]]], P.parse('M -1 -2.5')
  end

  def test_scientific_notation
    assert_equal [[:M, [100.0, 0.0]]], P.parse('M 1e2 0')
    assert_equal [[:M, [100.0, 0.0]]], P.parse('M 1E2 0')
    assert_equal [[:M, [0.001, 0.0]]], P.parse('M 1e-3 0')
  end

  # ---- implicit continuation ----

  def test_implicit_lineto_after_moveto
    # Per spec, additional pairs after M become implicit L.
    assert_equal [[:M, [0.0, 0.0]], [:L, [10.0, 10.0]], [:L, [20.0, 20.0]]],
                 P.parse('M 0 0 10 10 20 20')
  end

  def test_implicit_lineto_after_relative_moveto
    # After m, implicit continuation is l (relative), not L.
    assert_equal [[:m, [0.0, 0.0]], [:l, [10.0, 10.0]]],
                 P.parse('m 0 0 10 10')
  end

  def test_implicit_lineto_after_lineto
    assert_equal [[:M, [0.0, 0.0]], [:L, [10.0, 10.0]], [:L, [20.0, 20.0]]],
                 P.parse('M 0 0 L 10 10 20 20')
  end

  def test_implicit_curveto
    # C commands can also be implicitly continued.
    assert_equal [
      [:M, [0.0, 0.0]],
      [:C, [10.0, 0.0, 20.0, 10.0, 30.0, 10.0]],
      [:C, [40.0, 10.0, 50.0, 0.0, 60.0, 0.0]],
    ], P.parse('M 0 0 C 10 0 20 10 30 10 40 10 50 0 60 0')
  end

  # ---- bail cases ----

  def test_empty_returns_nil
    assert_nil P.parse('')
    assert_nil P.parse('   ')
    assert_nil P.parse(nil)
  end

  def test_non_moveto_start_returns_nil
    assert_nil P.parse('L 10 10')
    assert_nil P.parse('Z')
  end

  def test_unknown_command_returns_nil
    assert_nil P.parse('M 0 0 X 10 10')
  end

  def test_truncated_operand_returns_nil
    # L takes 2 operands; only 1 supplied.
    assert_nil P.parse('M 0 0 L 10')
    # C takes 6; only 5 supplied.
    assert_nil P.parse('M 0 0 C 10 20 30 40 50')
  end

  def test_junk_characters_return_nil
    assert_nil P.parse('M 0 0 ! 10 10')
    assert_nil P.parse('M 0 0; L 10 10')
  end
end
