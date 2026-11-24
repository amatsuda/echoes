# frozen_string_literal: true

module Echoes
  # Key encoding for the kitty keyboard protocol.
  # https://sw.kovidgoyal.net/kitty/keyboard-protocol/
  #
  # The GUI turns an NSEvent into a Key and asks `encode` what to send
  # under the flags the program on the active screen has pushed:
  #
  #   String   the escape sequence to write
  #   :legacy  the protocol leaves this key alone; use the legacy bytes
  #   nil      send nothing (a release the program hasn't asked for,
  #            a bare modifier key, ...)
  #
  # Nothing in here touches AppKit, so every rule is unit-tested.
  module KittyKeyboard
    # Progressive enhancement flags.
    DISAMBIGUATE      = 0b1
    REPORT_EVENTS     = 0b10
    REPORT_ALTERNATES = 0b100
    REPORT_ALL        = 0b1000
    REPORT_TEXT       = 0b10000

    # Modifier bits (the encoded field is 1 + these).
    SHIFT     = 0b1
    ALT       = 0b10
    CTRL      = 0b100
    SUPER     = 0b1000
    HYPER     = 0b10000
    META      = 0b100000
    CAPS_LOCK = 0b1000000
    NUM_LOCK  = 0b10000000
    LOCK_MODS = CAPS_LOCK | NUM_LOCK

    EVENT_TYPES = { press: 1, repeat: 2, release: 3 }.freeze

    # codepoint:  the key's unshifted codepoint (97 for the A key),
    #             nil for pure text events such as IME output
    # functional: a name from FUNCTIONAL for keys that aren't text
    # shifted:    codepoint the key gives with Shift (65), or nil
    # base:       codepoint of the same physical key on a US layout
    # text:       the text the key produced, "" or nil for none
    # mods:       bitmask of the modifier constants above
    # event:      :press, :repeat or :release
    Key = Struct.new(:codepoint, :functional, :shifted, :base, :text, :mods, :event, keyword_init: true)

    # The spec's functional key table: name => [number, final byte].
    # A letter final means the `CSI 1 ; mods letter` form, `~` the
    # `CSI number ; mods ~` form and `u` the plain `CSI number ; mods u`.
    FUNCTIONAL = {
      escape: [27, 'u'], enter: [13, 'u'], tab: [9, 'u'], backspace: [127, 'u'],
      insert: [2, '~'], delete: [3, '~'],
      left: [1, 'D'], right: [1, 'C'], up: [1, 'A'], down: [1, 'B'],
      page_up: [5, '~'], page_down: [6, '~'], home: [1, 'H'], end: [1, 'F'],
      caps_lock: [57358, 'u'], scroll_lock: [57359, 'u'], num_lock: [57360, 'u'],
      print_screen: [57361, 'u'], pause: [57362, 'u'], menu: [57363, 'u'],
      f1: [1, 'P'], f2: [1, 'Q'], f3: [13, '~'], f4: [1, 'S'],
      f5: [15, '~'], f6: [17, '~'], f7: [18, '~'], f8: [19, '~'],
      f9: [20, '~'], f10: [21, '~'], f11: [23, '~'], f12: [24, '~'],
      **(13..35).to_h { |n| [:"f#{n}", [57376 + n - 13, 'u']] },
      **(0..9).to_h { |n| [:"kp_#{n}", [57399 + n, 'u']] },
      kp_decimal: [57409, 'u'], kp_divide: [57410, 'u'], kp_multiply: [57411, 'u'],
      kp_subtract: [57412, 'u'], kp_add: [57413, 'u'], kp_enter: [57414, 'u'],
      kp_equal: [57415, 'u'], kp_separator: [57416, 'u'],
      kp_left: [57417, 'u'], kp_right: [57418, 'u'], kp_up: [57419, 'u'], kp_down: [57420, 'u'],
      kp_page_up: [57421, 'u'], kp_page_down: [57422, 'u'], kp_home: [57423, 'u'], kp_end: [57424, 'u'],
      kp_insert: [57425, 'u'], kp_delete: [57426, 'u'], kp_begin: [1, 'E'],
      media_play: [57428, 'u'], media_pause: [57429, 'u'], media_play_pause: [57430, 'u'],
      media_reverse: [57431, 'u'], media_stop: [57432, 'u'], media_fast_forward: [57433, 'u'],
      media_rewind: [57434, 'u'], media_track_next: [57435, 'u'], media_track_previous: [57436, 'u'],
      media_record: [57437, 'u'], lower_volume: [57438, 'u'], raise_volume: [57439, 'u'], mute_volume: [57440, 'u'],
      left_shift: [57441, 'u'], left_control: [57442, 'u'], left_alt: [57443, 'u'], left_super: [57444, 'u'],
      left_hyper: [57445, 'u'], left_meta: [57446, 'u'],
      right_shift: [57447, 'u'], right_control: [57448, 'u'], right_alt: [57449, 'u'], right_super: [57450, 'u'],
      right_hyper: [57451, 'u'], right_meta: [57452, 'u'],
      iso_level3_shift: [57453, 'u'], iso_level5_shift: [57454, 'u'],
    }.freeze

    # Keys that only exist as escape codes once a program asks for all
    # keys: the legacy encoding has no bytes for them.
    MODIFIER_KEYS = %i[
      caps_lock scroll_lock num_lock
      left_shift left_control left_alt left_super left_hyper left_meta
      right_shift right_control right_alt right_super right_hyper right_meta
      iso_level3_shift iso_level5_shift
    ].freeze

    # Keep their legacy bytes under disambiguation unless modified.
    LEGACY_C0_KEYS = %i[enter tab backspace].freeze

    def self.encode(key, flags)
      return :legacy if flags == 0 && key.event != :release
      return nil if flags == 0

      report_all = flags & REPORT_ALL != 0
      mods = key.mods.to_i
      text_key = text_key?(key)

      unless report_all
        return nil if MODIFIER_KEYS.include?(key.functional)
        # Releases exist only for keys that are encoded as escape
        # codes; text keys (and Enter/Tab/Backspace) have none.
        if key.event == :release
          return nil if text_key || LEGACY_C0_KEYS.include?(key.functional) || flags & REPORT_EVENTS == 0
        end
        if LEGACY_C0_KEYS.include?(key.functional)
          return :legacy if mods & ~LOCK_MODS == 0
        elsif text_key || (key.functional.nil? && key.codepoint)
          # Only ctrl, alt and super make a text key ambiguous.
          return :legacy if mods & (CTRL | ALT | SUPER) == 0
        end
        # Lock modifiers are not reported for text producing keys.
        mods &= ~LOCK_MODS if text_key || key.functional.nil?
      end

      return nil if key.event == :release && flags & REPORT_EVENTS == 0

      number, final, text = encoding_parts(key, flags)
      return :legacy if number.nil?

      mods_field = modifiers_field(mods, key.event, flags)
      params = []
      case final
      when 'u'
        params << number
        params << mods_field if mods_field || text
        params << text if text
      when '~'
        params << number
        params << mods_field if mods_field
      else
        params << "1;#{mods_field}" if mods_field
      end
      "\e[#{params.join(';')}#{final}"
    end

    # Does this key stand for text, as far as the legacy decision goes?
    def self.text_key?(key)
      text = key.text
      !text.nil? && !text.empty? && !control_text?(text)
    end

    def self.control_text?(text)
      text.each_codepoint.any? { |cp| cp < 0x20 || (0x7F..0x9F).cover?(cp) }
    end

    # [number-with-alternates, final, text-field-or-nil]; number is nil
    # for a text event with no key when the text can't be embedded.
    def self.encoding_parts(key, flags)
      text = nil
      # Text is produced by the press (or repeat); a release has none.
      if flags & REPORT_ALL != 0 && flags & REPORT_TEXT != 0 && key.event != :release && text_key?(key)
        text = key.text.each_codepoint.map(&:to_s).join(':')
      end

      if key.functional
        number, final = FUNCTIONAL.fetch(key.functional)
        return [number.to_s, final, final == 'u' ? text : nil]
      end

      if key.codepoint.nil? || key.codepoint == 0
        # Text with no key behind it (an input method, a dead-key
        # sequence): only representable when the text itself rides along.
        return [nil, 'u', nil] unless text
        return ['0', 'u', text]
      end

      number = key.codepoint.to_s
      if flags & REPORT_ALTERNATES != 0
        shifted = key.shifted if key.mods.to_i & SHIFT != 0 && key.shifted && key.shifted != key.codepoint
        base = key.base if key.base && key.base != key.codepoint
        if shifted || base
          number = "#{number}:#{shifted}"
          number = "#{number}:#{base}" if base
        end
      end
      [number, 'u', text]
    end

    # "mods" or "mods:event", nil when both are at their defaults.
    def self.modifiers_field(mods, event, flags)
      event_type = flags & REPORT_EVENTS != 0 ? EVENT_TYPES.fetch(event, 1) : 1
      return nil if mods == 0 && event_type == 1

      field = (mods + 1).to_s
      field = "#{field}:#{event_type}" if event_type != 1
      field
    end

    # macOS virtual key codes (kVK_ANSI_*) for the keys that type text,
    # mapped to what they produce on a US layout: the spec's
    # "base layout key".
    BASE_LAYOUT = {
      0 => 'a', 1 => 's', 2 => 'd', 3 => 'f', 4 => 'h', 5 => 'g', 6 => 'z', 7 => 'x',
      8 => 'c', 9 => 'v', 11 => 'b', 12 => 'q', 13 => 'w', 14 => 'e', 15 => 'r', 16 => 'y',
      17 => 't', 18 => '1', 19 => '2', 20 => '3', 21 => '4', 22 => '6', 23 => '5', 24 => '=',
      25 => '9', 26 => '7', 27 => '-', 28 => '8', 29 => '0', 30 => ']', 31 => 'o', 32 => 'u',
      33 => '[', 34 => 'i', 35 => 'p', 37 => 'l', 38 => 'j', 39 => "'", 40 => 'k', 41 => ';',
      42 => '\\', 43 => ',', 44 => '/', 45 => 'n', 46 => 'm', 47 => '.', 49 => ' ', 50 => '`',
    }.transform_values(&:ord).freeze

    def self.base_layout_codepoint(key_code)
      BASE_LAYOUT[key_code]
    end
  end
end
