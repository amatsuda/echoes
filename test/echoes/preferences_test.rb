# frozen_string_literal: true

require "test_helper"
require "echoes/preferences"

class Echoes::PreferencesTest < Test::Unit::TestCase
  # Round-trips a key through the real NSUserDefaults backing store.
  # Each test uses a fresh random key to avoid colliding with others.

  def test_fetch_double_returns_default_when_key_is_unset
    key = unique_key
    assert_equal 99.5, Echoes::Preferences.fetch_double(key, default: 99.5)
  end

  def test_set_then_fetch_round_trip
    key = unique_key
    Echoes::Preferences.set_double(key, 17.25)
    assert_equal 17.25, Echoes::Preferences.fetch_double(key, default: 0.0)
  ensure
    Echoes::Preferences.delete(key)
  end

  def test_delete_clears_a_set_key
    key = unique_key
    Echoes::Preferences.set_double(key, 42.0)
    Echoes::Preferences.delete(key)
    assert_equal -1.0, Echoes::Preferences.fetch_double(key, default: -1.0)
  end

  def test_zero_is_distinguishable_from_missing
    # doubleForKey: returns 0.0 for both missing and explicitly-zero
    # entries; fetch_double goes through objectForKey: so an explicit
    # 0.0 round-trips as 0.0 instead of falling back to the default.
    key = unique_key
    Echoes::Preferences.set_double(key, 0.0)
    assert_equal 0.0, Echoes::Preferences.fetch_double(key, default: 99.0)
  ensure
    Echoes::Preferences.delete(key)
  end

  private

  def unique_key
    "echoes_test_#{Process.pid}_#{rand(1_000_000)}"
  end
end
