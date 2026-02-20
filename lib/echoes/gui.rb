# frozen_string_literal: true

require 'pty'

module Echoes
  class GUI
    def initialize(command: Echoes.config.shell, rows: Echoes.config.rows, cols: Echoes.config.cols, font_size: Echoes.config.font_size)
      @rows = rows
      @cols = cols
      @font_size = font_size
      @command = command
      @screen = Screen.new(rows: rows, cols: cols)
      @parser = Parser.new(@screen)
      @colors = build_color_table
      @default_fg = make_color(*Echoes.config.foreground)
      @default_bg = make_color(*Echoes.config.background)
      @scroll_offset = 0
      @scroll_accum = 0.0
    end

    def run
      spawn_pty
      setup_app
      create_window
      create_view
      setup_timer
      start_app
    end

    def spawn_pty
      @pty_read, @pty_write, @pty_pid = PTY.spawn(@command)
      @pty_read.winsize = [@rows, @cols]
    end

    def setup_app
      @app = ObjC::MSG_PTR.call(ObjC.cls('NSApplication'), ObjC.sel('sharedApplication'))
      ObjC::MSG_VOID_I.call(@app, ObjC.sel('setActivationPolicy:'), 0)
    end

    def create_window
      @font = ObjC.retain(create_nsfont(@font_size))

      update_cell_metrics

      win_width = @cell_width * @cols
      win_height = @cell_height * @rows

      win = ObjC::MSG_PTR.call(ObjC.cls('NSWindow'), ObjC.sel('alloc'))
      @window = ObjC::MSG_PTR_RECT_L_L_I.call(
        win, ObjC.sel('initWithContentRect:styleMask:backing:defer:'),
        0.0, 0.0, win_width, win_height,
        ObjC::NSWindowStyleMaskDefault,
        ObjC::NSBackingStoreBuffered,
        0
      )

      ObjC::MSG_VOID_1.call(@window, ObjC.sel('setTitle:'), ObjC.nsstring(Echoes.config.window_title))
      # Enable full screen button
      ObjC::MSG_VOID_L.call(@window, ObjC.sel('setCollectionBehavior:'), 1 << 7)  # NSWindowCollectionBehaviorFullScreenPrimary
      ObjC::MSG_VOID.call(@window, ObjC.sel('center'))
    end

    def create_view
      gui = self

      @draw_rect_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
         Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE]
      ) { |_self, _cmd, x, y, w, h| gui.draw_rect }

      @key_down_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.key_down(event) }

      @accepts_fr_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_INT,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd| 1 }

      @timer_fired_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, _timer| gui.timer_fired }

      @is_flipped_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_INT,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd| 1 }

      @scroll_wheel_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.scroll_wheel(event) }

      # Get NSView's original setFrameSize: IMP so we can call super
      nsview_cls = ObjC.cls('NSView')
      super_imp = ObjC::GetMethodImpl.call(nsview_cls, ObjC.sel('setFrameSize:'))
      @super_set_frame_size = Fiddle::Function.new(super_imp, [ObjC::P, ObjC::P, ObjC::D, ObjC::D], ObjC::V)

      @set_frame_size_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE]
      ) { |_self, _cmd, w, h|
        @super_set_frame_size.call(_self, _cmd, w, h)
        gui.handle_resize(w, h)
      }

      @view_class = ObjC.define_class('EchoesTerminalView', 'NSView', {
        'drawRect:'             => ['v@:{CGRect=dddd}', @draw_rect_closure],
        'keyDown:'              => ['v@:@', @key_down_closure],
        'acceptsFirstResponder' => ['c@:', @accepts_fr_closure],
        'timerFired:'           => ['v@:@', @timer_fired_closure],
        'isFlipped'             => ['c@:', @is_flipped_closure],
        'scrollWheel:'          => ['v@:@', @scroll_wheel_closure],
        'setFrameSize:'         => ['v@:{CGSize=dd}', @set_frame_size_closure],
      })

      win_width = @cell_width * @cols
      win_height = @cell_height * @rows

      view = ObjC::MSG_PTR.call(@view_class, ObjC.sel('alloc'))
      @view = ObjC::MSG_PTR_RECT.call(
        view, ObjC.sel('initWithFrame:'),
        0.0, 0.0, win_width, win_height
      )

      ObjC::MSG_VOID_1.call(@window, ObjC.sel('setContentView:'), @view)
      ObjC::MSG_VOID_1.call(@window, ObjC.sel('makeKeyAndOrderFront:'), @app)
      ObjC::MSG_VOID_1.call(@window, ObjC.sel('makeFirstResponder:'), @view)
      ObjC::MSG_VOID_I.call(@app, ObjC.sel('activateIgnoringOtherApps:'), 1)
    end

    def setup_timer
      @timer = ObjC::MSG_PTR_D_P_P_P_I.call(
        ObjC.cls('NSTimer'),
        ObjC.sel('scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:'),
        1.0 / 60.0,
        @view,
        ObjC.sel('timerFired:'),
        Fiddle::Pointer.new(0),
        1
      )
    end

    def start_app
      ObjC::MSG_VOID.call(@app, ObjC.sel('run'))
    end

    # --- Callbacks ---

    def draw_rect
      # Autorelease pool to prevent temporary object accumulation
      pool = ObjC::MSG_PTR.call(ObjC.cls('NSAutoreleasePool'), ObjC.sel('alloc'))
      pool = ObjC::MSG_PTR.call(pool, ObjC.sel('init'))

      # Fill entire background (use large area to cover any extra pixels beyond grid)
      ObjC::MSG_VOID.call(@default_bg, ObjC.sel('setFill'))
      ObjC::NSRectFill.call(0.0, 0.0, @cell_width * (@cols + 1), @cell_height * (@rows + 1))

      scrollback = @screen.scrollback
      visible_start = scrollback.size - @scroll_offset

      @rows.times do |r|
        src = visible_start + r
        row = if src < scrollback.size
                scrollback[src]
              else
                @screen.grid[src - scrollback.size]
              end

        y = r * @cell_height  # isFlipped makes y=0 at top

        row.each_with_index do |cell, c|
          # Skip continuation cells (second half of wide chars or multicell)
          next if cell.width == 0
          next if cell.multicell == :cont

          fg_idx = cell.fg
          bg_idx = cell.bg
          if cell.inverse
            fg_idx, bg_idx = bg_idx, fg_idx
          end

          fg_color = fg_idx ? @colors[fg_idx] : @default_fg
          bg_color = bg_idx ? @colors[bg_idx] : @default_bg

          if cell.bold && fg_idx && fg_idx < 8
            fg_color = @colors[fg_idx + 8]
          end

          if cell.multicell.is_a?(Hash)
            # Multicell anchor: render scaled text in the block area
            mc = cell.multicell
            x = c * @cell_width
            block_w = mc[:cols] * @cell_width
            block_h = mc[:rows] * @cell_height

            # Fill background
            if bg_idx
              ObjC::MSG_VOID.call(bg_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, block_w, block_h)
            end

            next if cell.char == " " && !bg_idx

            # Calculate scaled font size
            effective_scale = mc[:scale].to_f
            if mc[:frac_d] > 0 && mc[:frac_d] > mc[:frac_n]
              effective_scale *= (1.0 + mc[:frac_n].to_f / mc[:frac_d])
            end
            scaled_font = ObjC.retain(create_nsfont(@font_size * effective_scale))

            draw_attrs = {
              ObjC::NSFontAttributeName => scaled_font,
              ObjC::NSForegroundColorAttributeName => fg_color,
            }
            if cell.underline
              draw_attrs[ObjC::NSUnderlineStyleAttributeName] = ObjC.nsnumber_int(1)
            end
            ns_attrs = ObjC.nsdict(draw_attrs)
            ns_char = ObjC.nsstring(cell.char)

            # Measure text for alignment
            text_w = ObjC::MSG_RET_D_1.call(ns_char, ObjC.sel('sizeWithAttributes:'), ns_attrs)

            # Horizontal alignment
            draw_x = case mc[:halign]
                      when 1 then x + block_w - text_w  # right
                      when 2 then x + (block_w - text_w) / 2.0  # center
                      else x  # left (default)
                      end

            # Vertical alignment
            scaled_ascender = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('ascender'))
            scaled_descender = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('descender'))
            scaled_leading = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('leading'))
            text_h = scaled_ascender - scaled_descender + scaled_leading

            draw_y = case mc[:valign]
                      when 1 then y + block_h - text_h  # bottom
                      when 2 then y + (block_h - text_h) / 2.0  # center
                      else y  # top (default)
                      end

            ObjC::MSG_VOID_PT_1.call(ns_char, ObjC.sel('drawAtPoint:withAttributes:'), draw_x, draw_y, ns_attrs)
            ObjC.release(scaled_font)
          else
            # Normal cell rendering
            x = c * @cell_width
            cell_w = cell.width == 2 ? @cell_width * 2 : @cell_width

            # Fill cell background (skip if default black)
            if bg_idx
              ObjC::MSG_VOID.call(bg_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, cell_w, @cell_height)
            end

            # Draw character
            next if cell.char == " " && !bg_idx

            attrs = {
              ObjC::NSFontAttributeName => @font,
              ObjC::NSForegroundColorAttributeName => fg_color,
            }
            if cell.underline
              attrs[ObjC::NSUnderlineStyleAttributeName] = ObjC.nsnumber_int(1)
            end
            ns_attrs = ObjC.nsdict(attrs)
            ns_char = ObjC.nsstring(cell.char)
            ObjC::MSG_VOID_PT_1.call(ns_char, ObjC.sel('drawAtPoint:withAttributes:'), x, y, ns_attrs)
          end
        end
      end

      # Draw cursor (only when at live view)
      if @scroll_offset == 0 && @screen.cursor.visible
        cx = @screen.cursor.col * @cell_width
        cy = @screen.cursor.row * @cell_height
        cursor_color = make_color(*Echoes.config.cursor_color)
        ObjC::MSG_VOID.call(cursor_color, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(cx, cy, @cell_width, @cell_height)
      end

      ObjC::MSG_VOID.call(pool, ObjC.sel('drain'))
    end

    def key_down(event_ptr)
      @scroll_offset = 0
      @scroll_accum = 0.0

      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))

      # Cmd+Plus / Cmd+Minus for font size
      if (flags & ObjC::NSEventModifierFlagCommand) != 0
        chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('charactersIgnoringModifiers'))
        chars = ObjC.to_ruby_string(chars_ns)
        case chars
        when "+", "="
          update_font(@font_size + 1.0)
          return
        when "-"
          update_font(@font_size - 1.0) if @font_size > 4.0
          return
        when "0"
          update_font(Echoes.config.font_size)
          return
        end
      end

      if (flags & ObjC::NSEventModifierFlagControl) != 0
        chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('charactersIgnoringModifiers'))
        chars = ObjC.to_ruby_string(chars_ns)
        unless chars.empty?
          ctrl_char = (chars[0].ord & 0x1F).chr
          @pty_write.write(ctrl_char)
        end
      else
        chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('characters'))
        chars = ObjC.to_ruby_string(chars_ns)
        unless chars.empty?
          @pty_write.write(map_special_keys(chars))
        end
      end
    rescue Errno::EIO, IOError
      ObjC::MSG_VOID_1.call(@app, ObjC.sel('terminate:'), Fiddle::Pointer.new(0))
    end

    def timer_fired
      data = @pty_read.read_nonblock(4096)
      @parser.feed(data)
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    rescue IO::WaitReadable
      # No data, skip
    rescue EOFError, Errno::EIO
      ObjC::MSG_VOID_1.call(@app, ObjC.sel('terminate:'), Fiddle::Pointer.new(0))
    end

    def scroll_wheel(event_ptr)
      delta = ObjC::MSG_RET_D.call(event_ptr, ObjC.sel('deltaY'))
      @scroll_accum += delta

      if @scroll_accum.abs >= 1.0
        lines = @scroll_accum.to_i
        @scroll_offset += lines
        @scroll_offset = @scroll_offset.clamp(0, @screen.scrollback.size)
        @scroll_accum -= lines
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end
    end

    def handle_resize(w, h)
      new_cols = (w / @cell_width).to_i
      new_rows = (h / @cell_height).to_i
      new_cols = 1 if new_cols < 1
      new_rows = 1 if new_rows < 1

      return if new_rows == @rows && new_cols == @cols

      @rows = new_rows
      @cols = new_cols
      @screen.resize(@rows, @cols)
      @pty_read.winsize = [@rows, @cols]
    rescue Errno::EIO, IOError
      # PTY already closed
    end

    def update_font(new_size)
      @font_size = new_size
      old_font = @font
      @font = ObjC.retain(create_nsfont(@font_size))
      ObjC.release(old_font) if old_font
      update_cell_metrics

      win_width = @cell_width * @cols
      win_height = @cell_height * @rows

      # setContentSize: takes NSSize (2 doubles on arm64)
      msg_void_2d = ObjC.new_msg([ObjC::P, ObjC::P, ObjC::D, ObjC::D], ObjC::V)
      msg_void_2d.call(@window, ObjC.sel('setContentSize:'), win_width, win_height)

      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    private

    def create_nsfont(size)
      if (family = Echoes.config.font_family)
        ObjC::MSG_PTR_1D.call(
          ObjC.cls('NSFont'), ObjC.sel('fontWithName:size:'),
          ObjC.nsstring(family), size
        )
      else
        ObjC::MSG_PTR_2D.call(
          ObjC.cls('NSFont'), ObjC.sel('monospacedSystemFontOfSize:weight:'),
          size, 0.0
        )
      end
    end

    def update_cell_metrics
      if Echoes.config.font_family
        # Measure "M" with sizeWithAttributes: for proportional fonts
        attrs = ObjC.nsdict({ObjC::NSFontAttributeName => @font})
        ns_m = ObjC.nsstring("M")
        @cell_width = ObjC::MSG_RET_D_1.call(ns_m, ObjC.sel('sizeWithAttributes:'), attrs)
      else
        # maximumAdvancement is accurate for monospaced fonts
        @cell_width = ObjC::MSG_RET_D.call(@font, ObjC.sel('maximumAdvancement'))
      end
      ascender = ObjC::MSG_RET_D.call(@font, ObjC.sel('ascender'))
      descender = ObjC::MSG_RET_D.call(@font, ObjC.sel('descender'))
      leading = ObjC::MSG_RET_D.call(@font, ObjC.sel('leading'))
      @cell_height = ascender - descender + leading
    end

    def map_special_keys(chars)
      case chars
      when "\u{F700}" then "\e[A"    # Up
      when "\u{F701}" then "\e[B"    # Down
      when "\u{F702}" then "\e[D"    # Left
      when "\u{F703}" then "\e[C"    # Right
      when "\u{F728}" then "\e[3~"   # Delete
      when "\u{F729}" then "\e[H"    # Home
      when "\u{F72B}" then "\e[F"    # End
      when "\u{F72C}" then "\e[5~"   # Page Up
      when "\u{F72D}" then "\e[6~"   # Page Down
      when "\u{F704}" then "\eOP"    # F1
      when "\u{F705}" then "\eOQ"    # F2
      when "\u{F706}" then "\eOR"    # F3
      when "\u{F707}" then "\eOS"    # F4
      when "\u{F708}" then "\e[15~"  # F5
      when "\u{F709}" then "\e[17~"  # F6
      when "\u{F70A}" then "\e[18~"  # F7
      when "\u{F70B}" then "\e[19~"  # F8
      when "\u{F70C}" then "\e[20~"  # F9
      when "\u{F70D}" then "\e[21~"  # F10
      when "\u{F70E}" then "\e[23~"  # F11
      when "\u{F70F}" then "\e[24~"  # F12
      else chars
      end
    end

    def build_color_table
      ansi_rgb = [
        [0.0,  0.0,  0.0],   # 0: black
        [0.8,  0.0,  0.0],   # 1: red
        [0.0,  0.8,  0.0],   # 2: green
        [0.8,  0.8,  0.0],   # 3: yellow
        [0.0,  0.0,  0.8],   # 4: blue
        [0.8,  0.0,  0.8],   # 5: magenta
        [0.0,  0.8,  0.8],   # 6: cyan
        [0.75, 0.75, 0.75],  # 7: white
        [0.5,  0.5,  0.5],   # 8: bright black
        [1.0,  0.0,  0.0],   # 9: bright red
        [0.0,  1.0,  0.0],   # 10: bright green
        [1.0,  1.0,  0.0],   # 11: bright yellow
        [0.0,  0.0,  1.0],   # 12: bright blue
        [1.0,  0.0,  1.0],   # 13: bright magenta
        [0.0,  1.0,  1.0],   # 14: bright cyan
        [1.0,  1.0,  1.0],   # 15: bright white
      ]

      colors = {}
      ansi_rgb.each_with_index do |(r, g, b), i|
        colors[i] = make_color(r, g, b)
      end

      # 6x6x6 color cube (indices 16-231)
      216.times do |i|
        idx = 16 + i
        b_val = (i % 6) * 51
        g_val = ((i / 6) % 6) * 51
        r_val = (i / 36) * 51
        colors[idx] = make_color(r_val / 255.0, g_val / 255.0, b_val / 255.0)
      end

      # Grayscale ramp (indices 232-255)
      24.times do |i|
        idx = 232 + i
        v = (8 + 10 * i) / 255.0
        colors[idx] = make_color(v, v, v)
      end

      colors
    end

    def make_color(r, g, b, a = 1.0)
      ObjC.retain(ObjC::MSG_PTR_4D.call(
        ObjC.cls('NSColor'), ObjC.sel('colorWithRed:green:blue:alpha:'),
        r, g, b, a
      ))
    end
  end
end
