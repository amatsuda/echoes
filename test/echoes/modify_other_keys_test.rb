# frozen_string_literal: true

require "test_helper"

class Echoes::ModifyOtherKeysTest < Test::Unit::TestCase
  KK  = Echoes::KittyKeyboard
  MOK = Echoes::ModifyOtherKeys

  def key(codepoint = nil, text: nil, mods: 0, functional: nil, shifted: nil)
    if text.nil? && codepoint && !functional && mods & (KK::CTRL | KK::ALT | KK::SUPER) == 0
      text = [mods & KK::SHIFT != 0 && shifted ? shifted : codepoint].pack('U')
    end
    KK::Key.new(codepoint: codepoint, functional: functional, shifted: shifted,
                text: text, mods: mods, event: :press)
  end

  test "level 0 leaves everything to the legacy bytes" do
    assert_equal :legacy, MOK.encode(key(97, mods: KK::CTRL), 0)
    assert_equal :legacy, MOK.encode(key(functional: :enter, mods: KK::SHIFT), 0)
  end

  test "unmodified keys and keys with only lock modifiers are legacy at every level" do
    assert_equal :legacy, MOK.encode(key(97), 2)
    assert_equal :legacy, MOK.encode(key(97, mods: KK::CAPS_LOCK), 2)
    assert_equal :legacy, MOK.encode(key(functional: :enter), 2)
  end

  test "level 2 encodes every ctrl, alt and super combination in xterm's form" do
    assert_equal "\e[27;5;97~", MOK.encode(key(97, mods: KK::CTRL), 2)
    assert_equal "\e[27;3;97~", MOK.encode(key(97, mods: KK::ALT), 2)
    assert_equal "\e[27;7;97~", MOK.encode(key(97, mods: KK::CTRL | KK::ALT), 2)
    assert_equal "\e[27;9;97~", MOK.encode(key(97, mods: KK::SUPER), 2)
    assert_equal "\e[27;5;13~", MOK.encode(key(functional: :enter, mods: KK::CTRL), 2)
    assert_equal "\e[27;5;9~", MOK.encode(key(functional: :tab, mods: KK::CTRL), 2)
    assert_equal "\e[27;5;127~", MOK.encode(key(functional: :backspace, mods: KK::CTRL), 2)
    assert_equal "\e[27;5;27~", MOK.encode(key(functional: :escape, mods: KK::CTRL), 2)
  end

  test "the code is the key as Shift leaves it" do
    assert_equal "\e[27;6;65~", MOK.encode(key(97, mods: KK::CTRL | KK::SHIFT, shifted: 65), 2)
    assert_equal "\e[27;5;97~", MOK.encode(key(97, mods: KK::CTRL, shifted: 65), 2)
    assert_equal "\e[27;6;64~", MOK.encode(key(50, mods: KK::CTRL | KK::SHIFT, shifted: 64), 2)
  end

  test "Shift alone is text on a text key but encoded on the keys that have no shifted text" do
    assert_equal :legacy, MOK.encode(key(97, mods: KK::SHIFT, shifted: 65), 2)
    assert_equal "\e[27;2;13~", MOK.encode(key(functional: :enter, mods: KK::SHIFT), 2)
    assert_equal "\e[27;2;9~", MOK.encode(key(functional: :tab, mods: KK::SHIFT), 2)
    assert_equal "\e[27;2;127~", MOK.encode(key(functional: :backspace, mods: KK::SHIFT), 2)
    assert_equal "\e[27;2;27~", MOK.encode(key(functional: :escape, mods: KK::SHIFT), 2)
    assert_equal "\e[27;2;32~", MOK.encode(key(32, text: ' ', mods: KK::SHIFT), 2)
  end

  test "lock modifiers are not part of the parameter" do
    assert_equal "\e[27;5;97~", MOK.encode(key(97, mods: KK::CTRL | KK::CAPS_LOCK), 2)
  end

  test "cursor, function and keypad keys are someone else's business" do
    assert_equal :legacy, MOK.encode(key(functional: :up, mods: KK::CTRL), 2)
    assert_equal :legacy, MOK.encode(key(functional: :f5, mods: KK::SHIFT), 2)
    assert_equal :legacy, MOK.encode(key(functional: :kp_enter, mods: KK::CTRL), 2)
    assert_equal :legacy, MOK.encode(key(functional: :kp_1, text: '1', mods: KK::CTRL), 2)
    assert_equal :legacy, MOK.encode(key(functional: :left_shift, mods: KK::SHIFT), 2)
  end

  test "level 1 keeps the combinations the legacy bytes already express" do
    assert_equal :legacy, MOK.encode(key(97, mods: KK::CTRL), 1)                 # ^A
    assert_equal :legacy, MOK.encode(key(32, mods: KK::CTRL), 1)                 # NUL
    assert_equal :legacy, MOK.encode(key(91, mods: KK::CTRL), 1)                 # Ctrl+[ is ESC
    assert_equal :legacy, MOK.encode(key(51, mods: KK::CTRL), 1)                 # Ctrl+3 is ESC
    assert_equal :legacy, MOK.encode(key(97, mods: KK::ALT), 1)                  # ESC a
    assert_equal :legacy, MOK.encode(key(97, mods: KK::CTRL | KK::ALT), 1)       # ESC ^A
    assert_equal :legacy, MOK.encode(key(functional: :tab, mods: KK::SHIFT), 1)  # CSI Z
    assert_equal :legacy, MOK.encode(key(functional: :enter, mods: KK::ALT), 1)  # ESC CR
    assert_equal :legacy, MOK.encode(key(functional: :backspace, mods: KK::CTRL), 1)  # BS
    assert_equal :legacy, MOK.encode(key(functional: :backspace, mods: KK::ALT), 1)   # ESC DEL
    assert_equal :legacy, MOK.encode(key(functional: :escape, mods: KK::ALT), 1)      # ESC ESC
  end

  test "level 1 encodes the combinations the legacy bytes lose" do
    assert_equal "\e[27;6;65~", MOK.encode(key(97, mods: KK::CTRL | KK::SHIFT, shifted: 65), 1)
    assert_equal "\e[27;5;49~", MOK.encode(key(49, mods: KK::CTRL), 1)           # Ctrl+1 has no C0
    assert_equal "\e[27;5;44~", MOK.encode(key(44, mods: KK::CTRL), 1)           # Ctrl+,
    assert_equal "\e[27;2;13~", MOK.encode(key(functional: :enter, mods: KK::SHIFT), 1)
    assert_equal "\e[27;5;13~", MOK.encode(key(functional: :enter, mods: KK::CTRL), 1)
    assert_equal "\e[27;5;9~", MOK.encode(key(functional: :tab, mods: KK::CTRL), 1)
    assert_equal "\e[27;6;9~", MOK.encode(key(functional: :tab, mods: KK::CTRL | KK::SHIFT), 1)
    assert_equal "\e[27;2;127~", MOK.encode(key(functional: :backspace, mods: KK::SHIFT), 1)
    assert_equal "\e[27;6;27~", MOK.encode(key(functional: :escape, mods: KK::CTRL | KK::SHIFT), 1)
    assert_equal "\e[27;9;97~", MOK.encode(key(97, mods: KK::SUPER), 1)
  end
end
