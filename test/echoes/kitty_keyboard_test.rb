# frozen_string_literal: true

require "test_helper"

class Echoes::KittyKeyboardTest < Test::Unit::TestCase
  KK = Echoes::KittyKeyboard

  def key(codepoint = nil, text: nil, mods: 0, event: :press, functional: nil, shifted: nil, base: nil)
    text = [codepoint].pack('U') if text.nil? && codepoint && !functional && mods & (KK::CTRL | KK::ALT | KK::SUPER) == 0
    KK::Key.new(codepoint: codepoint, functional: functional, shifted: shifted, base: base,
                text: text, mods: mods, event: event)
  end

  def fn(name, mods: 0, event: :press, text: nil)
    key(functional: name, mods: mods, event: event, text: text)
  end

  # --- no flags: everything stays legacy ---

  test "with no flags every press is left to the legacy encoder" do
    assert_equal :legacy, KK.encode(key(97), 0)
    assert_equal :legacy, KK.encode(key(97, mods: KK::CTRL), 0)
    assert_equal :legacy, KK.encode(fn(:escape), 0)
    assert_equal :legacy, KK.encode(fn(:up, mods: KK::SHIFT), 0)
  end

  test "with no flags releases send nothing" do
    assert_nil KK.encode(key(97, event: :release), 0)
    assert_nil KK.encode(fn(:up, event: :release), 0)
  end

  # --- disambiguate ---

  test "disambiguate leaves plain text keys to the legacy path" do
    assert_equal :legacy, KK.encode(key(97), KK::DISAMBIGUATE)
    assert_equal :legacy, KK.encode(key(97, text: 'A', mods: KK::SHIFT), KK::DISAMBIGUATE)
    assert_equal :legacy, KK.encode(key(32), KK::DISAMBIGUATE)
  end

  test "disambiguate encodes ctrl, alt and super combinations with the unshifted key" do
    assert_equal "\e[97;5u", KK.encode(key(97, mods: KK::CTRL), KK::DISAMBIGUATE)
    assert_equal "\e[97;3u", KK.encode(key(97, mods: KK::ALT), KK::DISAMBIGUATE)
    assert_equal "\e[97;6u", KK.encode(key(97, mods: KK::CTRL | KK::SHIFT), KK::DISAMBIGUATE)
    assert_equal "\e[97;7u", KK.encode(key(97, mods: KK::CTRL | KK::ALT), KK::DISAMBIGUATE)
    assert_equal "\e[97;4u", KK.encode(key(97, mods: KK::ALT | KK::SHIFT), KK::DISAMBIGUATE)
    assert_equal "\e[97;9u", KK.encode(key(97, mods: KK::SUPER), KK::DISAMBIGUATE)
  end

  test "disambiguate does not report lock modifiers on text keys" do
    assert_equal "\e[97;5u", KK.encode(key(97, mods: KK::CTRL | KK::CAPS_LOCK), KK::DISAMBIGUATE)
  end

  test "escape becomes CSI 27 u" do
    assert_equal "\e[27u", KK.encode(fn(:escape), KK::DISAMBIGUATE)
    assert_equal "\e[27;2u", KK.encode(fn(:escape, mods: KK::SHIFT), KK::DISAMBIGUATE)
  end

  test "enter, tab and backspace stay legacy unless modified" do
    assert_equal :legacy, KK.encode(fn(:enter), KK::DISAMBIGUATE)
    assert_equal :legacy, KK.encode(fn(:tab), KK::DISAMBIGUATE)
    assert_equal :legacy, KK.encode(fn(:backspace), KK::DISAMBIGUATE)
    assert_equal :legacy, KK.encode(fn(:enter, mods: KK::CAPS_LOCK), KK::DISAMBIGUATE)
    assert_equal "\e[13;2u", KK.encode(fn(:enter, mods: KK::SHIFT), KK::DISAMBIGUATE)
    assert_equal "\e[9;2u", KK.encode(fn(:tab, mods: KK::SHIFT), KK::DISAMBIGUATE)
    assert_equal "\e[127;5u", KK.encode(fn(:backspace, mods: KK::CTRL), KK::DISAMBIGUATE)
  end

  test "cursor and editing keys use their CSI letter and tilde forms" do
    assert_equal "\e[A", KK.encode(fn(:up), KK::DISAMBIGUATE)
    assert_equal "\e[1;2A", KK.encode(fn(:up, mods: KK::SHIFT), KK::DISAMBIGUATE)
    assert_equal "\e[H", KK.encode(fn(:home), KK::DISAMBIGUATE)
    assert_equal "\e[1;5F", KK.encode(fn(:end, mods: KK::CTRL), KK::DISAMBIGUATE)
    assert_equal "\e[3~", KK.encode(fn(:delete), KK::DISAMBIGUATE)
    assert_equal "\e[3;5~", KK.encode(fn(:delete, mods: KK::CTRL), KK::DISAMBIGUATE)
    assert_equal "\e[2~", KK.encode(fn(:insert), KK::DISAMBIGUATE)
    assert_equal "\e[5~", KK.encode(fn(:page_up), KK::DISAMBIGUATE)
    assert_equal "\e[6;3~", KK.encode(fn(:page_down, mods: KK::ALT), KK::DISAMBIGUATE)
  end

  test "lock modifiers are reported on functional keys" do
    assert_equal "\e[1;65A", KK.encode(fn(:up, mods: KK::CAPS_LOCK), KK::DISAMBIGUATE)
  end

  test "function keys follow the spec table, with F3 as 13~" do
    assert_equal "\e[P", KK.encode(fn(:f1), KK::DISAMBIGUATE)
    assert_equal "\e[1;2Q", KK.encode(fn(:f2, mods: KK::SHIFT), KK::DISAMBIGUATE)
    assert_equal "\e[13~", KK.encode(fn(:f3), KK::DISAMBIGUATE)
    assert_equal "\e[13;2~", KK.encode(fn(:f3, mods: KK::SHIFT), KK::DISAMBIGUATE)
    assert_equal "\e[S", KK.encode(fn(:f4), KK::DISAMBIGUATE)
    assert_equal "\e[15~", KK.encode(fn(:f5), KK::DISAMBIGUATE)
    assert_equal "\e[24;5~", KK.encode(fn(:f12, mods: KK::CTRL), KK::DISAMBIGUATE)
    assert_equal "\e[57376u", KK.encode(fn(:f13), KK::DISAMBIGUATE)
  end

  test "non-text keypad keys get private use codes, text keypad keys stay text" do
    assert_equal "\e[57414u", KK.encode(fn(:kp_enter), KK::DISAMBIGUATE)
    assert_equal "\e[57417;2u", KK.encode(fn(:kp_left, mods: KK::SHIFT), KK::DISAMBIGUATE)
    assert_equal :legacy, KK.encode(fn(:kp_1, text: '1'), KK::DISAMBIGUATE)
    assert_equal "\e[57400;5u", KK.encode(fn(:kp_1, text: '1', mods: KK::CTRL), KK::DISAMBIGUATE)
  end

  test "modifier keys and releases are not reported without the matching flags" do
    assert_nil KK.encode(fn(:left_shift, mods: KK::SHIFT), KK::DISAMBIGUATE)
    assert_nil KK.encode(fn(:up, event: :release), KK::DISAMBIGUATE)
    assert_nil KK.encode(key(97, mods: KK::CTRL, event: :release), KK::DISAMBIGUATE)
  end

  test "repeats look like presses without the event flag" do
    assert_equal "\e[97;5u", KK.encode(key(97, mods: KK::CTRL, event: :repeat), KK::DISAMBIGUATE)
  end

  # --- report event types ---

  test "event types add a sub-parameter to the modifiers" do
    flags = KK::DISAMBIGUATE | KK::REPORT_EVENTS
    assert_equal "\e[97;5:2u", KK.encode(key(97, mods: KK::CTRL, event: :repeat), flags)
    assert_equal "\e[97;5:3u", KK.encode(key(97, mods: KK::CTRL, event: :release), flags)
    assert_equal "\e[1;1:3A", KK.encode(fn(:up, event: :release), flags)
    assert_equal "\e[3;1:2~", KK.encode(fn(:delete, event: :repeat), flags)
    assert_equal "\e[27;1:3u", KK.encode(fn(:escape, event: :release), flags)
  end

  test "text keys and enter, tab, backspace get no releases without report all" do
    flags = KK::DISAMBIGUATE | KK::REPORT_EVENTS
    assert_nil KK.encode(key(97, event: :release), flags)
    assert_nil KK.encode(fn(:enter, event: :release), flags)
    assert_equal "\e[13;1:3u", KK.encode(fn(:enter, event: :release), flags | KK::REPORT_ALL)
    assert_equal "\e[97;1:3u", KK.encode(key(97, event: :release), flags | KK::REPORT_ALL)
  end

  # --- alternate keys ---

  test "alternate keys add the shifted key only while shift is held" do
    flags = KK::DISAMBIGUATE | KK::REPORT_ALTERNATES
    assert_equal "\e[97:65;6u", KK.encode(key(97, mods: KK::CTRL | KK::SHIFT, shifted: 65), flags)
    assert_equal "\e[97;5u", KK.encode(key(97, mods: KK::CTRL, shifted: 65), flags)
  end

  test "alternate keys add the base layout key behind an empty shifted field" do
    flags = KK::DISAMBIGUATE | KK::REPORT_ALTERNATES
    assert_equal "\e[246::112;5u", KK.encode(key(246, mods: KK::CTRL, shifted: 214, base: 112), flags)
    assert_equal "\e[246:214:112;6u", KK.encode(key(246, mods: KK::CTRL | KK::SHIFT, shifted: 214, base: 112), flags)
    assert_equal "\e[97;5u", KK.encode(key(97, mods: KK::CTRL, base: 97), flags)
  end

  test "alternate keys are left out without the flag" do
    assert_equal "\e[97;6u", KK.encode(key(97, mods: KK::CTRL | KK::SHIFT, shifted: 65, base: 97), KK::DISAMBIGUATE)
  end

  # --- report all keys ---

  test "report all encodes text keys, enter and the keypad too" do
    assert_equal "\e[97u", KK.encode(key(97), KK::REPORT_ALL)
    assert_equal "\e[97;2u", KK.encode(key(97, text: 'A', mods: KK::SHIFT), KK::REPORT_ALL)
    assert_equal "\e[32u", KK.encode(key(32), KK::REPORT_ALL)
    assert_equal "\e[13u", KK.encode(fn(:enter), KK::REPORT_ALL)
    assert_equal "\e[9;2u", KK.encode(fn(:tab, mods: KK::SHIFT), KK::REPORT_ALL)
    assert_equal "\e[127u", KK.encode(fn(:backspace), KK::REPORT_ALL)
    assert_equal "\e[57400u", KK.encode(fn(:kp_1, text: '1'), KK::REPORT_ALL)
    assert_equal "\e[A", KK.encode(fn(:up), KK::REPORT_ALL)
  end

  test "report all reports lock modifiers and modifier keys" do
    assert_equal "\e[97;65u", KK.encode(key(97, text: 'A', mods: KK::CAPS_LOCK), KK::REPORT_ALL)
    assert_equal "\e[57441;2u", KK.encode(fn(:left_shift, mods: KK::SHIFT), KK::REPORT_ALL)
    assert_equal "\e[57442;5u", KK.encode(fn(:left_control, mods: KK::CTRL), KK::REPORT_ALL)
    assert_equal "\e[57358;65u", KK.encode(fn(:caps_lock, mods: KK::CAPS_LOCK), KK::REPORT_ALL)
    assert_nil KK.encode(fn(:left_shift, mods: 0, event: :release), KK::REPORT_ALL)
    assert_equal "\e[57441;1:3u", KK.encode(fn(:left_shift, mods: 0, event: :release), KK::REPORT_ALL | KK::REPORT_EVENTS)
  end

  test "report all sends text with no known key as key 0 only with the text flag" do
    assert_equal :legacy, KK.encode(key(nil, text: 'é'), KK::REPORT_ALL)
    assert_equal "\e[0;;233u", KK.encode(key(nil, text: 'é'), KK::REPORT_ALL | KK::REPORT_TEXT)
    assert_equal :legacy, KK.encode(key(nil, text: 'é'), 0)
  end

  test "a dead key press with no text and no modifiers stays with the input method" do
    assert_equal :legacy, KK.encode(key(101, text: ''), KK::DISAMBIGUATE)
    assert_equal "\e[101u", KK.encode(key(101, text: ''), KK::REPORT_ALL)
  end

  # --- report associated text ---

  test "associated text follows the modifiers field" do
    flags = KK::REPORT_ALL | KK::REPORT_TEXT
    assert_equal "\e[97;;97u", KK.encode(key(97), flags)
    assert_equal "\e[97;2;65u", KK.encode(key(97, text: 'A', mods: KK::SHIFT), flags)
    assert_equal "\e[101;;101:769u", KK.encode(key(101, text: "é"), flags)
    assert_equal "\e[57400;;49u", KK.encode(fn(:kp_1, text: '1'), flags)
  end

  test "associated text never carries control codes" do
    flags = KK::REPORT_ALL | KK::REPORT_TEXT
    assert_equal "\e[97;5u", KK.encode(key(97, text: "\x01", mods: KK::CTRL), flags)
    assert_equal "\e[13u", KK.encode(fn(:enter, text: "\r"), flags)
  end

  test "associated text is undefined without report all and ignored" do
    assert_equal :legacy, KK.encode(key(97), KK::REPORT_TEXT)
    assert_equal "\e[97;5u", KK.encode(key(97, text: "\x01", mods: KK::CTRL), KK::DISAMBIGUATE | KK::REPORT_TEXT)
  end

  test "everything on at once" do
    flags = 31
    assert_equal "\e[97:65;2;65u", KK.encode(key(97, text: 'A', mods: KK::SHIFT, shifted: 65), flags)
    assert_equal "\e[97;1:3u", KK.encode(key(97, event: :release), flags)
    assert_equal "\e[1;2:2A", KK.encode(fn(:up, mods: KK::SHIFT, event: :repeat), flags)
  end

  # --- macOS key codes to the PC-101 base layout ---

  test "base layout lookup maps macOS virtual key codes to US ASCII" do
    assert_equal 'a'.ord, KK.base_layout_codepoint(0)      # kVK_ANSI_A
    assert_equal 'p'.ord, KK.base_layout_codepoint(35)     # kVK_ANSI_P
    assert_equal '1'.ord, KK.base_layout_codepoint(18)     # kVK_ANSI_1
    assert_equal ';'.ord, KK.base_layout_codepoint(41)     # kVK_ANSI_Semicolon
    assert_nil KK.base_layout_codepoint(126)               # Up arrow: not a text key
  end
end
