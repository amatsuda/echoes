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
      @csi_prefix = nil  # tracks <, =, > prefix bytes in CSI
      @csi_intermediate = nil
      @osc_string = +""
      @esc_intermediate = nil
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
      when 0x0E # SO (shift out -> G1)
        @screen.active_charset = 1
      when 0x0F # SI (shift in -> G0)
        @screen.active_charset = 0
      when 0x07 # BEL
        @screen.bell = true
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
        @csi_prefix = nil
        @csi_intermediate = nil
      when 0x50 # P (DCS)
        @state = :dcs_entry
        @dcs_params = []
        @dcs_current_param = +""
        @dcs_data = "".b
        @dcs_intermediate = nil
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
      when 0x45 # E (NEL - Next Line)
        @screen.carriage_return
        @screen.line_feed
        @state = :ground
      when 0x48 # H (HTS - Horizontal Tab Set)
        @screen.set_tab_stop
        @state = :ground
      when 0x4D # M
        @screen.reverse_index
        @state = :ground
      when 0x3D # = (application keypad mode)
        @screen.application_keypad = true
        @state = :ground
      when 0x3E # > (normal keypad mode)
        @screen.application_keypad = false
        @state = :ground
      when 0x20..0x2F # intermediate bytes
        @esc_intermediate = byte
        @state = :escape_intermediate
      else
        @state = :ground
      end
    end

    def escape_intermediate(byte)
      case byte
      when 0x20..0x2F
        @esc_intermediate = byte
      when 0x30..0x7E
        dispatch_escape_intermediate(byte)
        @state = :ground
      else
        @state = :ground
      end
    end

    def dispatch_escape_intermediate(final)
      case @esc_intermediate
      when 0x23 # #
        @screen.decaln if final == 0x38  # ESC # 8
      when 0x28 # ( => G0
        charset = final == 0x30 ? :dec_special : :ascii
        @screen.designate_charset(0, charset)
      when 0x29 # ) => G1
        charset = final == 0x30 ? :dec_special : :ascii
        @screen.designate_charset(1, charset)
      end
    end

    def csi_entry(byte)
      case byte
      when 0x3F # ?
        @private_flag = true
        @state = :csi_param
      when 0x3C..0x3E # <, =, > (private parameter prefixes)
        @csi_prefix = byte
        @state = :csi_param
      when 0x30..0x39 # 0-9
        @current_param << byte.chr
        @state = :csi_param
      when 0x3A # : (sub-parameter separator)
        @current_param << ':'
        @state = :csi_param
      when 0x3B # ;
        @params << @current_param
        @current_param = +""
        @state = :csi_param
      when 0x20..0x2F # intermediate bytes
        @csi_intermediate = byte.chr
        @state = :csi_param
      when 0x40..0x7E # final byte
        dispatch_csi(byte.chr)
        @state = :ground
      when 0x18, 0x1A # CAN, SUB — abort sequence
        @state = :ground
      else
        @state = :csi_param
      end
    end

    def csi_param(byte)
      case byte
      when 0x30..0x39 # 0-9
        @current_param << byte.chr
      when 0x3A # : (sub-parameter separator)
        @current_param << ':'
      when 0x3B # ;
        @params << @current_param
        @current_param = +""
      when 0x20..0x2F # intermediate bytes
        @csi_intermediate = byte.chr
      when 0x40..0x7E # final byte
        dispatch_csi(byte.chr)
        @state = :ground
      when 0x1B # ESC interrupts
        @state = :escape
      when 0x18, 0x1A # CAN, SUB — abort sequence
        @state = :ground
      when 0x0D # CR
        @screen.carriage_return
      when 0x0A, 0x0B, 0x0C # LF, VT, FF
        @screen.line_feed
      when 0x08 # BS
        @screen.backspace
      when 0x09 # HT
        @screen.tab
      when 0x07 # BEL
        @screen.bell = true
      end
    end

    def osc_string(byte)
      case byte
      when 0x07 # BEL terminates OSC
        dispatch_osc
        @state = :ground
      when 0x1B # ESC — dispatch OSC, enter escape state for ST (\)
        dispatch_osc
        @state = :escape
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
      when 0x20..0x2F # intermediate bytes (+, etc.)
        @dcs_intermediate = byte
        @state = :dcs_param
      when 0x40..0x7E # final byte
        @dcs_params << @dcs_current_param unless @dcs_current_param.empty?
        if byte == 0x71 # 'q'
          @state = :dcs_passthrough
        else
          @state = :ground
        end
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
      when 0x20..0x2F # intermediate bytes
        @dcs_intermediate = byte
      when 0x40..0x7E # final byte
        @dcs_params << @dcs_current_param unless @dcs_current_param.empty?
        if byte == 0x71 # 'q'
          @state = :dcs_passthrough
        else
          @state = :ground
        end
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
      if @dcs_intermediate == 0x2B # '+' => XTGETTCAP
        dispatch_xtgettcap(@dcs_data)
      else
        params = @dcs_params.map { |s| s.empty? ? 0 : s.to_i }
        @screen.put_sixel(@dcs_data, params)
      end
    end

    TCAP_RESPONSES = {
      'TN' => 'xterm-256color',    # terminal name
      'Co' => '256',                # max colors
      'RGB' => '1',                 # direct color support
      'Su' => '1',                  # styled underlines
      'Ms' => '\033]52;%p1%s;%p2%s\033\\\\',  # clipboard (OSC 52)
    }.freeze

    def dispatch_xtgettcap(data)
      return unless @writer

      # Data contains hex-encoded capability names separated by ';'
      names = data.force_encoding('ASCII').split(';')
      names.each do |hex_name|
        name = [hex_name].pack('H*') rescue next
        value = TCAP_RESPONSES[name]
        if value
          hex_value = value.unpack1('H*')
          hex_key = name.unpack1('H*')
          @writer.call("\eP1+r#{hex_key}=#{hex_value}\e\\")
        else
          hex_key = name.unpack1('H*')
          @writer.call("\eP0+r#{hex_key}\e\\")
        end
      end
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
      when '8'
        _params, uri = rest.split(';', 2)
        @screen.set_hyperlink(uri && !uri.empty? ? uri : nil)
        return
      when '7'
        @screen.current_directory = rest
        return
      when '4'
        dispatch_osc4(rest)
        return
      when '10'
        dispatch_osc_default_color(:fg, 10, rest)
        return
      when '11'
        dispatch_osc_default_color(:bg, 11, rest)
        return
      when '12'
        dispatch_osc_default_color(:cursor, 12, rest)
        return
      when '52'
        dispatch_osc52(rest)
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

    def dispatch_osc_default_color(key, osc_code, spec)
      if spec == '?'
        if @writer && @screen.palette_handler
          rgb = @screen.palette_handler.call(:get, key)
          if rgb
            r, g, b = rgb
            @writer.call("\e]#{osc_code};rgb:#{format('%04x', r)}/#{format('%04x', g)}/#{format('%04x', b)}\e\\")
          end
        end
      elsif spec =~ /\Argb:([0-9a-fA-F]+)\/([0-9a-fA-F]+)\/([0-9a-fA-F]+)\z/
        r = scale_color_component($1)
        g = scale_color_component($2)
        b = scale_color_component($3)
        @screen.palette_handler&.call(:set, key, [r, g, b])
      end
    end

    def dispatch_osc4(rest)
      # OSC 4 can contain multiple index;spec pairs
      parts = rest.split(';')
      parts.each_slice(2) do |index_str, spec|
        break unless spec
        idx = index_str.to_i
        next if idx < 0 || idx > 255

        if spec == '?'
          # Query: respond with current color
          if @writer && @screen.palette_handler
            rgb = @screen.palette_handler.call(:get, idx)
            if rgb
              r, g, b = rgb
              @writer.call("\e]4;#{idx};rgb:#{format('%04x', r)}/#{format('%04x', g)}/#{format('%04x', b)}\e\\")
            end
          end
        else
          # Set: parse color spec (rgb:RR/GG/BB or rgb:RRRR/GGGG/BBBB)
          if spec =~ /\Argb:([0-9a-fA-F]+)\/([0-9a-fA-F]+)\/([0-9a-fA-F]+)\z/
            r_s, g_s, b_s = $1, $2, $3
            r = scale_color_component(r_s)
            g = scale_color_component(g_s)
            b = scale_color_component(b_s)
            @screen.palette_handler&.call(:set, idx, [r, g, b])
          end
        end
      end
    end

    def scale_color_component(hex)
      val = hex.to_i(16)
      case hex.length
      when 1 then val * 0x1111
      when 2 then val * 0x0101
      when 3 then val * 0x0010 + (val >> 4)
      when 4 then val
      else val
      end
    end

    def dispatch_osc52(rest)
      _selection, data = rest.split(';', 2)
      return unless data

      if data == '?'
        # Query clipboard — respond with current clipboard content
        if @writer && @screen.respond_to?(:clipboard_content)
          content = @screen.clipboard_content
          if content
            encoded = [content].pack('m0')
            @writer.call("\e]52;c;#{encoded}\e\\")
          end
        end
      else
        # Set clipboard
        decoded = data.unpack1('m')
        decoded.force_encoding('UTF-8')
        @screen.set_clipboard(decoded) if @screen.respond_to?(:set_clipboard)
      end
    end

    def dispatch_csi(final)
      if @csi_prefix
        if @csi_prefix == 0x3E && final == 'c'
          dispatch_da2(collect_params)
        end
        return
      end

      params = collect_params

      case final
      when 'A' then @screen.move_cursor_up(params[0] || 1)
      when 'B' then @screen.move_cursor_down(params[0] || 1)
      when 'C' then @screen.move_cursor_forward(params[0] || 1)
      when 'D' then @screen.move_cursor_backward(params[0] || 1)
      when 'E' then @screen.move_cursor_next_line(params[0] || 1)
      when 'F' then @screen.move_cursor_prev_line(params[0] || 1)
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
      when 'Z' then @screen.backward_tab(params[0] || 1)
      when 'b' then @screen.repeat_char(params[0] || 1)
      when 'S' then @screen.scroll_up(params[0] || 1)
      when 'T' then @screen.scroll_down(params[0] || 1)
      when 'm' then @screen.set_graphics(collect_sgr_params)
      when 'r' then @screen.set_scroll_region((params[0] || 1) - 1, (params[1] || @screen.rows) - 1)
      when 's' then @screen.save_cursor
      when 'u' then @screen.restore_cursor
      when 'g' then @screen.clear_tab_stop(params[0] || 0)
      when 'c' then dispatch_da(params)
      when 'n' then dispatch_dsr(params)
      when 'p' then @screen.soft_reset if @csi_intermediate == '!'
      when 'q' then @screen.cursor_style = (params[0] || 0) if @csi_intermediate == ' '
      when 't' then dispatch_window_ops(params)
      when 'h' then dispatch_mode_set(params)
      when 'l' then dispatch_mode_reset(params)
      end
    end

    def dispatch_mode_set(params)
      unless @private_flag
        params.each do |p|
          case p
          when 4 then @screen.insert_mode = true
          end
        end
        return
      end

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
        when 1004 then @screen.focus_reporting = true
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
      unless @private_flag
        params.each do |p|
          case p
          when 4 then @screen.insert_mode = false
          end
        end
        return
      end

      params.each do |p|
        case p
        when 1 then @screen.application_cursor_keys = false
        when 6 then @screen.origin_mode = false
        when 7 then @screen.auto_wrap = false
        when 25 then @screen.hide_cursor
        when 9, 1000, 1002, 1003 then @screen.mouse_tracking = :off
        when 1006 then @screen.mouse_encoding = :default
        when 1004 then @screen.focus_reporting = false
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

    def dispatch_da2(params)
      return unless @writer
      return unless params[0].nil? || params[0] == 0

      # Report as VT220 (type 1), version 0.1.0 → 100, ROM cartridge 0
      @writer.call("\e[>1;100;0c")
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

    def dispatch_window_ops(params)
      case params[0]
      when 14
        # Report window size in pixels
        if @writer
          px_height = (@screen.rows * @screen.cell_pixel_height).to_i
          px_width = (@screen.cols * @screen.cell_pixel_width).to_i
          @writer.call("\e[4;#{px_height};#{px_width}t")
        end
      when 18
        # Report text area size in characters
        @writer&.call("\e[8;#{@screen.rows};#{@screen.cols}t")
      when 22
        # Push title
        @screen.push_title if params[1] == 0 || params[1] == 2 || params[1].nil?
      when 23
        # Pop title
        @screen.pop_title if params[1] == 0 || params[1] == 2 || params[1].nil?
      end
    end

    def collect_params
      raw = @params + [@current_param]
      raw.map { |s| s.empty? ? nil : s.to_i }
    end

    # For SGR (m), return params that may contain colon sub-parameters.
    # Each element is either an Integer or an Array of (Integer|nil) for sub-params.
    def collect_sgr_params
      raw = @params + [@current_param]
      raw.map do |s|
        if s.include?(':')
          s.split(':').map { |p| p.empty? ? nil : p.to_i }
        else
          s.empty? ? nil : s.to_i
        end
      end
    end
  end
end
