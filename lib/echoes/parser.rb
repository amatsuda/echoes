# frozen_string_literal: true

module Echoes
  class Parser
    def initialize(screen, writer: nil)
      @screen = screen
      @writer = writer
      @state = :ground
      @params = []
      @current_param = +""
      @private_flag = false
      @osc_string = +""
      @dcs_params = []
      @dcs_current_param = +""
      @dcs_data = "".b
      @utf8_buf = "".b
      @utf8_remaining = 0
    end

    def feed(data)
      data.each_byte do |byte|
        process_byte(byte)
      end
    end

    private

    def process_byte(byte)
      # UTF-8 continuation bytes
      if @utf8_remaining > 0
        @utf8_buf << byte.chr(Encoding::BINARY)
        @utf8_remaining -= 1
        if @utf8_remaining == 0
          char = @utf8_buf.force_encoding('UTF-8')
          @screen.put_char(char) if char.valid_encoding?
          @utf8_buf = "".b
        end
        return
      end

      case @state
      when :ground
        ground(byte)
      when :escape
        escape(byte)
      when :escape_intermediate
        escape_intermediate(byte)
      when :csi_entry
        csi_entry(byte)
      when :csi_param
        csi_param(byte)
      when :osc_string
        osc_string(byte)
      when :dcs_entry
        dcs_entry(byte)
      when :dcs_param
        dcs_param(byte)
      when :dcs_passthrough
        dcs_passthrough(byte)
      end
    end

    def ground(byte)
      case byte
      when 0x1B # ESC
        @state = :escape
      when 0x0D # CR
        @screen.carriage_return
      when 0x0A, 0x0B, 0x0C # LF, VT, FF
        @screen.line_feed
      when 0x08 # BS
        @screen.backspace
      when 0x09 # HT
        @screen.tab
      when 0x07 # BEL
        # ignore
      when 0x00..0x1F
        # ignore other C0 controls
      when 0x20..0x7E # printable ASCII
        @screen.put_char(byte.chr)
      when 0xC0..0xDF # UTF-8 2-byte
        @utf8_buf = byte.chr(Encoding::BINARY)
        @utf8_remaining = 1
      when 0xE0..0xEF # UTF-8 3-byte
        @utf8_buf = byte.chr(Encoding::BINARY)
        @utf8_remaining = 2
      when 0xF0..0xF7 # UTF-8 4-byte
        @utf8_buf = byte.chr(Encoding::BINARY)
        @utf8_remaining = 3
      end
    end

    def escape(byte)
      case byte
      when 0x5B # [
        @state = :csi_entry
        @params = []
        @current_param = +""
        @private_flag = false
      when 0x50 # P (DCS)
        @state = :dcs_entry
        @dcs_params = []
        @dcs_current_param = +""
        @dcs_data = "".b
      when 0x5D # ]
        @state = :osc_string
        @osc_string = "".b
      when 0x37 # 7
        @screen.save_cursor
        @state = :ground
      when 0x38 # 8
        @screen.restore_cursor
        @state = :ground
      when 0x63 # c
        @screen.reset
        @state = :ground
      when 0x44 # D
        @screen.line_feed
        @state = :ground
      when 0x4D # M
        @screen.reverse_index
        @state = :ground
      when 0x20..0x2F # intermediate bytes
        @state = :escape_intermediate
      else
        @state = :ground
      end
    end

    def escape_intermediate(byte)
      case byte
      when 0x20..0x2F
        # accumulate intermediates, ignore
      when 0x30..0x7E
        # final byte, ignore the whole sequence (charset designations, etc.)
        @state = :ground
      else
        @state = :ground
      end
    end

    def csi_entry(byte)
      case byte
      when 0x3F # ?
        @private_flag = true
        @state = :csi_param
      when 0x30..0x39 # 0-9
        @current_param << byte.chr
        @state = :csi_param
      when 0x3B # ;
        @params << @current_param
        @current_param = +""
        @state = :csi_param
      when 0x40..0x7E # final byte
        dispatch_csi(byte.chr)
        @state = :ground
      else
        @state = :csi_param
      end
    end

    def csi_param(byte)
      case byte
      when 0x30..0x39 # 0-9
        @current_param << byte.chr
      when 0x3B # ;
        @params << @current_param
        @current_param = +""
      when 0x40..0x7E # final byte
        dispatch_csi(byte.chr)
        @state = :ground
      when 0x1B # ESC interrupts
        @state = :escape
      end
    end

    def osc_string(byte)
      case byte
      when 0x07 # BEL terminates OSC
        dispatch_osc
        @state = :ground
      when 0x1B # ESC (potential ST = ESC \)
        dispatch_osc
        @state = :ground
      else
        @osc_string << byte
      end
    end

    def dcs_entry(byte)
      case byte
      when 0x30..0x39
        @dcs_current_param << byte.chr
        @state = :dcs_param
      when 0x3B
        @dcs_params << @dcs_current_param
        @dcs_current_param = +""
        @state = :dcs_param
      when 0x71 # 'q' => sixel
        @dcs_params << @dcs_current_param unless @dcs_current_param.empty?
        @state = :dcs_passthrough
      when 0x40..0x7E
        @state = :ground
      when 0x1B
        @state = :escape
      end
    end

    def dcs_param(byte)
      case byte
      when 0x30..0x39
        @dcs_current_param << byte.chr
      when 0x3B
        @dcs_params << @dcs_current_param
        @dcs_current_param = +""
      when 0x71 # 'q'
        @dcs_params << @dcs_current_param unless @dcs_current_param.empty?
        @state = :dcs_passthrough
      when 0x40..0x7E
        @state = :ground
      when 0x1B
        @state = :escape
      end
    end

    def dcs_passthrough(byte)
      if byte == 0x1B
        dispatch_dcs
        @state = :escape
      else
        @dcs_data << byte
      end
    end

    def dispatch_dcs
      params = @dcs_params.map { |s| s.empty? ? 0 : s.to_i }
      @screen.put_sixel(@dcs_data, params)
    end

    def dispatch_osc
      code, rest = @osc_string.split(';'.b, 2)
      return unless rest

      code.force_encoding('UTF-8')
      rest.force_encoding('UTF-8')

      case code
      when '0', '2'
        @screen.title = rest
        return
      when '66'
        # fall through to multicell handling below
      else
        return
      end
      meta_str, text = rest.split(';', 2)
      return unless text

      text.force_encoding('UTF-8')
      params = {scale: 1, width: 0, frac_n: 0, frac_d: 0, valign: 0, halign: 0}
      meta_str.split(':').each do |pair|
        k, v = pair.split('=', 2)
        next unless v
        val = v.to_i
        case k
        when 's' then params[:scale] = val.clamp(1, 7)
        when 'w' then params[:width] = val.clamp(0, 7)
        when 'n' then params[:frac_n] = val.clamp(0, 15)
        when 'd' then params[:frac_d] = val.clamp(0, 15)
        when 'v' then params[:valign] = val.clamp(0, 2)
        when 'h' then params[:halign] = val.clamp(0, 2)
        end
      end

      @screen.put_multicell(text, **params)
    end

    def dispatch_csi(final)
      params = collect_params

      case final
      when 'A' then @screen.move_cursor_up(params[0] || 1)
      when 'B' then @screen.move_cursor_down(params[0] || 1)
      when 'C' then @screen.move_cursor_forward(params[0] || 1)
      when 'D' then @screen.move_cursor_backward(params[0] || 1)
      when 'H', 'f' then @screen.move_cursor((params[0] || 1) - 1, (params[1] || 1) - 1)
      when 'G', '`' then @screen.move_cursor(@screen.cursor.row, (params[0] || 1) - 1)
      when 'd' then @screen.move_cursor((params[0] || 1) - 1, @screen.cursor.col)
      when 'J' then @screen.erase_in_display(params[0] || 0)
      when 'K' then @screen.erase_in_line(params[0] || 0)
      when 'L' then @screen.insert_lines(params[0] || 1)
      when 'M' then @screen.delete_lines(params[0] || 1)
      when 'P' then @screen.delete_chars(params[0] || 1)
      when '@' then @screen.insert_chars(params[0] || 1)
      when 'X' then @screen.erase_chars(params[0] || 1)
      when 'S' then @screen.scroll_up(params[0] || 1)
      when 'T' then @screen.scroll_down(params[0] || 1)
      when 'm' then @screen.set_graphics(params)
      when 'r' then @screen.set_scroll_region((params[0] || 1) - 1, (params[1] || @screen.rows) - 1)
      when 's' then @screen.save_cursor
      when 'u' then @screen.restore_cursor
      when 'c' then dispatch_da(params)
      when 'n' then dispatch_dsr(params)
      when 'h' then dispatch_mode_set(params)
      when 'l' then dispatch_mode_reset(params)
      end
    end

    def dispatch_mode_set(params)
      return unless @private_flag

      params.each do |p|
        case p
        when 1 then @screen.application_cursor_keys = true
        when 6 then @screen.origin_mode = true
        when 7 then @screen.auto_wrap = true
        when 25 then @screen.show_cursor
        when 9 then @screen.mouse_tracking = :x10
        when 1000 then @screen.mouse_tracking = :normal
        when 1002 then @screen.mouse_tracking = :button_event
        when 1003 then @screen.mouse_tracking = :any_event
        when 1006 then @screen.mouse_encoding = :sgr
        when 2004 then @screen.bracketed_paste_mode = true
        when 1049
          @screen.save_cursor
          @screen.switch_to_alt_screen
        when 47, 1047
          @screen.switch_to_alt_screen
        end
      end
    end

    def dispatch_mode_reset(params)
      return unless @private_flag

      params.each do |p|
        case p
        when 1 then @screen.application_cursor_keys = false
        when 6 then @screen.origin_mode = false
        when 7 then @screen.auto_wrap = false
        when 25 then @screen.hide_cursor
        when 9, 1000, 1002, 1003 then @screen.mouse_tracking = :off
        when 1006 then @screen.mouse_encoding = :default
        when 2004 then @screen.bracketed_paste_mode = false
        when 1049
          @screen.switch_to_main_screen
          @screen.restore_cursor
        when 47, 1047
          @screen.switch_to_main_screen
        end
      end
    end

    def dispatch_da(params)
      return unless @writer
      return unless params[0].nil? || params[0] == 0

      # VT220 with ANSI color support
      @writer.call("\e[?62;22c")
    end

    def dispatch_dsr(params)
      return unless @writer

      case params[0]
      when 5
        @writer.call("\e[0n")
      when 6
        row = @screen.cursor.row + 1
        col = @screen.cursor.col + 1
        @writer.call("\e[#{row};#{col}R")
      end
    end

    def collect_params
      raw = @params + [@current_param]
      raw.map { |s| s.empty? ? nil : s.to_i }
    end
  end
end
