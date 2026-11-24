# frozen_string_literal: true

module Echoes
  # xterm's modifyOtherKeys: the older way for a program to tell
  # Ctrl+Shift+A from Ctrl+A or Shift+Enter from Enter, used by Vim,
  # Emacs and others that predate the kitty protocol.
  #
  # A program sets the level with CSI > 4 ; level m. At level 1 only
  # the combinations the legacy bytes cannot express are encoded; at
  # level 2 every Ctrl/Alt/Super combination is, plus Shift on the
  # keys that have no shifted text. The encoding is xterm's default
  # form, CSI 27 ; modifiers ; code ~, with the code being the key as
  # Shift leaves it (Ctrl+Shift+A is 65).
  #
  # Takes the same Key the kitty encoder does and answers a String or
  # :legacy. Kitty flags, when pushed, take precedence; the GUI never
  # asks this module while they are set.
  module ModifyOtherKeys
    KK = KittyKeyboard

    MODIFIER_MASK = KK::SHIFT | KK::ALT | KK::CTRL | KK::SUPER

    # Functional keys whose code is a C0 byte: the only ones xterm
    # covers here. Cursor, function and keypad keys have their own
    # modifier scheme (CSI 1 ; mods A) and are left alone.
    C0_KEYS = { enter: 13, tab: 9, backspace: 127, escape: 27 }.freeze

    # Text keys Ctrl already maps to a C0 byte in legacy mode, next to
    # the letters: Ctrl+[ is ESC, Ctrl+2 is NUL and so on (the same
    # set as GUI::CONTROL_KEY_BYTES, spelled out so this file does not
    # depend on AppKit being loaded).
    CTRL_C0_CODEPOINTS = %w[2 @ 3 [ 4 \\ 5 ] 6 ^ 7 _ - / 8 ?].map(&:ord).push(32).freeze

    def self.encode(key, level)
      return :legacy if level.to_i <= 0 || key.event == :release

      mods = key.mods.to_i & MODIFIER_MASK
      return :legacy if mods == 0

      code = code_for(key, mods)
      return :legacy unless code

      if level.to_i == 1
        return :legacy if legacy_expresses?(key, mods)
      elsif mods == KK::SHIFT && key.functional.nil? && key.codepoint != 32
        # Shift alone on a text key is just the shifted text (Space
        # being the one text key with no shifted text).
        return :legacy
      end

      "\e[27;#{mods + 1};#{code}~"
    end

    def self.code_for(key, mods)
      if key.functional
        C0_KEYS[key.functional]
      elsif key.codepoint && key.codepoint > 0
        mods & KK::SHIFT != 0 && key.shifted ? key.shifted : key.codepoint
      end
    end

    # Does the legacy encoding already carry this combination?
    def self.legacy_expresses?(key, mods)
      return false if mods & KK::SUPER != 0

      case key.functional
      when :tab       then mods == KK::SHIFT                       # CSI Z
      when :enter     then mods == KK::ALT                         # ESC CR
      when :escape    then mods == KK::ALT                         # ESC ESC
      when :backspace then [KK::CTRL, KK::ALT].include?(mods)      # BS, ESC DEL
      when nil
        return false if mods & KK::SHIFT != 0 && mods & KK::CTRL != 0  # Ctrl+Shift+a is ^A too
        return true if mods & KK::CTRL == 0                             # Alt alone prefixes ESC
        cp = key.codepoint
        letter = (97..122).cover?(cp) || (65..90).cover?(cp)
        letter || CTRL_C0_CODEPOINTS.include?(cp)
      else
        false
      end
    end
  end
end
