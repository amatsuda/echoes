# frozen_string_literal: true

require "test_helper"
require "echoes/animation_ticker"

class Echoes::AnimationTickerTest < Test::Unit::TestCase
  T = Echoes::AnimationTicker

  # ---- should_advance? ----

  def test_returns_false_when_elapsed_is_under_duration
    assert_false T.should_advance?(0.04, 0.05)
  end

  def test_returns_true_when_elapsed_meets_duration_exactly
    assert T.should_advance?(0.05, 0.05)
  end

  def test_returns_true_when_elapsed_exceeds_duration
    assert T.should_advance?(0.10, 0.05)
  end

  def test_returns_false_for_nil_duration
    assert_false T.should_advance?(1.0, nil)
  end

  def test_returns_false_for_zero_duration
    # Some GIFs report 0 ms per frame; treat as "don't spin".
    assert_false T.should_advance?(1.0, 0.0)
  end

  def test_returns_false_for_negative_duration
    assert_false T.should_advance?(1.0, -0.05)
  end

  # ---- next_frame_index ----

  def test_advances_to_next_frame
    assert_equal 1, T.next_frame_index(0, 5)
    assert_equal 3, T.next_frame_index(2, 5)
  end

  def test_wraps_at_last_frame
    assert_equal 0, T.next_frame_index(4, 5)
  end

  def test_total_of_one_stays_at_zero
    # Static-image edge case — caller shouldn't be ticking, but
    # guard anyway so a misuse doesn't silently produce frame 1.
    assert_equal 0, T.next_frame_index(0, 1)
  end

  def test_total_of_zero_or_nil_stays_at_zero
    assert_equal 0, T.next_frame_index(0, 0)
    assert_equal 0, T.next_frame_index(7, nil)
  end
end
