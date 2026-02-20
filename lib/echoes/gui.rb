# frozen_string_literal: true

require 'pty'

module Echoes
  class GUI
    def initialize(command: Echoes.config.shell, rows: Echoes.config.rows, cols: Echoes.config.cols, font_size: Echoes.config.font_size)
      @rows = rows
      @cols = cols
      @font_size = font_size
      @command = command
      @tabs = []
      @active_tab = 0
      @colors = build_color_table
      @default_fg = make_color(*Echoes.config.foreground)
      @default_bg = make_color(*Echoes.config.background)
      @tab_bg = make_color(0.15, 0.15, 0.15)
      @tab_active_bg = make_color(0.3, 0.3, 0.3)
      @tab_fg = make_color(0.8, 0.8, 0.8)
    end

    def run
      create_tab
      setup_app
      create_window
      create_view
      setup_timer
      start_app
    end

    def create_tab
      @tabs << Tab.new(command: @command, rows: @rows, cols: @cols)
      @active_tab = @tabs.size - 1
    end

    def close_tab(index)
      return if index < 0 || index >= @tabs.size

      @tabs[index].close
      @tabs.delete_at(index)

      if @tabs.empty?
        ObjC::MSG_VOID_1.call(@app, ObjC.sel('terminate:'), Fiddle::Pointer.new(0))
        return
      end

      @active_tab = @active_tab.clamp(0, @tabs.size - 1)
    end

    def current_tab
      @tabs[@active_tab]
    end

    def tab_bar_height
      @tabs.size > 1 ? @cell_height : 0.0
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
      ObjC::MSG_VOID_L.call(@window, ObjC.sel('setCollectionBehavior:'), 1 << 7)
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

      @mouse_down_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.mouse_down(event) }

      @perform_key_equiv_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_INT,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.perform_key_equivalent(event) }

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
        'mouseDown:'            => ['v@:@', @mouse_down_closure],
        'performKeyEquivalent:' => ['c@:@', @perform_key_equiv_closure],
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

      tab = current_tab
      tbh = tab_bar_height

      # Fill entire background
      ObjC::MSG_VOID.call(@default_bg, ObjC.sel('setFill'))
      ObjC::NSRectFill.call(0.0, 0.0, @cell_width * (@cols + 1), tbh + @cell_height * (@rows + 1))

      # Draw tab bar
      if tbh > 0
        draw_tab_bar(tbh)
      end

      # Draw terminal grid
      screen = tab.screen
      scrollback = screen.scrollback
      visible_start = scrollback.size - tab.scroll_offset

      @rows.times do |r|
        src = visible_start + r
        row = if src < scrollback.size
                scrollback[src]
              else
                screen.grid[src - scrollback.size]
              end

        y = tbh + r * @cell_height

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
            mc = cell.multicell
            x = c * @cell_width
            block_w = mc[:cols] * @cell_width
            block_h = mc[:rows] * @cell_height

            if bg_idx
              ObjC::MSG_VOID.call(bg_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, block_w, block_h)
            end

            next if cell.char == " " && !bg_idx

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

            text_w = ObjC::MSG_RET_D_1.call(ns_char, ObjC.sel('sizeWithAttributes:'), ns_attrs)

            draw_x = case mc[:halign]
                      when 1 then x + block_w - text_w
                      when 2 then x + (block_w - text_w) / 2.0
                      else x
                      end

            scaled_ascender = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('ascender'))
            scaled_descender = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('descender'))
            scaled_leading = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('leading'))
            text_h = scaled_ascender - scaled_descender + scaled_leading

            draw_y = case mc[:valign]
                      when 1 then y + block_h - text_h
                      when 2 then y + (block_h - text_h) / 2.0
                      else y
                      end

            ObjC::MSG_VOID_PT_1.call(ns_char, ObjC.sel('drawAtPoint:withAttributes:'), draw_x, draw_y, ns_attrs)
            ObjC.release(scaled_font)
          else
            x = c * @cell_width
            cell_w = cell.width == 2 ? @cell_width * 2 : @cell_width

            if bg_idx
              ObjC::MSG_VOID.call(bg_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, cell_w, @cell_height)
            end

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
      if tab.scroll_offset == 0 && screen.cursor.visible
        cx = screen.cursor.col * @cell_width
        cy = tbh + screen.cursor.row * @cell_height
        cursor_color = make_color(*Echoes.config.cursor_color)
        ObjC::MSG_VOID.call(cursor_color, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(cx, cy, @cell_width, @cell_height)
      end

      ObjC::MSG_VOID.call(pool, ObjC.sel('drain'))
    end

    def perform_key_equivalent(event_ptr)
      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))
      return 0 unless (flags & ObjC::NSEventModifierFlagCommand) != 0

      chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('charactersIgnoringModifiers'))
      chars = ObjC.to_ruby_string(chars_ns)
      key_code = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('keyCode'))

      case chars
      when "+", "="
        update_font(@font_size + 1.0)
        return 1
      when "-"
        update_font(@font_size - 1.0) if @font_size > 4.0
        return 1
      when "0"
        update_font(Echoes.config.font_size)
        return 1
      when "t"
        create_tab
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        return 1
      when "w"
        close_tab(@active_tab)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        return 1
      end

      # Cmd+Shift+[ / Cmd+Shift+] — use keyCode for keyboard layout independence
      if key_code == 33  # [ key
        @active_tab = (@active_tab - 1) % @tabs.size
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        return 1
      elsif key_code == 30  # ] key
        @active_tab = (@active_tab + 1) % @tabs.size
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        return 1
      end

      0
    end

    def key_down(event_ptr)
      tab = current_tab
      tab.scroll_offset = 0
      tab.scroll_accum = 0.0

      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))

      if (flags & ObjC::NSEventModifierFlagControl) != 0
        chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('charactersIgnoringModifiers'))
        chars = ObjC.to_ruby_string(chars_ns)
        unless chars.empty?
          ctrl_char = (chars[0].ord & 0x1F).chr
          tab.pty_write.write(ctrl_char)
        end
      else
        chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('characters'))
        chars = ObjC.to_ruby_string(chars_ns)
        unless chars.empty?
          tab.pty_write.write(map_special_keys(chars))
        end
      end
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def timer_fired
      need_redraw = false

      @tabs.each do |tab|
        begin
          data = tab.pty_read.read_nonblock(4096)
          tab.parser.feed(data)
          need_redraw = true
        rescue IO::WaitReadable
          # No data for this tab
        rescue EOFError, Errno::EIO
          # Tab's process exited — will be cleaned up
        end
      end

      # Clean up dead tabs
      dead = @tabs.reject(&:alive?)
      if dead.any?
        dead.each { |t| t.close }
        @tabs -= dead
        if @tabs.empty?
          ObjC::MSG_VOID_1.call(@app, ObjC.sel('terminate:'), Fiddle::Pointer.new(0))
          return
        end
        @active_tab = @active_tab.clamp(0, @tabs.size - 1)
        need_redraw = true
      end

      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1) if need_redraw
    end

    def scroll_wheel(event_ptr)
      tab = current_tab
      delta = ObjC::MSG_RET_D.call(event_ptr, ObjC.sel('deltaY'))
      tab.scroll_accum += delta

      if tab.scroll_accum.abs >= 1.0
        lines = tab.scroll_accum.to_i
        tab.scroll_offset += lines
        tab.scroll_offset = tab.scroll_offset.clamp(0, tab.screen.scrollback.size)
        tab.scroll_accum -= lines
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end
    end

    def mouse_down(event_ptr)
      tbh = tab_bar_height
      return if tbh == 0

      click_x, click_y_in_window = event_location(event_ptr)
      view_height = @view_height || (tbh + @rows * @cell_height)
      # Window coords are non-flipped (y=0 at bottom); our view is flipped (y=0 at top)
      click_y = view_height - click_y_in_window

      return unless click_y < tbh

      tab_w = (@cell_width * @cols) / @tabs.size
      clicked_tab = (click_x / tab_w).to_i.clamp(0, @tabs.size - 1)
      @active_tab = clicked_tab
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    def handle_resize(w, h)
      @view_height = h
      tbh = tab_bar_height
      grid_height = h - tbh

      new_cols = (w / @cell_width).to_i
      new_rows = (grid_height / @cell_height).to_i
      new_cols = 1 if new_cols < 1
      new_rows = 1 if new_rows < 1

      return if new_rows == @rows && new_cols == @cols

      @rows = new_rows
      @cols = new_cols
      @tabs.each { |tab| tab.resize(@rows, @cols) }
    end

    def update_font(new_size)
      @font_size = new_size
      old_font = @font
      @font = ObjC.retain(create_nsfont(@font_size))
      ObjC.release(old_font) if old_font
      update_cell_metrics

      win_width = @cell_width * @cols
      win_height = tab_bar_height + @cell_height * @rows

      ObjC::MSG_VOID_2D.call(@window, ObjC.sel('setContentSize:'), win_width, win_height)
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    private

    def draw_tab_bar(tbh)
      total_w = @cell_width * @cols
      tab_w = total_w / @tabs.size

      # Tab bar background
      ObjC::MSG_VOID.call(@tab_bg, ObjC.sel('setFill'))
      ObjC::NSRectFill.call(0.0, 0.0, total_w + @cell_width, tbh)

      @tabs.each_with_index do |tab, i|
        x = i * tab_w

        # Active tab highlight
        if i == @active_tab
          ObjC::MSG_VOID.call(@tab_active_bg, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(x, 0.0, tab_w, tbh)
        end

        # Tab title
        label = tab.title
        label = "#{label} " if label.length < 12
        ns_label = ObjC.nsstring(label)
        ns_attrs = ObjC.nsdict({
          ObjC::NSFontAttributeName => @font,
          ObjC::NSForegroundColorAttributeName => @tab_fg,
        })
        text_x = x + @cell_width * 0.5
        ObjC::MSG_VOID_PT_1.call(ns_label, ObjC.sel('drawAtPoint:withAttributes:'), text_x, 0.0, ns_attrs)

        # Separator line between tabs
        if i < @tabs.size - 1
          sep_color = make_color(0.4, 0.4, 0.4)
          ObjC::MSG_VOID.call(sep_color, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(x + tab_w - 0.5, 2.0, 1.0, tbh - 4.0)
        end
      end
    end

    # Extract NSPoint (x, y) from [event locationInWindow] via NSInvocation
    # to work around Fiddle only capturing d0 (not d1) on arm64
    def event_location(event_ptr)
      event_class = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('class'))
      sig = ObjC::MSG_PTR_1.call(
        event_class, ObjC.sel('instanceMethodSignatureForSelector:'),
        ObjC.sel('locationInWindow')
      )
      inv = ObjC::MSG_PTR_1.call(
        ObjC.cls('NSInvocation'), ObjC.sel('invocationWithMethodSignature:'), sig
      )
      ObjC::MSG_VOID_1.call(inv, ObjC.sel('setSelector:'), ObjC.sel('locationInWindow'))
      ObjC::MSG_VOID_1.call(inv, ObjC.sel('invokeWithTarget:'), event_ptr)
      buf = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
      ObjC::MSG_VOID_1.call(inv, ObjC.sel('getReturnValue:'), buf)
      buf[0, 16].unpack('dd')
    end

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
        attrs = ObjC.nsdict({ObjC::NSFontAttributeName => @font})
        ns_m = ObjC.nsstring("M")
        @cell_width = ObjC::MSG_RET_D_1.call(ns_m, ObjC.sel('sizeWithAttributes:'), attrs)
      else
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
