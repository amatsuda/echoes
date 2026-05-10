# frozen_string_literal: true

require "test_helper"
require "echoes/configuration"

class Echoes::KeybindTest < Test::Unit::TestCase
  def setup
    @cfg = Echoes::Configuration.new
  end

  # Modifier flag constants live on AppKit but are echoed in
  # Configuration::SHORTCUT_MODIFIERS so config can resolve
  # shortcuts without loading objc.rb. Pin the bit positions.
  SHIFT   = 1 << 17
  CONTROL = 1 << 18
  OPTION  = 1 << 19
  COMMAND = 1 << 20

  test "parse_shortcut returns key + 0 modifiers for plain keys" do
    assert_equal({key: 'a', modifiers: 0}, @cfg.parse_shortcut('a'))
  end

  test "parse_shortcut handles Cmd+Letter" do
    assert_equal({key: 's', modifiers: COMMAND}, @cfg.parse_shortcut('Cmd+S'))
  end

  test "parse_shortcut combines multiple modifiers" do
    assert_equal({key: 'p', modifiers: COMMAND | SHIFT},
                 @cfg.parse_shortcut('Cmd+Shift+P'))
    assert_equal({key: 't', modifiers: COMMAND | CONTROL | OPTION},
                 @cfg.parse_shortcut('Cmd+Ctrl+Option+T'))
  end

  test "parse_shortcut is case-insensitive and accepts spaces" do
    assert_equal({key: 'x', modifiers: COMMAND | SHIFT},
                 @cfg.parse_shortcut('cmd + SHIFT + X'))
  end

  test "parse_shortcut recognizes Cmd / Command / Super as aliases" do
    %w[Cmd Command Super].each do |alias_name|
      assert_equal COMMAND, @cfg.parse_shortcut("#{alias_name}+X")[:modifiers]
    end
  end

  test "parse_shortcut returns the disabled sentinel for empty / nil input" do
    assert_equal({key: '', modifiers: 0}, @cfg.parse_shortcut(''))
    assert_equal({key: '', modifiers: 0}, @cfg.parse_shortcut(nil))
  end

  test "keybind stores an override keyed by action symbol" do
    @cfg.keybind 'Cmd+Shift+T', :new_tab
    assert_equal({key: 't', modifiers: COMMAND | SHIFT}, @cfg.keybind_for(:new_tab))
  end

  test "keybind with an empty string disables the action" do
    @cfg.keybind '', :toggle_pointer
    assert_equal({key: '', modifiers: 0}, @cfg.keybind_for(:toggle_pointer))
  end

  test "keybind_for returns nil when no override is set" do
    assert_nil @cfg.keybind_for(:not_bound)
  end

  test "keybind coerces String keys to Symbol" do
    @cfg.keybind 'Cmd+R', 'reset_font_size'
    assert_equal({key: 'r', modifiers: COMMAND}, @cfg.keybind_for(:reset_font_size))
  end
end
