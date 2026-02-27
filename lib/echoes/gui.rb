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
      @selection_color = make_color(*Echoes.config.selection_color)
      @search_match_color = make_color(0.6, 0.5, 0.0)
      @search_current_color = make_color(0.8, 0.6, 0.0)
      @selection_anchor = nil
      @selection_end = nil
      @font_cache = {}
      @rgb_color_cache = {}
      @nsstring_cache = {}
      @cursor_blink_on = true
      @cursor_blink_counter = 0
      @search_mode = false
      @search_query = +""
      @search_matches = []
      @search_index = -1
      @bell_flash = 0
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
      tab = Tab.new(command: @command, rows: @rows, cols: @cols)
      tab.title = "Tab #{@tabs.size + 1}"
      if @cell_width && @cell_height
        tab.screen.cell_pixel_width = @cell_width
        tab.screen.cell_pixel_height = @cell_height
      end
      tab.screen.clipboard_handler = method(:handle_clipboard)
      @tabs << tab
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

    def grid_y_offset
      Echoes.config.tab_position == :bottom ? 0.0 : tab_bar_height
    end

    def tab_bar_y
      Echoes.config.tab_position == :bottom ? @cell_height * @rows : 0.0
    end

    def setup_app
      @app = ObjC::MSG_PTR.call(ObjC.cls('NSApplication'), ObjC.sel('sharedApplication'))
      ObjC::MSG_VOID_I.call(@app, ObjC.sel('setActivationPolicy:'), 0)
      setup_menu_bar
    end

    def setup_menu_bar
      main_menu = create_menu('')

      # Application menu
      app_menu = create_menu('Echoes')
      add_menu_item(app_menu, "About Echoes", 'orderFrontStandardAboutPanel:', '')
      add_separator(app_menu)
      add_menu_item(app_menu, "Hide Echoes", 'hide:', 'h')
      add_menu_item(app_menu, "Hide Others", 'hideOtherApplications:', '')
      add_menu_item(app_menu, "Show All", 'unhideAllApplications:', '')
      add_separator(app_menu)
      add_menu_item(app_menu, "Quit Echoes", 'terminate:', 'q')
      add_submenu(main_menu, app_menu, 'Echoes')

      # Edit menu
      edit_menu = create_menu('Edit')
      add_menu_item(edit_menu, "Copy", 'copy:', 'c')
      add_menu_item(edit_menu, "Paste", 'paste:', 'v')
      add_menu_item(edit_menu, "Select All", 'selectAll:', 'a')
      add_submenu(main_menu, edit_menu, 'Edit')

      # View menu
      view_menu = create_menu('View')
      add_menu_item(view_menu, "Bigger", 'increaseFontSize:', '+')
      add_menu_item(view_menu, "Smaller", 'decreaseFontSize:', '-')
      add_menu_item(view_menu, "Reset Font Size", 'resetFontSize:', '0')
      add_separator(view_menu)
      add_menu_item(view_menu, "Find", 'toggleFind:', 'f')
      add_submenu(main_menu, view_menu, 'View')

      # Window menu
      window_menu = create_menu('Window')
      add_menu_item(window_menu, "Minimize", 'miniaturize:', 'm')
      add_menu_item(window_menu, "Zoom", 'zoom:', '')
      add_menu_item(window_menu, "Enter Full Screen", 'toggleFullScreen:', 'f',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagControl)
      add_separator(window_menu)
      add_menu_item(window_menu, "Show Previous Tab", 'showPreviousTab:', '{',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift)
      add_menu_item(window_menu, "Show Next Tab", 'showNextTab:', '}',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift)
      add_submenu(main_menu, window_menu, 'Window')

      # Shell menu
      shell_menu = create_menu('Shell')
      add_menu_item(shell_menu, "New Tab", 'newTab:', 't')
      add_menu_item(shell_menu, "Close Tab", 'closeTab:', 'w')
      add_submenu(main_menu, shell_menu, 'Shell')

      ObjC::MSG_VOID_1.call(@app, ObjC.sel('setMainMenu:'), main_menu)
    end

    private def create_menu(title)
      m = ObjC::MSG_PTR.call(ObjC.cls('NSMenu'), ObjC.sel('alloc'))
      ObjC::MSG_PTR_1.call(m, ObjC.sel('initWithTitle:'), ObjC.nsstring(title))
    end

    private def add_menu_item(menu, title, action, key, modifiers: ObjC::NSEventModifierFlagCommand)
      item = ObjC::MSG_PTR.call(ObjC.cls('NSMenuItem'), ObjC.sel('alloc'))
      item = ObjC::MSG_PTR_3.call(item, ObjC.sel('initWithTitle:action:keyEquivalent:'),
        ObjC.nsstring(title), action.empty? ? Fiddle::Pointer.new(0) : ObjC.sel(action), ObjC.nsstring(key))
      if modifiers != ObjC::NSEventModifierFlagCommand && !key.empty?
        ObjC::MSG_VOID_L.call(item, ObjC.sel('setKeyEquivalentModifierMask:'), modifiers)
      end
      ObjC::MSG_VOID_1.call(menu, ObjC.sel('addItem:'), item)
      item
    end

    private def add_separator(menu)
      sep = ObjC::MSG_PTR.call(ObjC.cls('NSMenuItem'), ObjC.sel('separatorItem'))
      ObjC::MSG_VOID_1.call(menu, ObjC.sel('addItem:'), sep)
    end

    private def add_submenu(parent, submenu, title)
      item = ObjC::MSG_PTR.call(ObjC.cls('NSMenuItem'), ObjC.sel('alloc'))
      item = ObjC::MSG_PTR_3.call(item, ObjC.sel('initWithTitle:action:keyEquivalent:'),
        ObjC.nsstring(title), Fiddle::Pointer.new(0), ObjC.nsstring(''))
      ObjC::MSG_VOID_1.call(item, ObjC.sel('setSubmenu:'), submenu)
      ObjC::MSG_VOID_1.call(parent, ObjC.sel('addItem:'), item)
    end

    def create_window
      @font = ObjC.retain(create_nsfont(@font_size))
      @bold_font = ObjC.retain(create_bold_nsfont(@font))

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
      ) { |_self, _cmd, x, y, w, h| gui.draw_rect(y, y + h) }

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

      @mouse_dragged_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.mouse_dragged(event) }

      @mouse_up_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.mouse_up(event) }

      @right_mouse_down_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.right_mouse_down(event) }

      @right_mouse_dragged_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.right_mouse_dragged(event) }

      @right_mouse_up_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.right_mouse_up(event) }

      @other_mouse_down_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.other_mouse_down(event) }

      @other_mouse_dragged_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.other_mouse_dragged(event) }

      @other_mouse_up_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.other_mouse_up(event) }

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

      menu_action = proc { |action_block|
        Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd, _sender| action_block.call }
      }

      @new_tab_closure = menu_action.call(-> {
        gui.create_tab
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @close_tab_closure = menu_action.call(-> {
        gui.close_tab(@active_tab)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @copy_closure = menu_action.call(-> { gui.copy_to_clipboard })
      @paste_closure = menu_action.call(-> { gui.paste_from_clipboard })
      @select_all_closure = menu_action.call(-> { gui.select_all })
      @increase_font_closure = menu_action.call(-> { gui.update_font(@font_size + 1.0) })
      @decrease_font_closure = menu_action.call(-> { gui.update_font(@font_size - 1.0) if @font_size > 4.0 })
      @reset_font_closure = menu_action.call(-> { gui.update_font(Echoes.config.font_size) })
      @toggle_find_closure = menu_action.call(-> {
        gui.toggle_search
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @prev_tab_closure = menu_action.call(-> {
        @active_tab = (@active_tab - 1) % @tabs.size
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @next_tab_closure = menu_action.call(-> {
        @active_tab = (@active_tab + 1) % @tabs.size
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })

      @focus_gained_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, _notification| gui.window_focus_changed(true) }

      @focus_lost_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, _notification| gui.window_focus_changed(false) }

      @view_class = ObjC.define_class('EchoesTerminalView', 'NSView', {
        'drawRect:'             => ['v@:{CGRect=dddd}', @draw_rect_closure],
        'keyDown:'              => ['v@:@', @key_down_closure],
        'acceptsFirstResponder' => ['c@:', @accepts_fr_closure],
        'timerFired:'           => ['v@:@', @timer_fired_closure],
        'isFlipped'             => ['c@:', @is_flipped_closure],
        'scrollWheel:'          => ['v@:@', @scroll_wheel_closure],
        'mouseDown:'            => ['v@:@', @mouse_down_closure],
        'mouseDragged:'         => ['v@:@', @mouse_dragged_closure],
        'mouseUp:'              => ['v@:@', @mouse_up_closure],
        'rightMouseDown:'       => ['v@:@', @right_mouse_down_closure],
        'rightMouseDragged:'    => ['v@:@', @right_mouse_dragged_closure],
        'rightMouseUp:'         => ['v@:@', @right_mouse_up_closure],
        'otherMouseDown:'       => ['v@:@', @other_mouse_down_closure],
        'otherMouseDragged:'    => ['v@:@', @other_mouse_dragged_closure],
        'otherMouseUp:'         => ['v@:@', @other_mouse_up_closure],
        'performKeyEquivalent:' => ['c@:@', @perform_key_equiv_closure],
        'setFrameSize:'         => ['v@:{CGSize=dd}', @set_frame_size_closure],
        'windowDidBecomeKey:'   => ['v@:@', @focus_gained_closure],
        'windowDidResignKey:'   => ['v@:@', @focus_lost_closure],
        'newTab:'               => ['v@:@', @new_tab_closure],
        'closeTab:'             => ['v@:@', @close_tab_closure],
        'copy:'                 => ['v@:@', @copy_closure],
        'paste:'                => ['v@:@', @paste_closure],
        'selectAll:'            => ['v@:@', @select_all_closure],
        'increaseFontSize:'     => ['v@:@', @increase_font_closure],
        'decreaseFontSize:'     => ['v@:@', @decrease_font_closure],
        'resetFontSize:'        => ['v@:@', @reset_font_closure],
        'toggleFind:'           => ['v@:@', @toggle_find_closure],
        'showPreviousTab:'      => ['v@:@', @prev_tab_closure],
        'showNextTab:'          => ['v@:@', @next_tab_closure],
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

      setup_focus_notifications
    end

    def setup_focus_notifications
      nc = ObjC::MSG_PTR.call(ObjC.cls('NSNotificationCenter'), ObjC.sel('defaultCenter'))
      ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
        @view, ObjC.sel('windowDidBecomeKey:'),
        ObjC.nsstring('NSWindowDidBecomeKeyNotification'), @window)
      ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
        @view, ObjC.sel('windowDidResignKey:'),
        ObjC.nsstring('NSWindowDidResignKeyNotification'), @window)
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

    def draw_rect(dirty_min_y = 0.0, dirty_max_y = Float::INFINITY)
      # Autorelease pool to prevent temporary object accumulation
      pool = ObjC::MSG_PTR.call(ObjC.cls('NSAutoreleasePool'), ObjC.sel('alloc'))
      pool = ObjC::MSG_PTR.call(pool, ObjC.sel('init'))

      tab = current_tab
      tbh = tab_bar_height
      gy_off = grid_y_offset

      # Fill dirty region background
      ObjC::MSG_VOID.call(@default_bg, ObjC.sel('setFill'))
      ObjC::NSRectFill.call(0.0, dirty_min_y, @cell_width * (@cols + 1), dirty_max_y - dirty_min_y)

      # Draw tab bar if it intersects the dirty region
      if tbh > 0
        tby = tab_bar_y
        if dirty_min_y < tby + tbh && dirty_max_y > tby
          draw_tab_bar(tbh, tby)
        end
      end

      # Draw terminal grid
      screen = tab.screen
      scrollback = screen.scrollback
      visible_start = scrollback.size - tab.scroll_offset

      @rows.times do |r|
        y = gy_off + r * @cell_height
        next if y + @cell_height < dirty_min_y || y > dirty_max_y
        src = visible_start + r
        row = if src < scrollback.size
                scrollback[src]
              else
                screen.grid[src - scrollback.size]
              end

        row.each_with_index do |cell, c|
          # Skip continuation cells (second half of wide chars or multicell)
          next if cell.width == 0
          next if cell.multicell == :cont

          fg_val = cell.fg
          bg_val = cell.bg
          if cell.inverse
            fg_val, bg_val = bg_val, fg_val
          end

          fg_color = resolve_color(fg_val, @default_fg)
          bg_color = resolve_color(bg_val, @default_bg)

          if cell.bold && fg_val.is_a?(Integer) && fg_val < 8
            fg_color = @colors[fg_val + 8]
          end

          has_bg = !bg_val.nil?

          selected = cell_selected?(src, c)
          is_match = @search_mode && search_match_at?(src, c)
          is_current_match = @search_mode && current_search_match_at?(src, c)

          if cell.multicell.is_a?(Hash)
            mc = cell.multicell
            x = c * @cell_width
            block_w = mc[:cols] * @cell_width
            block_h = mc[:rows] * @cell_height

            if selected
              ObjC::MSG_VOID.call(@selection_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, block_w, block_h)
            elsif has_bg
              ObjC::MSG_VOID.call(bg_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, block_w, block_h)
            end

            if mc[:sixel]
              draw_sixel_image(mc[:sixel], x, y, block_w, block_h)
              next
            end

            next if cell.char == " " && !has_bg

            effective_scale = mc[:scale].to_f
            if mc[:frac_d] > 0 && mc[:frac_d] > mc[:frac_n]
              effective_scale *= (1.0 + mc[:frac_n].to_f / mc[:frac_d])
            end
            scaled_font = ObjC.retain(create_nsfont(@font_size * effective_scale))
            if cell.bold
              regular = scaled_font
              scaled_font = ObjC.retain(create_bold_nsfont(regular))
              ObjC.release(regular)
            end

            draw_attrs = {
              ObjC::NSFontAttributeName => scaled_font,
              ObjC::NSForegroundColorAttributeName => fg_color,
            }
            if cell.underline
              draw_attrs[ObjC::NSUnderlineStyleAttributeName] = ObjC.nsnumber_int(1)
            end
            ns_attrs = ObjC.nsdict(draw_attrs)
            ns_char = cached_nsstring(cell.char)

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

            if is_current_match
              ObjC::MSG_VOID.call(@search_current_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, cell_w, @cell_height)
            elsif is_match
              ObjC::MSG_VOID.call(@search_match_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, cell_w, @cell_height)
            elsif selected
              ObjC::MSG_VOID.call(@selection_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, cell_w, @cell_height)
            elsif has_bg
              ObjC::MSG_VOID.call(bg_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(x, y, cell_w, @cell_height)
            end

            next if cell.char == " " && !has_bg && !selected && !is_match

            base_font = cell.bold ? @bold_font : font_for_char(cell.char)
            if cell.italic
              base_font = create_italic_nsfont(base_font)
            end
            if cell.concealed || (cell.blink && !@cursor_blink_on)
              fg_color = bg_color
            elsif cell.faint
              fg_color = make_color_with_alpha(fg_color, 0.5)
            end
            attrs = {
              ObjC::NSFontAttributeName => base_font,
              ObjC::NSForegroundColorAttributeName => fg_color,
            }
            if cell.underline
              attrs[ObjC::NSUnderlineStyleAttributeName] = ObjC.nsnumber_int(1)
            end
            if cell.strikethrough
              attrs[ObjC::NSStrikethroughStyleAttributeName] = ObjC.nsnumber_int(1)
            end
            ns_attrs = ObjC.nsdict(attrs)
            ns_char = cached_nsstring(cell.char)
            ObjC::MSG_VOID_PT_1.call(ns_char, ObjC.sel('drawAtPoint:withAttributes:'), x, y, ns_attrs)
          end
        end
      end

      # Draw cursor (only when at live view)
      if tab.scroll_offset == 0 && screen.cursor.visible
        style = screen.cursor_style
        blink = style.odd? || style == 0
        if !blink || @cursor_blink_on
          cx = screen.cursor.col * @cell_width
          cy = gy_off + screen.cursor.row * @cell_height
          cursor_color = make_color(*Echoes.config.cursor_color)
          ObjC::MSG_VOID.call(cursor_color, ObjC.sel('setFill'))
          case style
          when 3, 4 # underline
            ObjC::NSRectFill.call(cx, cy + @cell_height - 2.0, @cell_width, 2.0)
          when 5, 6 # bar
            ObjC::NSRectFill.call(cx, cy, 2.0, @cell_height)
          else # block (0, 1, 2)
            ObjC::NSRectFill.call(cx, cy, @cell_width, @cell_height)
            # Draw character under cursor with inverted colors
            cell = screen.grid[screen.cursor.row][screen.cursor.col]
            if cell.char != ' '
              inv_fg = @default_bg
              ns_attrs = ObjC.nsdict({
                ObjC::NSFontAttributeName => cell.bold ? @bold_font : font_for_char(cell.char),
                ObjC::NSForegroundColorAttributeName => inv_fg,
              })
              ns_char = cached_nsstring(cell.char)
              ObjC::MSG_VOID_PT_1.call(ns_char, ObjC.sel('drawAtPoint:withAttributes:'), cx, cy, ns_attrs)
            end
          end
        end
      end

      # Visual bell flash
      if @bell_flash > 0
        flash_color = make_color_with_alpha(make_color(1.0, 1.0, 1.0), 0.15)
        ObjC::MSG_VOID.call(flash_color, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(0.0, gy_off, @cols * @cell_width, @rows * @cell_height)
      end

      # Draw search bar
      if @search_mode
        bar_h = @cell_height + 4.0
        bar_y = gy_off + @rows * @cell_height
        bar_bg = make_color(0.2, 0.2, 0.2)
        ObjC::MSG_VOID.call(bar_bg, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(0.0, bar_y, @cols * @cell_width, bar_h)

        match_info = @search_matches.empty? ? "" : " [#{@search_index + 1}/#{@search_matches.size}]"
        label = "Find: #{@search_query}_#{match_info}"
        ns_str = ObjC.nsstring(label)
        ns_attrs = ObjC.nsdict({
          ObjC::NSFontAttributeName => @font,
          ObjC::NSForegroundColorAttributeName => make_color(1.0, 1.0, 1.0),
        })
        ObjC::MSG_VOID_PT_1.call(ns_str, ObjC.sel('drawAtPoint:withAttributes:'), 4.0, bar_y + 2.0, ns_attrs)
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
      when "c"
        copy_to_clipboard
        return 1
      when "v"
        paste_from_clipboard
        return 1
      when "f"
        toggle_search
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        return 1
      when "g"
        if @search_mode && !@search_matches.empty?
          if (flags & ObjC::NSEventModifierFlagShift) != 0
            search_prev
          else
            search_next
          end
          ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        end
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
      if @search_mode
        search_key_down(event_ptr)
        return
      end

      @selection_anchor = nil
      @selection_end = nil

      tab = current_tab
      tab.scroll_offset = 0
      tab.scroll_accum = 0.0

      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))
      chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('charactersIgnoringModifiers'))
      chars = ObjC.to_ruby_string(chars_ns)
      return if chars.empty?

      mod = modifier_param(flags)

      if mod > 1 && (seq = map_modified_key(chars, mod))
        tab.pty_write.write(seq)
      elsif (flags & ObjC::NSEventModifierFlagControl) != 0
        ctrl_char = (chars[0].ord & 0x1F).chr
        tab.pty_write.write(ctrl_char)
      elsif (flags & ObjC::NSEventModifierFlagOption) != 0
        tab.pty_write.write("\e#{chars}")
      else
        chars_ns2 = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('characters'))
        chars2 = ObjC.to_ruby_string(chars_ns2)
        numpad = (flags & ObjC::NSEventModifierFlagNumericPad) != 0
        tab.pty_write.write(map_special_keys(chars2.empty? ? chars : chars2, tab.screen.application_cursor_keys?, app_keypad: numpad && tab.screen.application_keypad))
      end
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def timer_fired
      need_redraw = false

      @tabs.each do |tab|
        begin
          loop do
            data = tab.pty_read.read_nonblock(16384)
            tab.parser.feed(data)
            need_redraw = true
          end
        rescue IO::WaitReadable
          # No more data for this tab
        rescue EOFError, Errno::EIO
          # Tab's process exited — will be cleaned up
        end
        if need_redraw && tab.screen.title
          tab.title = tab.screen.title
          tab.screen.title = nil
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

      tab = current_tab
      if tab&.screen&.bell
        tab.screen.bell = false
        @bell_flash = 3
        need_redraw = true
      elsif @bell_flash > 0
        @bell_flash -= 1
        need_redraw = true
      end

      @cursor_blink_counter += 1
      if @cursor_blink_counter >= 30
        @cursor_blink_counter = 0
        @cursor_blink_on = !@cursor_blink_on
        need_redraw = true
      end

      tab = current_tab
      return unless tab

      screen = tab.screen
      full_redraw = !need_redraw && (@bell_flash > 0 || @cursor_blink_counter == 0)

      if need_redraw
        ObjC::MSG_VOID_1.call(@window, ObjC.sel('setTitle:'), ObjC.nsstring(tab.title))

        dirty = screen.dirty_rows
        screen.clear_dirty

        if full_redraw || dead&.any? || dirty.size > @rows / 2
          ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        else
          # Also always invalidate the cursor row
          dirty << screen.cursor.row
          invalidate_dirty_rows(dirty)
        end
      elsif full_redraw
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end
    end

    def invalidate_dirty_rows(dirty_rows)
      gy_off = grid_y_offset
      width = @cell_width * @cols
      dirty_rows.each do |r|
        next if r < 0 || r >= @rows
        y = gy_off + r * @cell_height
        ObjC::MSG_VOID_RECT.call(@view, ObjC.sel('setNeedsDisplayInRect:'), 0.0, y, width, @cell_height)
      end
    end

    def scroll_wheel(event_ptr)
      tab = current_tab
      screen = tab.screen

      if screen.mouse_tracking != :off
        delta = ObjC::MSG_RET_D.call(event_ptr, ObjC.sel('deltaY'))
        pos = grid_position(event_ptr)
        return unless pos
        row, col = pos
        button = delta > 0 ? 64 : 65  # 64=scroll up, 65=scroll down
        send_mouse_event(tab, button, col, row)
        return
      end

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
      tab = current_tab
      pos = grid_position(event_ptr)
      click_count = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('clickCount'))

      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))

      if pos.nil?
        # Click in tab bar
        click_x, = event_location(event_ptr)
        tab_w = (@cell_width * @cols) / @tabs.size
        clicked_tab = (click_x / tab_w).to_i.clamp(0, @tabs.size - 1)
        @active_tab = clicked_tab
      elsif (flags & ObjC::NSEventModifierFlagCommand) != 0 && pos
        # Cmd+click: open hyperlink or detected URL
        abs_row, col = pos
        url = hyperlink_at(tab, abs_row, col)
        open_url(url) if url
      elsif tab.screen.mouse_tracking != :off
        row, col = pos
        send_mouse_event(tab, 0, col, row)  # button 0 = left press
      elsif click_count >= 3
        # Triple-click: select entire line
        abs_row, = pos
        @selection_anchor = [abs_row, 0]
        @selection_end = [abs_row, @cols - 1]
      elsif click_count == 2
        # Double-click: select word
        abs_row, col = pos
        row_data = row_at(tab, abs_row)
        if row_data
          bounds = word_boundaries_in_row(row_data, col)
          if bounds
            @selection_anchor = [abs_row, bounds[0]]
            @selection_end = [abs_row, bounds[1]]
          end
        end
      else
        # Single click: start drag selection
        @selection_anchor = pos
        @selection_end = nil
      end

      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    def mouse_dragged(event_ptr)
      tab = current_tab
      pos = grid_position(event_ptr)
      return unless pos

      if tab.screen.mouse_tracking == :button_event || tab.screen.mouse_tracking == :any_event
        row, col = pos
        send_mouse_event(tab, 32, col, row)  # 32 = left drag (button 0 + 32)
      else
        @selection_end = pos
      end
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    def mouse_up(event_ptr)
      tab = current_tab
      return if tab.screen.mouse_tracking == :off || tab.screen.mouse_tracking == :x10

      pos = grid_position(event_ptr)
      return unless pos
      row, col = pos
      send_mouse_event(tab, 3, col, row, release: true)  # 3 = release
    end

    def right_mouse_down(event_ptr)
      tab = current_tab
      return if tab.screen.mouse_tracking == :off

      pos = grid_position(event_ptr)
      return unless pos
      row, col = pos
      send_mouse_event(tab, 2, col, row)  # button 2 = right press
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def right_mouse_dragged(event_ptr)
      tab = current_tab
      return unless tab.screen.mouse_tracking == :button_event || tab.screen.mouse_tracking == :any_event

      pos = grid_position(event_ptr)
      return unless pos
      row, col = pos
      send_mouse_event(tab, 34, col, row)  # 34 = right drag (button 2 + 32)
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def right_mouse_up(event_ptr)
      tab = current_tab
      return if tab.screen.mouse_tracking == :off || tab.screen.mouse_tracking == :x10

      pos = grid_position(event_ptr)
      return unless pos
      row, col = pos
      send_mouse_event(tab, 3, col, row, release: true)
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def other_mouse_down(event_ptr)
      tab = current_tab
      return if tab.screen.mouse_tracking == :off

      pos = grid_position(event_ptr)
      return unless pos
      row, col = pos
      send_mouse_event(tab, 1, col, row)  # button 1 = middle press
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def other_mouse_dragged(event_ptr)
      tab = current_tab
      return unless tab.screen.mouse_tracking == :button_event || tab.screen.mouse_tracking == :any_event

      pos = grid_position(event_ptr)
      return unless pos
      row, col = pos
      send_mouse_event(tab, 33, col, row)  # 33 = middle drag (button 1 + 32)
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def other_mouse_up(event_ptr)
      tab = current_tab
      return if tab.screen.mouse_tracking == :off || tab.screen.mouse_tracking == :x10

      pos = grid_position(event_ptr)
      return unless pos
      row, col = pos
      send_mouse_event(tab, 3, col, row, release: true)
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
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

    def window_focus_changed(focused)
      tab = current_tab
      return unless tab&.screen&.focus_reporting?

      seq = focused ? "\e[I" : "\e[O"
      tab.pty_write.write(seq) rescue nil
    end

    def update_font(new_size)
      @font_size = new_size
      old_font = @font
      old_bold = @bold_font
      @font = ObjC.retain(create_nsfont(@font_size))
      @bold_font = ObjC.retain(create_bold_nsfont(@font))
      ObjC.release(old_font) if old_font
      ObjC.release(old_bold) if old_bold
      @font_cache.each_value { |f| ObjC.release(f) unless f.to_i == old_font&.to_i }
      @font_cache = {}
      update_cell_metrics

      win_width = @cell_width * @cols
      win_height = tab_bar_height + @cell_height * @rows

      ObjC::MSG_VOID_2D.call(@window, ObjC.sel('setContentSize:'), win_width, win_height)
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    private

    def select_all
      tab = current_tab
      return unless tab
      screen = tab.screen
      total = screen.scrollback.size + screen.rows
      @selection_anchor = [0, 0]
      @selection_end = [total - 1, screen.cols - 1]
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    def copy_to_clipboard
      sr, sc, er, ec = selection_range
      return unless sr

      text = selected_text_from_buffer(sr, sc, er, ec)
      return if text.empty?

      pb = ObjC::MSG_PTR.call(ObjC.cls('NSPasteboard'), ObjC.sel('generalPasteboard'))
      ObjC::MSG_PTR.call(pb, ObjC.sel('clearContents'))
      ObjC::MSG_PTR_2.call(pb, ObjC.sel('setString:forType:'), ObjC.nsstring(text), ObjC::NSPasteboardTypeString)
    end

    def handle_clipboard(action, text)
      pb = ObjC::MSG_PTR.call(ObjC.cls('NSPasteboard'), ObjC.sel('generalPasteboard'))
      case action
      when :set
        ObjC::MSG_PTR.call(pb, ObjC.sel('clearContents'))
        ObjC::MSG_PTR_2.call(pb, ObjC.sel('setString:forType:'), ObjC.nsstring(text), ObjC::NSPasteboardTypeString)
        nil
      when :get
        ns_str = ObjC::MSG_PTR_1.call(pb, ObjC.sel('stringForType:'), ObjC::NSPasteboardTypeString)
        return nil if ns_str.null?
        ObjC.to_ruby_string(ns_str)
      end
    end

    def paste_from_clipboard
      pb = ObjC::MSG_PTR.call(ObjC.cls('NSPasteboard'), ObjC.sel('generalPasteboard'))
      ns_str = ObjC::MSG_PTR_1.call(pb, ObjC.sel('stringForType:'), ObjC::NSPasteboardTypeString)
      return if ns_str.null?

      str = ObjC.to_ruby_string(ns_str)
      return if str.empty?

      tab = current_tab
      if tab.screen.bracketed_paste_mode?
        tab.pty_write.write("\e[200~")
        tab.pty_write.write(str)
        tab.pty_write.write("\e[201~")
      else
        tab.pty_write.write(str)
      end
    rescue Errno::EIO, IOError
    end

    def draw_sixel_image(sixel, x, y, draw_w, draw_h)
      # Cache CGImage on first render
      unless sixel[:cg_image]
        rgba = sixel[:rgba]
        w = sixel[:width]
        h = sixel[:height]

        rgba_ptr = Fiddle::Pointer.to_ptr(rgba)
        color_space = ObjC::CGColorSpaceCreateDeviceRGB.call
        ctx = ObjC::CGBitmapContextCreate.call(
          rgba_ptr, w, h, 8, w * 4, color_space,
          ObjC::KCGImageAlphaPremultipliedLast
        )
        sixel[:cg_image] = ObjC::CGBitmapContextCreateImage.call(ctx)
        ObjC::CGContextRelease.call(ctx)
        ObjC::CGColorSpaceRelease.call(color_space)
      end

      cg_image = sixel[:cg_image]
      return if cg_image.null?

      # Get current CGContext
      ns_ctx = ObjC::MSG_PTR.call(ObjC.cls('NSGraphicsContext'), ObjC.sel('currentContext'))
      cg_ctx = ObjC::MSG_PTR.call(ns_ctx, ObjC.sel('CGContext'))

      # Draw with flipping (view is flipped, but CGContext draws bottom-up)
      ObjC::CGContextSaveGState.call(cg_ctx)
      ObjC::CGContextTranslateCTM.call(cg_ctx, x, y + draw_h)
      ObjC::CGContextScaleCTM.call(cg_ctx, 1.0, -1.0)
      ObjC::CGContextDrawImage.call(cg_ctx, 0.0, 0.0, draw_w, draw_h, cg_image)
      ObjC::CGContextRestoreGState.call(cg_ctx)
    end

    def draw_tab_bar(tbh, ty)
      total_w = @cell_width * @cols
      tab_w = total_w / @tabs.size

      # Tab bar background
      ObjC::MSG_VOID.call(@tab_bg, ObjC.sel('setFill'))
      ObjC::NSRectFill.call(0.0, ty, total_w + @cell_width, tbh)

      @tabs.each_with_index do |tab, i|
        x = i * tab_w

        # Active tab highlight
        if i == @active_tab
          ObjC::MSG_VOID.call(@tab_active_bg, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(x, ty, tab_w, tbh)
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
        ObjC::MSG_VOID_PT_1.call(ns_label, ObjC.sel('drawAtPoint:withAttributes:'), text_x, ty, ns_attrs)

        # Separator line between tabs
        if i < @tabs.size - 1
          sep_color = make_color(0.4, 0.4, 0.4)
          ObjC::MSG_VOID.call(sep_color, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(x + tab_w - 0.5, ty + 2.0, 1.0, tbh - 4.0)
        end
      end
    end

    def grid_position(event_ptr)
      x, y_in_window = event_location(event_ptr)
      view_height = @view_height || (tab_bar_height + @rows * @cell_height)
      y = view_height - y_in_window
      gy_off = grid_y_offset
      grid_y = y - gy_off
      return nil if grid_y < 0 || grid_y >= @rows * @cell_height

      visible_row = (grid_y / @cell_height).to_i.clamp(0, @rows - 1)
      col = (x / @cell_width).to_i.clamp(0, @cols - 1)
      # Return absolute row (scrollback + grid index)
      tab = current_tab
      scrollback_size = tab.screen.scrollback.size
      abs_row = scrollback_size - tab.scroll_offset + visible_row
      [abs_row, col]
    end

    def selection_range
      return nil unless @selection_anchor && @selection_end

      a_r, a_c = @selection_anchor
      b_r, b_c = @selection_end
      if a_r < b_r || (a_r == b_r && a_c <= b_c)
        [a_r, a_c, b_r, b_c]
      else
        [b_r, b_c, a_r, a_c]
      end
    end

    def toggle_search
      @search_mode = !@search_mode
      if @search_mode
        @search_query = +""
        @search_matches = []
        @search_index = -1
      end
    end

    def search_key_down(event_ptr)
      chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('characters'))
      chars = ObjC.to_ruby_string(chars_ns)
      key_code = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('keyCode'))
      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))

      case key_code
      when 53 # Escape
        @search_mode = false
        @search_matches = []
      when 36 # Return
        if (flags & ObjC::NSEventModifierFlagShift) != 0
          search_prev
        else
          search_next
        end
      when 51 # Backspace
        @search_query.chop!
        perform_search
      else
        unless chars.empty? || chars[0].ord < 0x20
          @search_query << chars
          perform_search
        end
      end
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    def perform_search
      @search_matches = []
      @search_index = -1
      return if @search_query.empty?

      tab = current_tab
      screen = tab.screen
      scrollback = screen.scrollback

      # Search scrollback
      scrollback.each_with_index do |row, abs_row|
        text = row.map(&:char).join
        pos = 0
        while (idx = text.index(@search_query, pos))
          @search_matches << [abs_row, idx, @search_query.length]
          pos = idx + 1
        end
      end

      # Search grid
      screen.grid.each_with_index do |row, grid_row|
        abs_row = scrollback.size + grid_row
        text = row.map(&:char).join
        pos = 0
        while (idx = text.index(@search_query, pos))
          @search_matches << [abs_row, idx, @search_query.length]
          pos = idx + 1
        end
      end

      @search_index = @search_matches.size - 1 if @search_matches.any?
      scroll_to_match if @search_index >= 0
    end

    def search_next
      return if @search_matches.empty?
      @search_index = (@search_index + 1) % @search_matches.size
      scroll_to_match
    end

    def search_prev
      return if @search_matches.empty?
      @search_index = (@search_index - 1) % @search_matches.size
      scroll_to_match
    end

    def scroll_to_match
      abs_row, = @search_matches[@search_index]
      tab = current_tab
      scrollback_size = tab.screen.scrollback.size
      if abs_row < scrollback_size
        tab.scroll_offset = scrollback_size - abs_row - (@rows / 2)
        tab.scroll_offset = tab.scroll_offset.clamp(0, scrollback_size)
      else
        tab.scroll_offset = 0
      end
    end

    def search_match_at?(abs_row, col)
      @search_matches.any? { |r, c, len| r == abs_row && col >= c && col < c + len }
    end

    def current_search_match_at?(abs_row, col)
      return false if @search_index < 0 || @search_index >= @search_matches.size
      r, c, len = @search_matches[@search_index]
      r == abs_row && col >= c && col < c + len
    end

    URL_REGEX = /https?:\/\/\S+/

    def hyperlink_at(tab, abs_row, col)
      row = row_at(tab, abs_row)
      return nil unless row

      # Check OSC 8 hyperlink first
      cell = row[col]
      return cell.hyperlink if cell&.hyperlink

      # Detect URL in row text
      text = row.map(&:char).join
      text.scan(URL_REGEX) do |url|
        start = Regexp.last_match.begin(0)
        if col >= start && col < start + url.length
          return url
        end
      end
      nil
    end

    def open_url(url)
      ns_url = ObjC::MSG_PTR_1.call(ObjC.cls('NSURL'), ObjC.sel('URLWithString:'), ObjC.nsstring(url))
      return if ns_url.null?
      workspace = ObjC::MSG_PTR.call(ObjC.cls('NSWorkspace'), ObjC.sel('sharedWorkspace'))
      ObjC::MSG_PTR_1.call(workspace, ObjC.sel('openURL:'), ns_url)
    end

    def row_at(tab, abs_row)
      scrollback = tab.screen.scrollback
      if abs_row < scrollback.size
        scrollback[abs_row]
      elsif abs_row - scrollback.size < tab.screen.rows
        tab.screen.grid[abs_row - scrollback.size]
      end
    end

    def word_boundaries_in_row(row, col)
      return nil if col < 0 || col >= row.size

      cls = char_class_of(row[col].char)
      start_col = col
      start_col -= 1 while start_col > 0 && char_class_of(row[start_col - 1].char) == cls
      end_col = col
      end_col += 1 while end_col < row.size - 1 && char_class_of(row[end_col + 1].char) == cls
      [start_col, end_col]
    end

    def char_class_of(c)
      if c.nil? || c.empty? || c == ' ' then :space
      elsif Echoes.config.word_separators.include?(c) then :separator
      else :word
      end
    end

    def selected_text_from_buffer(sr, sc, er, ec)
      screen = current_tab.screen
      scrollback = screen.scrollback
      lines = []
      (sr..er).each do |abs_row|
        row = if abs_row < scrollback.size
                scrollback[abs_row]
              else
                screen.grid[abs_row - scrollback.size]
              end
        next unless row

        from = (abs_row == sr) ? sc : 0
        to = (abs_row == er) ? ec : @cols - 1
        lines << row[from..to].map(&:char).join.rstrip
      end
      lines.join("\n")
    end

    def cell_selected?(row, col)
      range = selection_range
      return false unless range

      sr, sc, er, ec = range
      return false if row < sr || row > er
      return col >= sc && col <= ec if sr == er
      return col >= sc if row == sr
      return col <= ec if row == er

      true
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

    def create_bold_nsfont(font)
      fm = ObjC::MSG_PTR.call(ObjC.cls('NSFontManager'), ObjC.sel('sharedFontManager'))
      ObjC::MSG_PTR_1L.call(fm, ObjC.sel('convertFont:toHaveTrait:'), font, 0x2)  # NSBoldFontMask
    end

    def create_italic_nsfont(font)
      fm = ObjC::MSG_PTR.call(ObjC.cls('NSFontManager'), ObjC.sel('sharedFontManager'))
      ObjC::MSG_PTR_1L.call(fm, ObjC.sel('convertFont:toHaveTrait:'), font, 0x1)  # NSItalicFontMask
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

      # Propagate cell metrics to all screens for sixel sizing
      @tabs.each do |tab|
        tab.screen.cell_pixel_width = @cell_width
        tab.screen.cell_pixel_height = @cell_height
      end
    end

    def font_for_char(char)
      return @font if char.ascii_only?

      cached = @font_cache[char]
      return cached if cached

      ns_str = ObjC.nsstring(char)
      ns_len = ObjC::MSG_RET_L.call(ns_str, ObjC.sel('length'))
      fallback = ObjC::CTFontCreateForString.call(@font, ns_str, 0, ns_len)
      if fallback.to_i == @font.to_i
        @font_cache[char] = @font
      else
        @font_cache[char] = ObjC.retain(fallback)
      end
      @font_cache[char]
    end

    MODIFIED_KEYS = {
      "\u{F700}" => ['1', 'A'],   # Up
      "\u{F701}" => ['1', 'B'],   # Down
      "\u{F702}" => ['1', 'D'],   # Left
      "\u{F703}" => ['1', 'C'],   # Right
      "\u{F728}" => ['3', '~'],   # Delete
      "\u{F729}" => ['1', 'H'],   # Home
      "\u{F72B}" => ['1', 'F'],   # End
      "\u{F72C}" => ['5', '~'],   # Page Up
      "\u{F72D}" => ['6', '~'],   # Page Down
      "\u{F704}" => ['1', 'P'],   # F1
      "\u{F705}" => ['1', 'Q'],   # F2
      "\u{F706}" => ['1', 'R'],   # F3
      "\u{F707}" => ['1', 'S'],   # F4
      "\u{F708}" => ['15', '~'],  # F5
      "\u{F709}" => ['17', '~'],  # F6
      "\u{F70A}" => ['18', '~'],  # F7
      "\u{F70B}" => ['19', '~'],  # F8
      "\u{F70C}" => ['20', '~'],  # F9
      "\u{F70D}" => ['21', '~'],  # F10
      "\u{F70E}" => ['23', '~'],  # F11
      "\u{F70F}" => ['24', '~'],  # F12
    }.freeze

    def modifier_param(flags)
      m = 1
      m += 1 if (flags & ObjC::NSEventModifierFlagShift) != 0
      m += 2 if (flags & ObjC::NSEventModifierFlagOption) != 0
      m += 4 if (flags & ObjC::NSEventModifierFlagControl) != 0
      m
    end

    def map_modified_key(chars, mod)
      entry = MODIFIED_KEYS[chars]
      return nil unless entry

      param, final = entry
      "\e[#{param};#{mod}#{final}"
    end

    KEYPAD_APP_MAP = {
      '0' => "\eOp", '1' => "\eOq", '2' => "\eOr", '3' => "\eOs",
      '4' => "\eOt", '5' => "\eOu", '6' => "\eOv", '7' => "\eOw",
      '8' => "\eOx", '9' => "\eOy", '-' => "\eOm", '+' => "\eOk",
      '*' => "\eOj", '/' => "\eOo", '.' => "\eOn", "\r" => "\eOM",
      '=' => "\eOX",
    }.freeze

    def map_special_keys(chars, app_cursor = false, app_keypad: false)
      if app_keypad && (seq = KEYPAD_APP_MAP[chars])
        return seq
      end

      case chars
      when "\u{F700}" then app_cursor ? "\eOA" : "\e[A"    # Up
      when "\u{F701}" then app_cursor ? "\eOB" : "\e[B"    # Down
      when "\u{F702}" then app_cursor ? "\eOD" : "\e[D"    # Left
      when "\u{F703}" then app_cursor ? "\eOC" : "\e[C"    # Right
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

      # Override with user-configured palette
      if (palette = Echoes.config.color_palette)
        palette.each_with_index do |rgb, i|
          ansi_rgb[i] = rgb if i < 16 && rgb
        end
      end

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

    def send_mouse_event(tab, button, col, row, release: false)
      cx = col + 1
      cy = row + 1
      if tab.screen.mouse_encoding == :sgr
        final = release ? 'm' : 'M'
        tab.pty_write.write("\e[<#{button};#{cx};#{cy}#{final}")
      else
        tab.pty_write.write("\e[M#{(button + 32).chr}#{(cx + 32).chr}#{(cy + 32).chr}")
      end
    rescue Errno::EIO, IOError
    end

    def resolve_color(val, default)
      case val
      when nil then default
      when Integer then @colors[val]
      when Array
        key = (val[0] << 16) | (val[1] << 8) | val[2]
        @rgb_color_cache[key] ||= make_color(val[0] / 255.0, val[1] / 255.0, val[2] / 255.0)
      else default
      end
    end

    def make_color_with_alpha(color, alpha)
      ObjC::MSG_PTR_1D.call(color, ObjC.sel('colorWithAlphaComponent:'), alpha)
    end

    def cached_nsstring(str)
      @nsstring_cache[str] ||= ObjC.retain(ObjC.nsstring(str))
    end

    def make_color(r, g, b, a = 1.0)
      ObjC.retain(ObjC::MSG_PTR_4D.call(
        ObjC.cls('NSColor'), ObjC.sel('colorWithRed:green:blue:alpha:'),
        r, g, b, a
      ))
    end
  end
end
