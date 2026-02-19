# frozen_string_literal: true

require 'pty'

module Nutty
  class GUI
    FONT_SIZE = 14.0

    def initialize(command: ENV['SHELL'] || '/bin/bash', rows: 24, cols: 80, font_size: FONT_SIZE)
      @rows = rows
      @cols = cols
      @font_size = font_size
      @command = command
      @screen = Screen.new(rows: rows, cols: cols)
      @parser = Parser.new(@screen)
      @colors = build_color_table
      @default_fg = make_color(0.9, 0.9, 0.9)
      @default_bg = make_color(0.0, 0.0, 0.0)
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
      @font = ObjC::MSG_PTR_2D.call(
        ObjC.cls('NSFont'), ObjC.sel('monospacedSystemFontOfSize:weight:'),
        @font_size, 0.0
      )

      # Get cell width from maximumAdvancement (returns NSSize, d0 = width on arm64)
      @cell_width = ObjC::MSG_RET_D.call(@font, ObjC.sel('maximumAdvancement'))
      ascender = ObjC::MSG_RET_D.call(@font, ObjC.sel('ascender'))
      descender = ObjC::MSG_RET_D.call(@font, ObjC.sel('descender'))
      leading = ObjC::MSG_RET_D.call(@font, ObjC.sel('leading'))
      @cell_height = ascender - descender + leading

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

      ObjC::MSG_VOID_1.call(@window, ObjC.sel('setTitle:'), ObjC.nsstring('Nutty'))
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

      @view_class = ObjC.define_class('NuttyTerminalView', 'NSView', {
        'drawRect:'             => ['v@:{CGRect=dddd}', @draw_rect_closure],
        'keyDown:'              => ['v@:@', @key_down_closure],
        'acceptsFirstResponder' => ['c@:', @accepts_fr_closure],
        'timerFired:'           => ['v@:@', @timer_fired_closure],
        'isFlipped'             => ['c@:', @is_flipped_closure],
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

      # Fill entire background
      ObjC::MSG_VOID.call(@default_bg, ObjC.sel('setFill'))
      ObjC::NSRectFill.call(0.0, 0.0, @cell_width * @cols, @cell_height * @rows)

      @screen.grid.each_with_index do |row, r|
        y = r * @cell_height  # isFlipped makes y=0 at top

        row.each_with_index do |cell, c|
          x = c * @cell_width

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

          # Fill cell background (skip if default black)
          if bg_idx
            ObjC::MSG_VOID.call(bg_color, ObjC.sel('setFill'))
            ObjC::NSRectFill.call(x, y, @cell_width, @cell_height)
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

      # Draw cursor
      if @screen.cursor.visible
        cx = @screen.cursor.col * @cell_width
        cy = @screen.cursor.row * @cell_height
        cursor_color = make_color(0.7, 0.7, 0.7, 0.5)
        ObjC::MSG_VOID.call(cursor_color, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(cx, cy, @cell_width, @cell_height)
      end

      ObjC::MSG_VOID.call(pool, ObjC.sel('drain'))
    end

    def key_down(event_ptr)
      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))

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

    private

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
      ObjC::MSG_PTR_4D.call(
        ObjC.cls('NSColor'), ObjC.sel('colorWithRed:green:blue:alpha:'),
        r, g, b, a
      )
    end
  end
end
