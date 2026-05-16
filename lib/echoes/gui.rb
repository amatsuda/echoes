# frozen_string_literal: true

require 'pty'
require 'shellwords'
require 'socket'
require 'uri'
require 'json'

module Echoes
  class GUI
    CRASH_LOG = File.join(Dir.home, '.local', 'share', 'echoes', 'crash.log')

    def log_crash(exception, context: nil)
      dir = File.dirname(CRASH_LOG)
      Dir.mkdir(dir) unless Dir.exist?(dir)
      File.open(CRASH_LOG, 'a') do |f|
        f.puts "--- #{Time.now} ---"
        f.puts "Context: #{context}" if context
        f.puts "#{exception.class}: #{exception.message}"
        exception.backtrace&.each { |line| f.puts "  #{line}" }
        f.puts
      end
      STDERR.puts "echoes: #{exception.class}: #{exception.message} (logged to #{CRASH_LOG})"
    rescue # log_crash itself must never raise
    end

    def initialize(command: Echoes.config.shell, rows: Echoes.config.rows, cols: Echoes.config.cols, font_size: nil)
      @rows = rows
      @cols = cols
      # Persisted font size wins over the config default; both wrappers
      # gracefully fall through if NSUserDefaults isn't reachable.
      @font_size = font_size || Preferences.fetch_double(:font_size, default: Echoes.config.font_size)
      @command = command
      @tabs = []
      @active_tab = 0
      @active_profile = Echoes.config.default_profile
      @colors = build_color_table
      @default_fg = make_color(*@active_profile.foreground)
      @default_bg = make_color(*@active_profile.background)
      @tab_bg = make_color(0.15, 0.15, 0.15)
      @tab_active_bg = make_color(0.3, 0.3, 0.3)
      @tab_fg = make_color(0.8, 0.8, 0.8)
      @selection_color = make_color(*@active_profile.selection_color)
      @search_match_color = make_color(0.6, 0.5, 0.0)
      @search_current_color = make_color(0.8, 0.6, 0.0)
      @selection_anchor = nil
      @selection_end = nil
      @selection_word_anchor = nil
      @font_cache = {}
      @rgb_color_cache = {}
      @nsstring_cache = {}
      @cursor_blink_on = true
      @cursor_blink_counter = 0
      @search_mode = false
      @search_query = +""
      @search_matches = []
      @search_index = -1
      @search_regex_mode = false
      @search_case_insensitive = false
      @bell_flash = 0
      @marked_text = nil
      @current_event = nil
      @pane_divider_color = make_color(*Echoes.config.pane_divider_color)
      @active_pane_border_color = make_color(*Echoes.config.active_pane_border_color)
      @copy_mode_cursor_color = make_color(*Echoes.config.copy_mode_cursor_color)
      @window_states = []
      @view_to_ws = {}
    end

    def run
      setup_app
      create_fonts
      create_view_class
      open_new_window
      setup_timer
      start_app
    end

    def create_tab(editor_file: nil)
      cwd = self.class.pane_local_cwd(current_tab&.active_pane)
      tab = Tab.new(command: @command, rows: @rows, cols: @cols, cwd: cwd,
                    embedded: embedded_mode?, editor_file: editor_file)
      tab.title = editor_file ? File.basename(editor_file) : "Tab #{@tabs.size + 1}"
      tab.panes.each { |pane| wire_screen_handlers(pane) }
      @tabs << tab
      @active_tab = @tabs.size - 1
    end

    # Convert the active pane's OSC 7 `current_directory` URI into a local
    # filesystem path, or return nil if it isn't a usable local path
    # (missing, malformed, points at a remote host, or doesn't exist).
    def self.pane_local_cwd(pane)
      uri_str = pane&.screen&.current_directory
      cwd_from_osc7_uri(uri_str)
    end

    def self.cwd_from_osc7_uri(uri_str)
      return nil if uri_str.nil? || uri_str.empty?
      uri = URI.parse(uri_str) rescue nil
      return nil unless uri && uri.scheme == 'file'
      host = uri.host.to_s
      local_host = Socket.gethostname
      unless host.empty? || host == 'localhost' ||
             host == local_host || host == local_host.split('.').first
        return nil
      end
      path = URI.decode_www_form_component(uri.path) rescue nil
      path if path && !path.empty? && Dir.exist?(path)
    end

    def close_tab(index)
      return if index < 0 || index >= @tabs.size

      @tabs[index].close
      @tabs.delete_at(index)

      if @tabs.empty?
        close_current_window
        return
      end

      @active_tab = @active_tab.clamp(0, @tabs.size - 1)
    end

    def current_tab
      @tabs[@active_tab]
    end

    # Phase 1 launch flag for the in-process Rubish embedding. Setting
    # ECHOES_EMBED=1 in the environment routes new Tab/Pane creation
    # through Echoes::EmbeddedShell instead of PTY.spawn.
    def embedded_mode?
      ENV['ECHOES_EMBED'] == '1'
    end

    def activate_for_view(view_ptr)
      ws = @view_to_ws[view_ptr.to_i]
      return unless ws
      save_window_state
      load_window_state(ws)
    end

    private def save_window_state
      return unless @window
      ws = @view_to_ws[@view.to_i]
      return unless ws
      ws[:nswindow] = @window
      ws[:nsview] = @view
      ws[:tabs] = @tabs
      ws[:active_tab] = @active_tab
      ws[:search_mode] = @search_mode
      ws[:search_query] = @search_query
      ws[:search_matches] = @search_matches
      ws[:search_index] = @search_index
      ws[:bell_flash] = @bell_flash
      ws[:marked_text] = @marked_text
      ws[:current_event] = @current_event
      ws[:selection_anchor] = @selection_anchor
      ws[:selection_end] = @selection_end
      ws[:rows] = @rows
      ws[:cols] = @cols
      ws[:focused] = @window_focused
    end

    private def load_window_state(ws)
      @window = ws[:nswindow]
      @view = ws[:nsview]
      @tabs = ws[:tabs]
      @active_tab = ws[:active_tab]
      @search_mode = ws[:search_mode]
      @search_query = ws[:search_query]
      @search_matches = ws[:search_matches]
      @search_index = ws[:search_index]
      @bell_flash = ws[:bell_flash]
      @marked_text = ws[:marked_text]
      @current_event = ws[:current_event]
      @selection_anchor = ws[:selection_anchor]
      @selection_end = ws[:selection_end]
      @rows = ws[:rows]
      @cols = ws[:cols]
      @window_focused = ws.fetch(:focused, true)
    end

    private def close_current_window
      closing_view = @view
      ws = @view_to_ws[closing_view.to_i]
      @view_to_ws.delete(closing_view.to_i)
      @window_states.delete(ws)
      ObjC::MSG_VOID_1.call(@window, ObjC.sel('orderOut:'), Fiddle::Pointer.new(0))

      if @window_states.empty?
        ObjC::MSG_VOID_1.call(@app, ObjC.sel('terminate:'), Fiddle::Pointer.new(0))
        return
      end

      load_window_state(@window_states.last)

      # If the timer targeted the closed view, retarget it
      if @timer && closing_view.to_i == @timer_view_id
        ObjC::MSG_VOID.call(@timer, ObjC.sel('invalidate'))
        @timer_view_id = @view.to_i
        @timer = ObjC::MSG_PTR_D_P_P_P_I.call(
          ObjC.cls('NSTimer'),
          ObjC.sel('scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:'),
          1.0 / 60.0, @view, ObjC.sel('timerFired:'),
          Fiddle::Pointer.new(0), 1
        )
      end
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
      # Disable native NSWindow tabbing so Cmd+N always spawns a real
      # new window. Default macOS behavior in fullscreen is to fold
      # additional NSWindows into the same OS-level tabbed window —
      # but Echoes already has its own tab abstraction (with its own
      # tab bar and @tabs array per window), so that promotion creates
      # a phantom OS tab the Echoes side has no record of, leaving a
      # second clickable tab that switches to nothing.
      ObjC::MSG_VOID_I.call(ObjC.cls('NSWindow'), ObjC.sel('setAllowsAutomaticWindowTabbing:'), 0)
      setup_menu_bar
    end

    def setup_menu_bar
      main_menu = create_menu('')

      # Application menu
      app_menu = create_menu('Echoes')
      add_menu_item(app_menu, "About Echoes", 'showAbout:', '')
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
      add_menu_item(view_menu, "Bigger", 'increaseFontSize:', '=', bind: :increase_font_size)
      add_menu_item(view_menu, "Bigger", 'increaseFontSize:', '+', bind: :increase_font_size_plus)
      add_menu_item(view_menu, "Smaller", 'decreaseFontSize:', '-', bind: :decrease_font_size)
      add_menu_item(view_menu, "Reset Font Size", 'resetFontSize:', '0', bind: :reset_font_size)
      add_separator(view_menu)
      add_menu_item(view_menu, "Find", 'toggleFind:', 'f', bind: :toggle_find)
      add_menu_item(view_menu, "Find Next", 'findNext:', 'g', bind: :find_next)
      add_menu_item(view_menu, "Find Previous", 'findPrevious:', 'g',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                    bind: :find_previous)
      add_separator(view_menu)
      add_menu_item(view_menu, "Hide Mouse Pointer", 'togglePointer:', 'p',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                    bind: :toggle_pointer)
      build_profiles_submenu(view_menu)
      add_submenu(main_menu, view_menu, 'View')

      # Window menu
      window_menu = create_menu('Window')
      add_menu_item(window_menu, "Minimize", 'miniaturize:', 'm')
      add_menu_item(window_menu, "Zoom", 'zoom:', '')
      add_menu_item(window_menu, "Enter Full Screen", 'toggleFullScreen:', 'f',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagControl)
      add_separator(window_menu)
      add_menu_item(window_menu, "Show Previous Tab", 'showPreviousTab:', '{',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                    bind: :show_previous_tab)
      add_menu_item(window_menu, "Show Next Tab", 'showNextTab:', '}',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                    bind: :show_next_tab)
      add_separator(window_menu)
      add_menu_item(window_menu, "Select Next Pane", 'selectNextPane:', ']', bind: :select_next_pane)
      add_menu_item(window_menu, "Select Previous Pane", 'selectPreviousPane:', '[', bind: :select_previous_pane)
      add_separator(window_menu)
      add_menu_item(window_menu, "Toggle Copy Mode", 'toggleCopyMode:', 'c',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                    bind: :toggle_copy_mode)
      add_separator(window_menu)
      # Register the menu as NSApplication's "windows menu"; AppKit
      # auto-populates it with one item per NSWindow (using the window's
      # title) and handles activation when an item is selected.
      ObjC::MSG_VOID_1.call(@app, ObjC.sel('setWindowsMenu:'), window_menu)
      add_submenu(main_menu, window_menu, 'Window')

      # Shell menu
      shell_menu = create_menu('Shell')
      add_menu_item(shell_menu, "New Window", 'newWindow:', 'n', bind: :new_window)
      add_menu_item(shell_menu, "New Tab", 'newTab:', 't', bind: :new_tab)
      add_menu_item(shell_menu, "Close Tab", 'closeTab:', 'w', bind: :close_tab)
      add_separator(shell_menu)
      add_menu_item(shell_menu, "Edit File…", 'editFile:', 'e',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                    bind: :edit_file)
      add_separator(shell_menu)
      add_menu_item(shell_menu, "Split Right", 'splitRight:', 'd', bind: :split_right)
      add_menu_item(shell_menu, "Split Down", 'splitDown:', 'd',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                    bind: :split_down)
      add_menu_item(shell_menu, "Close Pane", 'closePane:', 'w',
                    modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                    bind: :close_pane)
      add_submenu(main_menu, shell_menu, 'Shell')

      ObjC::MSG_VOID_1.call(@app, ObjC.sel('setMainMenu:'), main_menu)
    end

    private def create_menu(title)
      m = ObjC::MSG_PTR.call(ObjC.cls('NSMenu'), ObjC.sel('alloc'))
      ObjC::MSG_PTR_1.call(m, ObjC.sel('initWithTitle:'), ObjC.nsstring(title))
    end

    private def add_menu_item(menu, title, selector, key, modifiers: ObjC::NSEventModifierFlagCommand, bind: nil)
      # When `bind:` is given, allow `~/.config/echoes/echoes.conf`
      # to override the default shortcut via `keybind "…", :sym`.
      # The override fully replaces both the key and the modifier
      # bits — an override of `""` (or `nil`) disables the
      # shortcut entirely (menu item stays, no keyboard binding).
      if bind && (over = Echoes.config.keybind_for(bind))
        key = over[:key].to_s
        modifiers = over[:modifiers]
      end

      item = ObjC::MSG_PTR.call(ObjC.cls('NSMenuItem'), ObjC.sel('alloc'))
      item = ObjC::MSG_PTR_3.call(item, ObjC.sel('initWithTitle:action:keyEquivalent:'),
        ObjC.nsstring(title), selector.empty? ? Fiddle::Pointer.new(0) : ObjC.sel(selector), ObjC.nsstring(key))
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

    # Generate `applyProfile_<i>:` selector entries — one per
    # declared profile — for the view-class selector dict. The
    # closures already exist in @profile_closures keyed by name;
    # this just gives them stable selector strings AppKit can
    # dispatch by index. `profile_selector_for` returns the matching
    # selector string for a given profile name so the menu builder
    # can wire the right one to each menu item.
    private def profile_selectors
      out = {}
      Echoes.config.all_profiles.each_key.with_index do |pname, i|
        out[profile_selector_for(pname)] = ['v@:@', @profile_closures[pname]]
      end
      out
    end

    private def profile_selector_for(name)
      i = Echoes.config.all_profiles.keys.index(name)
      "applyProfile_#{i}:"
    end

    # Add a "Profile" submenu to `view_menu` listing the synthesized
    # "Default" plus every user-declared profile. Always rendered so
    # the feature is discoverable even with an empty config.
    private def build_profiles_submenu(view_menu)
      profiles = Echoes.config.all_profiles
      return if profiles.empty?
      add_separator(view_menu)
      submenu = create_menu('Profile')
      profiles.each_key do |pname|
        add_menu_item(submenu, pname, profile_selector_for(pname), '')
      end
      add_submenu(view_menu, submenu, 'Profile')
    end

    private def add_submenu(parent, submenu, title)
      item = ObjC::MSG_PTR.call(ObjC.cls('NSMenuItem'), ObjC.sel('alloc'))
      item = ObjC::MSG_PTR_3.call(item, ObjC.sel('initWithTitle:action:keyEquivalent:'),
        ObjC.nsstring(title), Fiddle::Pointer.new(0), ObjC.nsstring(''))
      ObjC::MSG_VOID_1.call(item, ObjC.sel('setSubmenu:'), submenu)
      ObjC::MSG_VOID_1.call(parent, ObjC.sel('addItem:'), item)
    end

    def create_fonts
      @font = ObjC.retain(create_nsfont(@font_size))
      @bold_font = ObjC.retain(create_bold_nsfont(@font))
      @font_y_offset_cache = {}
      update_cell_metrics
    end

    def create_view_class
      gui = self

      @draw_rect_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
         Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE]
      ) do |_self, _cmd, x, y, w, h|
        gui.activate_for_view(_self); gui.draw_rect(y, y + h)
      rescue => e
        gui.log_crash(e, context: 'draw_rect')
      end

      @key_down_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.key_down(event)
      rescue => e
        gui.log_crash(e, context: 'key_down')
      end

      @accepts_fr_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_INT,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd| 1 }

      @timer_fired_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, _timer|
        gui.timer_fired
      rescue => e
        gui.log_crash(e, context: 'timer_fired')
      end

      @is_flipped_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_INT,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd| 1 }

      # AppKit calls this when it (re)builds cursor rects for the
      # view — on key-window changes, view-resize, and explicit
      # `[window invalidateCursorRectsForView:view]` calls. Register
      # an I-beam over the entire content area so the mouse cursor
      # turns into a text-selection bar when hovering over the grid.
      @reset_cursor_rects_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd|
        ibeam = ObjC::MSG_PTR.call(ObjC.cls('NSCursor'), ObjC.sel('IBeamCursor'))
        w = (@cell_width || 8.0)  * ((@cols || 80) + 1)
        h = (@cell_height || 16.0) * ((@rows || 24) + 1) + tab_bar_height
        ObjC::MSG_VOID_RECT_1.call(_self, ObjC.sel('addCursorRect:cursor:'),
                                   0.0, 0.0, w, h, ibeam)
      rescue => e
        gui.log_crash(e, context: 'resetCursorRects')
      end

      @scroll_wheel_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.scroll_wheel(event)
      rescue => e
        gui.log_crash(e, context: 'scroll_wheel')
      end

      @mouse_down_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.mouse_down(event)
      rescue => e
        gui.log_crash(e, context: 'mouse_down')
      end

      @mouse_dragged_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.mouse_dragged(event)
      rescue => e
        gui.log_crash(e, context: 'mouse_dragged')
      end

      @mouse_moved_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.mouse_moved(event)
      rescue => e
        gui.log_crash(e, context: 'mouse_moved')
      end

      @mouse_up_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.mouse_up(event)
      rescue => e
        gui.log_crash(e, context: 'mouse_up')
      end

      @right_mouse_down_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.right_mouse_down(event)
      rescue => e
        gui.log_crash(e, context: 'right_mouse_down')
      end

      @right_mouse_dragged_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.right_mouse_dragged(event)
      rescue => e
        gui.log_crash(e, context: 'right_mouse_dragged')
      end

      @right_mouse_up_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.right_mouse_up(event)
      rescue => e
        gui.log_crash(e, context: 'right_mouse_up')
      end

      @other_mouse_down_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.other_mouse_down(event)
      rescue => e
        gui.log_crash(e, context: 'other_mouse_down')
      end

      @other_mouse_dragged_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.other_mouse_dragged(event)
      rescue => e
        gui.log_crash(e, context: 'other_mouse_dragged')
      end

      @other_mouse_up_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, event|
        gui.activate_for_view(_self); gui.other_mouse_up(event)
      rescue => e
        gui.log_crash(e, context: 'other_mouse_up')
      end

      @perform_key_equiv_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_INT,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, event| gui.activate_for_view(_self); gui.perform_key_equivalent(event) }

      # Get NSView's original setFrameSize: IMP so we can call super
      nsview_cls = ObjC.cls('NSView')
      super_imp = ObjC::GetMethodImpl.call(nsview_cls, ObjC.sel('setFrameSize:'))
      @super_set_frame_size = Fiddle::Function.new(super_imp, [ObjC::P, ObjC::P, ObjC::D, ObjC::D], ObjC::V)

      @set_frame_size_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE]
      ) do |_self, _cmd, w, h|
        @super_set_frame_size.call(_self, _cmd, w, h)
        gui.activate_for_view(_self)
        gui.handle_resize(w, h)
      rescue => e
        gui.log_crash(e, context: 'set_frame_size')
      end

      # NSTextInputClient protocol closures for IME support
      @insert_text_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG]
      ) do |_self, _cmd, text, _rep_loc, _rep_len|
        gui.activate_for_view(_self); gui.ime_insert_text(text)
      rescue => e
        gui.log_crash(e, context: 'insert_text')
      end

      @insert_text_simple_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, text|
        gui.activate_for_view(_self); gui.ime_insert_text(text)
      rescue => e
        gui.log_crash(e, context: 'insert_text_simple')
      end

      @do_command_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, _selector|
        gui.activate_for_view(_self); gui.ime_do_command
      rescue => e
        gui.log_crash(e, context: 'do_command')
      end

      @set_marked_text_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
         Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG]
      ) do |_self, _cmd, text, sel_loc, sel_len, _rep_loc, _rep_len|
        gui.activate_for_view(_self); gui.ime_set_marked_text(text, sel_loc, sel_len)
      rescue => e
        gui.log_crash(e, context: 'set_marked_text')
      end

      @unmark_text_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd|
        gui.activate_for_view(_self); gui.ime_unmark_text
      rescue => e
        gui.log_crash(e, context: 'unmark_text')
      end

      @has_marked_text_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_INT,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd| gui.ime_has_marked_text }

      @marked_range_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_LONG,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd| gui.ime_marked_range_location }

      @selected_range_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_LONG,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd| 0x7FFFFFFFFFFFFFFF } # NSNotFound

      @valid_attrs_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOIDP,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd| ObjC::MSG_PTR.call(ObjC.cls('NSArray'), ObjC.sel('array')) }

      @attr_substring_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOIDP,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, _loc, _len, _actual| Fiddle::Pointer.new(0) }

      @first_rect_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_DOUBLE,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, _loc, _len, _actual| 0.0 }

      @char_index_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_LONG,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE]
      ) { |_self, _cmd, _x, _y| 0x7FFFFFFFFFFFFFFF } # NSNotFound

      menu_action = proc { |action_block|
        Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, _sender|
          gui.activate_for_view(_self); action_block.call
        rescue => e
          gui.log_crash(e, context: 'menu_action')
        end
      }

      @show_about_closure = menu_action.call(-> { show_about_panel })

      # One closure per declared profile, indexed by name. The
      # menu builder later wires each into its own
      # `applyProfile_<n>:` selector so AppKit can deliver the
      # right one without us having to dispatch by event payload.
      @profile_closures = {}
      Echoes.config.all_profiles.each_key do |pname|
        @profile_closures[pname] = menu_action.call(-> { apply_profile(pname) })
      end
      @new_window_closure = menu_action.call(-> { open_new_window })
      @new_tab_closure = menu_action.call(-> {
        create_tab
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @edit_file_closure = menu_action.call(-> {
        path = prompt_for_file_to_edit
        if path
          create_tab(editor_file: path)
          ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        end
      })
      @close_tab_closure = menu_action.call(-> {
        close_tab(@active_tab)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @copy_closure = menu_action.call(-> { copy_to_clipboard })
      @paste_closure = menu_action.call(-> { paste_from_clipboard })
      @select_all_closure = menu_action.call(-> { select_all })
      @increase_font_closure = menu_action.call(-> { update_font(@font_size + 1.0) })
      @decrease_font_closure = menu_action.call(-> { update_font(@font_size - 1.0) if @font_size > 4.0 })
      @reset_font_closure = menu_action.call(-> {
        Preferences.delete(:font_size)
        update_font(Echoes.config.font_size, persist: false)
      })
      @toggle_find_closure = menu_action.call(-> {
        toggle_search
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @find_next_closure = menu_action.call(-> {
        if @search_mode && !@search_matches.empty?
          search_next
          ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        end
      })
      @find_prev_closure = menu_action.call(-> {
        if @search_mode && !@search_matches.empty?
          search_prev
          ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        end
      })
      @prev_tab_closure = menu_action.call(-> {
        @active_tab = (@active_tab - 1) % @tabs.size
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @next_tab_closure = menu_action.call(-> {
        @active_tab = (@active_tab + 1) % @tabs.size
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @split_right_closure = menu_action.call(-> {
        tab = current_tab
        new_pane = tab.split_vertical
        wire_screen_handlers(new_pane)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @split_down_closure = menu_action.call(-> {
        tab = current_tab
        new_pane = tab.split_horizontal
        wire_screen_handlers(new_pane)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @close_pane_closure = menu_action.call(-> {
        tab = current_tab
        if tab.pane_tree.single_pane?
          close_tab(@active_tab)
        else
          tab.close_active_pane
        end
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @select_next_pane_closure = menu_action.call(-> {
        current_tab.next_pane
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      @select_prev_pane_closure = menu_action.call(-> {
        current_tab.prev_pane
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })
      # NSMenu items dispatched from the tab-completion popup. Unlike the
      # main-menu actions, the completion picker needs the sender so we
      # can read its tag (= candidate index); menu_action's no-arg
      # convention isn't a fit, so wire it manually.
      @completion_picked_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, sender|
        gui.activate_for_view(_self); gui.completion_picked(sender)
      rescue => e
        gui.log_crash(e, context: 'completionPicked')
      end

      @toggle_pointer_closure = menu_action.call(-> {
        # NSCursor's hide/unhide are reference-counted; track state so
        # repeated invocations toggle cleanly. We don't use
        # `setHiddenUntilMouseMoves:` because the user wants explicit
        # control (mouse-move shouldn't undo a deliberate hide).
        if @pointer_hidden
          ObjC::MSG_VOID.call(ObjC.cls('NSCursor'), ObjC.sel('unhide'))
          @pointer_hidden = false
        else
          ObjC::MSG_VOID.call(ObjC.cls('NSCursor'), ObjC.sel('hide'))
          @pointer_hidden = true
        end
      })

      @toggle_copy_mode_closure = menu_action.call(-> {
        pane = current_tab.active_pane
        if pane.copy_mode&.active
          pane.copy_mode.exit
          pane.copy_mode = nil
        else
          pane.copy_mode = CopyMode.new(pane.screen)
          pane.copy_mode.enter
        end
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      })

      @dragging_entered_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_LONG,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, _sender| 1 }  # NSDragOperationCopy

      @perform_drag_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_INT,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |_self, _cmd, sender|
        gui.activate_for_view(_self); gui.perform_drag_operation(sender) ? 1 : 0
      rescue => e
        gui.log_crash(e, context: 'performDragOperation')
        0
      end

      @focus_gained_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, _notification| gui.activate_for_view(_self); gui.window_focus_changed(true) }

      @focus_lost_closure = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID,
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) { |_self, _cmd, _notification| gui.activate_for_view(_self); gui.window_focus_changed(false) }

      @view_class = ObjC.define_class('EchoesTerminalView', 'NSView', {
        'drawRect:'             => ['v@:{CGRect=dddd}', @draw_rect_closure],
        'keyDown:'              => ['v@:@', @key_down_closure],
        'acceptsFirstResponder' => ['c@:', @accepts_fr_closure],
        'timerFired:'           => ['v@:@', @timer_fired_closure],
        'isFlipped'             => ['c@:', @is_flipped_closure],
        'resetCursorRects'      => ['v@:', @reset_cursor_rects_closure],
        'scrollWheel:'          => ['v@:@', @scroll_wheel_closure],
        'mouseDown:'            => ['v@:@', @mouse_down_closure],
        'mouseDragged:'         => ['v@:@', @mouse_dragged_closure],
        'mouseMoved:'           => ['v@:@', @mouse_moved_closure],
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
        'showAbout:'             => ['v@:@', @show_about_closure],
        **profile_selectors,
        'newWindow:'             => ['v@:@', @new_window_closure],
        'newTab:'               => ['v@:@', @new_tab_closure],
        'editFile:'             => ['v@:@', @edit_file_closure],
        'closeTab:'             => ['v@:@', @close_tab_closure],
        'copy:'                 => ['v@:@', @copy_closure],
        'paste:'                => ['v@:@', @paste_closure],
        'selectAll:'            => ['v@:@', @select_all_closure],
        'increaseFontSize:'     => ['v@:@', @increase_font_closure],
        'decreaseFontSize:'     => ['v@:@', @decrease_font_closure],
        'resetFontSize:'        => ['v@:@', @reset_font_closure],
        'toggleFind:'           => ['v@:@', @toggle_find_closure],
        'findNext:'             => ['v@:@', @find_next_closure],
        'findPrevious:'         => ['v@:@', @find_prev_closure],
        'showPreviousTab:'      => ['v@:@', @prev_tab_closure],
        'showNextTab:'          => ['v@:@', @next_tab_closure],
        'splitRight:'           => ['v@:@', @split_right_closure],
        'splitDown:'            => ['v@:@', @split_down_closure],
        'closePane:'            => ['v@:@', @close_pane_closure],
        'selectNextPane:'       => ['v@:@', @select_next_pane_closure],
        'selectPreviousPane:'   => ['v@:@', @select_prev_pane_closure],
        'toggleCopyMode:'       => ['v@:@', @toggle_copy_mode_closure],
        'togglePointer:'        => ['v@:@', @toggle_pointer_closure],
        'completionPicked:'     => ['v@:@', @completion_picked_closure],
        # NSTextInputClient protocol methods for IME
        'insertText:replacementRange:'                      => ['v@:@{_NSRange=QQ}', @insert_text_closure],
        'insertText:'                                       => ['v@:@', @insert_text_simple_closure],
        'doCommandBySelector:'                              => ['v@::', @do_command_closure],
        'setMarkedText:selectedRange:replacementRange:'     => ['v@:@{_NSRange=QQ}{_NSRange=QQ}', @set_marked_text_closure],
        'unmarkText'                                        => ['v@:', @unmark_text_closure],
        'hasMarkedText'                                     => ['c@:', @has_marked_text_closure],
        'markedRange'                                       => ['{_NSRange=QQ}@:', @marked_range_closure],
        'selectedRange'                                     => ['{_NSRange=QQ}@:', @selected_range_closure],
        'validAttributesForMarkedText'                      => ['@@:', @valid_attrs_closure],
        'attributedSubstringForProposedRange:actualRange:'  => ['@@:{_NSRange=QQ}^{_NSRange=QQ}', @attr_substring_closure],
        'firstRectForCharacterRange:actualRange:'           => ['{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}', @first_rect_closure],
        'characterIndexForPoint:'                           => ['Q@:{CGPoint=dd}', @char_index_closure],
        'draggingEntered:'                                  => ['Q@:@', @dragging_entered_closure],
        'performDragOperation:'                             => ['c@:@', @perform_drag_closure],
      })

      # Add NSTextInputClient protocol conformance for IME
      protocol = ObjC::GetProtocol.call('NSTextInputClient')
      ObjC::AddProtocol.call(@view_class, protocol) unless protocol.null?
    end

    def setup_timer
      @timer_view_id = @view.to_i
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
      unless tab
        ObjC::MSG_VOID.call(pool, ObjC.sel('drain'))
        return
      end
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

      # Draw all panes
      pane_rects = tab.pane_tree.layout(0, 0, @cols, @rows)
      pane_rects.each do |rect|
        pane = rect[:pane]
        px = rect[:x] * @cell_width
        py = gy_off + rect[:y] * @cell_height
        is_active = (pane == tab.active_pane)

        draw_pane_content(pane, px, py, dirty_min_y, dirty_max_y, is_active)
      end

      # Draw pane dividers and active pane border
      if !tab.pane_tree.single_pane?
        draw_pane_dividers(pane_rects, gy_off)
        draw_active_pane_border(tab, pane_rects, gy_off)
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
        mode_flags = []
        mode_flags << 'regex' if @search_regex_mode
        mode_flags << 'i'     if @search_case_insensitive
        mode_tag = mode_flags.empty? ? '' : " (#{mode_flags.join(', ')})"
        label = "Find#{mode_tag}: #{@search_query}_#{match_info}"
        ns_str = ObjC.nsstring(label)
        ns_attrs = ObjC.nsdict({
          ObjC::NSFontAttributeName => @font,
          ObjC::NSForegroundColorAttributeName => make_color(1.0, 1.0, 1.0),
        })
        ObjC::MSG_VOID_PT_1.call(ns_str, ObjC.sel('drawAtPoint:withAttributes:'), 4.0, bar_y + 2.0, ns_attrs)
      end

      ObjC::MSG_VOID.call(pool, ObjC.sel('drain'))
    end

    def draw_pane_content(pane, px, py, dirty_min_y, dirty_max_y, is_active)
      screen = pane.screen
      scrollback = screen.scrollback
      visible_start = scrollback.size - pane.scroll_offset
      pane_rows = screen.rows
      pane_cols = screen.cols

      copy_mode = pane.copy_mode

      # Per-pane gradient background (set via OSC 7772 ;bg-gradient).
      # Drawn before any cells so cell-level bg colors paint on top.
      draw_pane_background(screen.background, px, py, pane_cols, pane_rows) if screen.background
      draw_pane_fills(screen.bg_fills, px, py, pane_cols, pane_rows) if screen.bg_fills && !screen.bg_fills.empty?

      pane_rows.times do |r|
        y = py + r * @cell_height
        next if y + @cell_height < dirty_min_y || y > dirty_max_y
        src = visible_start + r
        row = if src < scrollback.size
                scrollback[src]
              elsif src - scrollback.size < screen.grid.size
                screen.grid[src - scrollback.size]
              end
        next unless row

        # Text-run accumulator. We batch consecutive cells with
        # matching style into one drawAtPoint call so the font
        # shaper sees adjacent characters and can apply ligatures
        # (`=>`, `!=`, `<=`, etc.) on fonts that have them.
        # Anything that can't extend the run (multicell, blank
        # non-bg cell, style change) flushes it first.
        run_chars   = +''
        run_start_c = nil
        run_attrs   = nil
        run_font    = nil
        run_sig     = nil
        flush_run = lambda do
          next if run_chars.empty?
          ns_run = ObjC.nsstring(run_chars)
          run_x  = px + run_start_c * @cell_width
          run_dy = y + y_offset_for_font(run_font)
          ObjC::MSG_VOID_PT_1.call(ns_run, ObjC.sel('drawAtPoint:withAttributes:'),
                                   run_x, run_dy, run_attrs)
          run_chars   = +''
          run_start_c = nil
          run_attrs   = nil
          run_font    = nil
          run_sig     = nil
        end

        row.each_with_index do |cell, c|
          if cell.width == 0 || cell.multicell == :cont
            flush_run.call
            next
          end

          fg_val = cell.fg
          bg_val = cell.bg
          default_fg = @default_fg
          default_bg = @default_bg
          if cell.inverse
            fg_val, bg_val = bg_val, fg_val
            default_fg, default_bg = default_bg, default_fg
          end

          fg_color = resolve_color(fg_val, default_fg)
          bg_color = resolve_color(bg_val, default_bg)

          if cell.bold && fg_val.is_a?(Integer) && fg_val < 8
            fg_color = @colors[fg_val + 8]
          end

          has_bg = !bg_val.nil? || cell.inverse

          selected = is_active && cell_selected?(src, c)
          is_match = is_active && @search_mode && search_match_at?(src, c)
          is_current_match = is_active && @search_mode && current_search_match_at?(src, c)

          # Copy mode selection highlight
          if copy_mode&.active && copy_mode.selecting?
            sel_start, sel_end = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
            cm_abs_row = scrollback.size + r - pane.scroll_offset
            if cm_abs_row >= scrollback.size + sel_start[0] && cm_abs_row <= scrollback.size + sel_end[0]
              cm_row = cm_abs_row - scrollback.size
              if cm_row == sel_start[0] && cm_row == sel_end[0]
                selected = c >= sel_start[1] && c <= sel_end[1]
              elsif cm_row == sel_start[0]
                selected = c >= sel_start[1]
              elsif cm_row == sel_end[0]
                selected = c <= sel_end[1]
              else
                selected = true
              end
            end
          end

          if cell.multicell.is_a?(Hash)
            flush_run.call
            mc = cell.multicell
            x = px + c * @cell_width
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

            # Per OSC 66 spec, n=/d= define a fraction *of* the scale.
            # Effective glyph size is `s × n/d`. The reserved block
            # stays at the full s×s*width — n=/d= shrink (or grow) the
            # glyph within that block, paired with v=/h= for placement.
            # Example: `s=2:n=1:d=2:v=2;●` reserves 2×2 cells and draws
            # a 1-cell ● centered vertically inside it.
            effective_scale = mc[:scale].to_f
            if mc[:frac_d] > 0 && mc[:frac_n] > 0
              effective_scale *= mc[:frac_n].to_f / mc[:frac_d]
            end
            scaled_font = ObjC.retain(create_nsfont(@font_size * effective_scale, family: mc[:family]))
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
            if cell.strikethrough
              draw_attrs[ObjC::NSStrikethroughStyleAttributeName] = ObjC.nsnumber_int(1)
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
            x = px + c * @cell_width
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

            if cell.char == " " && !has_bg && !selected && !is_match
              flush_run.call
              next
            end

            base_font = cell.bold ? @bold_font : font_for_char(cell.char)
            if cell.italic
              base_font = create_italic_nsfont(base_font)
            end
            if cell.concealed || (cell.blink && !@cursor_blink_on)
              fg_color = bg_color
            elsif cell.faint
              fg_color = make_color_with_alpha(fg_color, 0.5)
            end

            sig = [base_font.to_i, fg_color.to_i, cell.underline, cell.strikethrough]
            if run_sig != sig
              flush_run.call
              run_sig     = sig
              run_start_c = c
              run_font    = base_font
              attrs = {
                ObjC::NSFontAttributeName            => base_font,
                ObjC::NSForegroundColorAttributeName => fg_color,
                # Ligature value `2` requests all discretionary
                # ligatures (`=>`, `!=`, `<=`, `>=`, etc.) on
                # fonts like Fira Code that ship them; default
                # `0` only does fi/fl-style essential ones.
                ObjC::NSLigatureAttributeName        => ObjC.nsnumber_int(2),
              }
              attrs[ObjC::NSUnderlineStyleAttributeName]     = ObjC.nsnumber_int(1) if cell.underline
              attrs[ObjC::NSStrikethroughStyleAttributeName] = ObjC.nsnumber_int(1) if cell.strikethrough
              run_attrs = ObjC.nsdict(attrs)
            end
            run_chars << cell.char
          end
        end
        flush_run.call
      end

      # Draw cursor or copy mode cursor
      if copy_mode&.active
        # Copy mode cursor (inverse block)
        cm_row = copy_mode.cursor_row
        if cm_row >= 0 && cm_row < pane_rows
          cx = px + copy_mode.cursor_col * @cell_width
          cy = py + cm_row * @cell_height
          ObjC::MSG_VOID.call(@copy_mode_cursor_color, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(cx, cy, @cell_width, @cell_height)
        end
      elsif pane.scroll_offset == 0 && screen.cursor.visible
        style = screen.cursor_style
        blink = style.odd? || style == 0
        cx = px + screen.cursor.col * @cell_width
        cy = py + screen.cursor.row * @cell_height

        if @window_focused
          # Active window: filled cursor (blinking if requested)
          if !blink || (is_active ? @cursor_blink_on : true)
            cursor_color = is_active ? make_color(*@active_profile.cursor_color) : make_color(0.5, 0.5, 0.5, 0.3)
            ObjC::MSG_VOID.call(cursor_color, ObjC.sel('setFill'))
            case style
            when 3, 4 # underline
              ObjC::NSRectFill.call(cx, cy + @cell_height - 2.0, @cell_width, 2.0)
            when 5, 6 # bar
              ObjC::NSRectFill.call(cx, cy, 2.0, @cell_height)
            else # block (0, 1, 2)
              ObjC::NSRectFill.call(cx, cy, @cell_width, @cell_height)
              # Draw character under cursor with inverted colors
              if screen.cursor.row < pane_rows && screen.cursor.col < pane_cols
                cell = screen.grid[screen.cursor.row][screen.cursor.col]
                if cell.char != ' '
                  inv_fg = @default_bg
                  cursor_font = cell.bold ? @bold_font : font_for_char(cell.char)
                  ns_attrs = ObjC.nsdict({
                    ObjC::NSFontAttributeName => cursor_font,
                    ObjC::NSForegroundColorAttributeName => inv_fg,
                  })
                  ns_char = cached_nsstring(cell.char)
                  dy = cy + y_offset_for_font(cursor_font)
                  ObjC::MSG_VOID_PT_1.call(ns_char, ObjC.sel('drawAtPoint:withAttributes:'), cx, dy, ns_attrs)
                end
              end
            end
          end
        else
          # Inactive window: hollow square outline (no blinking)
          ObjC::MSG_VOID.call(make_color(*@active_profile.cursor_color), ObjC.sel('setFill'))
          ObjC::NSRectFill.call(cx, cy, @cell_width, 1.0)                       # top
          ObjC::NSRectFill.call(cx, cy + @cell_height - 1.0, @cell_width, 1.0)  # bottom
          ObjC::NSRectFill.call(cx, cy, 1.0, @cell_height)                      # left
          ObjC::NSRectFill.call(cx + @cell_width - 1.0, cy, 1.0, @cell_height)  # right
        end
      end

      # Draw marked text (IME composition) at cursor position (active pane only)
      if is_active && @marked_text && pane.scroll_offset == 0
        mx = px + screen.cursor.col * @cell_width
        my = py + screen.cursor.row * @cell_height
        marked_width = @marked_text.each_char.sum { |c| c.ord > 0x7F ? @cell_width * 2 : @cell_width }

        ime_bg = make_color(0.2, 0.2, 0.35)
        ObjC::MSG_VOID.call(ime_bg, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(mx, my, marked_width, @cell_height)

        ns_str = ObjC.nsstring(@marked_text)
        ns_attrs = ObjC.nsdict({
          ObjC::NSFontAttributeName => @font,
          ObjC::NSForegroundColorAttributeName => make_color(1.0, 1.0, 1.0),
          ObjC::NSUnderlineStyleAttributeName => ObjC.nsnumber_int(1),
        })
        ObjC::MSG_VOID_PT_1.call(ns_str, ObjC.sel('drawAtPoint:withAttributes:'), mx, my, ns_attrs)
      end
    end

    def draw_pane_dividers(pane_rects, gy_off)
      return if pane_rects.size <= 1

      ObjC::MSG_VOID.call(@pane_divider_color, ObjC.sel('setFill'))

      pane_rects.each do |rect|
        px = rect[:x] * @cell_width
        py = gy_off + rect[:y] * @cell_height
        pw = rect[:w] * @cell_width
        ph = rect[:h] * @cell_height

        # Draw right edge divider (if not at the far right)
        if rect[:x] + rect[:w] < @cols
          ObjC::NSRectFill.call(px + pw - 0.5, py, 1.0, ph)
        end

        # Draw bottom edge divider (if not at the very bottom)
        if rect[:y] + rect[:h] < @rows
          ObjC::NSRectFill.call(px, py + ph - 0.5, pw, 1.0)
        end
      end
    end

    def draw_active_pane_border(tab, pane_rects, gy_off)
      active_rect = pane_rects.find { |r| r[:pane] == tab.active_pane }
      return unless active_rect

      ObjC::MSG_VOID.call(@active_pane_border_color, ObjC.sel('setFill'))

      px = active_rect[:x] * @cell_width
      py = gy_off + active_rect[:y] * @cell_height
      pw = active_rect[:w] * @cell_width
      ph = active_rect[:h] * @cell_height

      # Top border
      ObjC::NSRectFill.call(px, py, pw, 2.0)
      # Bottom border
      ObjC::NSRectFill.call(px, py + ph - 2.0, pw, 2.0)
      # Left border
      ObjC::NSRectFill.call(px, py, 2.0, ph)
      # Right border
      ObjC::NSRectFill.call(px + pw - 2.0, py, 2.0, ph)
    end

    def perform_key_equivalent(event_ptr)
      0
    end

    def key_down(event_ptr)
      if @search_mode
        search_key_down(event_ptr)
        return
      end

      tab = current_tab
      return unless tab
      pane = tab.active_pane
      return unless pane

      # Copy mode intercepts all keys
      if pane.copy_mode&.active
        copy_mode_key_down(event_ptr, pane)
        return
      end

      @selection_anchor = nil
      @selection_end = nil
      @selection_word_anchor = nil

      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))
      chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('charactersIgnoringModifiers'))
      chars = ObjC.to_ruby_string(chars_ns)
      return if chars.empty?

      # Snap-to-bottom on most key events. Exception: Cmd+Shift+Up/Down
      # is the OSC 133 jump-to-prompt nav, which sets @scroll_offset
      # itself — clobbering it here would defeat repeated presses.
      is_prompt_nav = (flags & (ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift)) ==
                      (ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift) &&
                      (chars == "\u{F700}" || chars == "\u{F701}")
      unless is_prompt_nav
        pane.scroll_offset = 0
        pane.scroll_accum = 0.0
      end

      # Viewer panes (rvim-backed) consume keys directly via
      # `pane.handle_key`, not via a pty. Without this branch the
      # legacy PTY path below tries to write keystrokes to a
      # non-existent pty fd, so vim never sees the input.
      if pane.editor?
        pane.handle_key(chars: chars, flags: flags)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        return
      end

      # Embedded-shell panes don't speak the byte-stream / escape-code
      # protocol; they have an in-Echoes line editor that submits
      # finished lines to a Rubish::REPL via direct method calls.
      if pane.embedded?
        # Tab with multiple completion candidates: show a native NSMenu
        # popup at the cursor cell instead of letting Pane print the
        # candidates inline. Single-candidate completion stays inline.
        if chars == "\t" && !pane.embedded_shell.running?
          req = pane.completion_request
          if req && req[:candidates].size > 1
            show_completion_popup(pane, req)
            ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
            return
          end
        end
        pane.handle_key(chars: chars, flags: flags)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        return
      end

      mod = modifier_param(flags)

      if chars == "\u{19}"  # NSBackTabCharacter (Shift+Tab on macOS)
        pane.write_input("\e[Z")
      elsif mod > 1 && (seq = map_modified_key(chars, mod))
        pane.write_input(seq)
      elsif (flags & ObjC::NSEventModifierFlagControl) != 0
        ctrl_char = (chars[0].ord & 0x1F).chr
        pane.write_input(ctrl_char)
      elsif (flags & ObjC::NSEventModifierFlagOption) != 0
        pane.write_input("\e#{chars}")
      else
        # Route through input method for IME support
        @current_event = event_ptr
        arr = ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'), event_ptr)
        ObjC::MSG_VOID_1.call(@view, ObjC.sel('interpretKeyEvents:'), arr)
      end
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def copy_mode_key_down(event_ptr, pane)
      chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('characters'))
      chars = ObjC.to_ruby_string(chars_ns)
      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))

      key = if (flags & ObjC::NSEventModifierFlagControl) != 0
              (chars[0].ord & 0x1F).chr
            else
              chars
            end

      result = pane.copy_mode.handle_key(key)
      case result
      when :exit
        pane.copy_mode = nil
      when :yank
        text = pane.copy_mode.selected_text
        unless text.empty?
          pb = ObjC::MSG_PTR.call(ObjC.cls('NSPasteboard'), ObjC.sel('generalPasteboard'))
          ObjC::MSG_PTR.call(pb, ObjC.sel('clearContents'))
          ObjC::MSG_PTR_2.call(pb, ObjC.sel('setString:forType:'), ObjC.nsstring(text), ObjC::NSPasteboardTypeString)
        end
        pane.copy_mode.exit
        pane.copy_mode = nil
      end
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    # --- IME (Input Method Editor) callbacks ---

    def ime_insert_text(text_ptr)
      text = nsstring_from_input(text_ptr)
      @marked_text = nil
      return if text.empty?

      tab = current_tab
      return unless tab
      pane = tab.active_pane
      return unless pane
      pane.write_input(text)
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def ime_do_command
      return unless @current_event

      tab = current_tab
      return unless tab
      pane = tab.active_pane
      return unless pane
      event_ptr = @current_event
      flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))
      chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('characters'))
      chars = ObjC.to_ruby_string(chars_ns)
      chars_ns2 = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('charactersIgnoringModifiers'))
      chars2 = ObjC.to_ruby_string(chars_ns2)

      numpad = (flags & ObjC::NSEventModifierFlagNumericPad) != 0
      actual = chars.empty? ? chars2 : chars
      pane.write_input(map_special_keys(actual, pane.screen.application_cursor_keys?, app_keypad: numpad && pane.screen.application_keypad))
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def ime_set_marked_text(text_ptr, _sel_loc, _sel_len)
      text = nsstring_from_input(text_ptr)

      if text.empty?
        @marked_text = nil
      else
        @marked_text = text
      end

      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    def ime_unmark_text
      @marked_text = nil
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    def ime_has_marked_text
      @marked_text ? 1 : 0
    end

    def ime_marked_range_location
      @marked_text ? 0 : 0x7FFFFFFFFFFFFFFF # NSNotFound
    end

    def timer_fired
      save_window_state

      @cursor_blink_counter += 1
      blink_toggled = false
      if @cursor_blink_counter >= 30
        @cursor_blink_counter = 0
        @cursor_blink_on = !@cursor_blink_on
        blink_toggled = true
      end

      @window_states.each do |ws|
        load_window_state(ws)
        timer_fired_for_window(ws, blink_toggled)
      end
    end

    private def timer_fired_for_window(ws, blink_toggled)
      need_redraw = false

      @tabs.each do |tab|
        tab.panes.each do |pane|
          loop do
            data = pane.read_available_output(16384)
            break if data.empty?
            pane.process_output(data)
            need_redraw = true
          end
          if need_redraw && pane.screen.title
            tab.title = pane.screen.title if pane == tab.active_pane
            pane.screen.title = nil
          end
        end

        # Clean up dead panes within the tab
        dead_panes = tab.panes.reject(&:alive?)
        dead_panes.each do |dp|
          next if tab.pane_tree.single_pane?
          tab.pane_tree.remove(dp)
          dp.close
          need_redraw = true
        end
      end

      # Clean up dead tabs (all panes dead)
      dead = @tabs.reject(&:alive?)
      if dead.any?
        dead.each { |t| t.close }
        @tabs -= dead
        if @tabs.empty?
          save_window_state
          close_current_window
          return
        end
        @active_tab = @active_tab.clamp(0, @tabs.size - 1)
        need_redraw = true
      end

      tab = current_tab
      return unless tab

      # Check bell on active pane
      active_pane = tab.active_pane
      if active_pane&.screen&.bell
        active_pane.screen.bell = false
        @bell_flash = 3
        need_redraw = true
      elsif @bell_flash > 0
        @bell_flash -= 1
        need_redraw = true
      end

      need_redraw = true if blink_toggled

      full_redraw = @bell_flash > 0 || blink_toggled

      # DEC private mode 2026 (synchronized output): when a TUI has
      # opened a sync window with `\e[?2026h`, hold the redraw — even
      # though we've already mutated the cell grid — until the
      # matching `\e[?2026l` arrives. This makes vim/bat/helix bulk
      # repaints land as a single visual frame instead of tearing
      # mid-batch. Dirty rows accumulate across sync ticks; when sync
      # ends, the next tick paints them all at once.
      if tab.panes.any? { |p| p.screen.sync_active }
        save_window_state
        return
      end

      if need_redraw
        ObjC::MSG_VOID_1.call(@window, ObjC.sel('setTitle:'), ObjC.nsstring(tab.title))

        if full_redraw || dead&.any? || !tab.pane_tree.single_pane?
          tab.panes.each { |p| p.screen.clear_dirty }
          ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        else
          # Single pane optimization: collect dirty rows before clearing
          screen = active_pane.screen
          dirty = screen.dirty_rows
          screen.clear_dirty
          dirty << screen.cursor.row
          invalidate_dirty_rows(dirty)
        end
      elsif full_redraw
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      save_window_state
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
      return unless tab
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
      return unless tab
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
        # Cmd+click: open hyperlink/URL if the cell has one; otherwise
        # in an embedded pane, recall the command at this prompt row
        # into the input buffer (using OSC 133 marks as the index).
        abs_row, col = pos
        url = hyperlink_at(tab, abs_row, col)
        if url
          open_url(url)
        else
          pane = tab.active_pane
          if pane.embedded?
            mark = pane.screen.find_command_mark_at_row(abs_row)
            if mark && mark[:command_text] && !pane.embedded_shell.running?
              pane.recall_command(mark[:command_text])
            end
          end
        end
      elsif tab.screen.mouse_tracking != :off
        row, col = pos
        send_mouse_event(tab, 0, col, row)  # button 0 = left press
      elsif click_count >= 3
        # Triple-click: if the clicked row falls inside a command's
        # OSC 133 output region, select the whole region (semantic
        # copy). Otherwise fall back to selecting just this one line.
        abs_row, = pos
        region = tab.active_pane&.screen&.output_region_for_row(abs_row)
        if region
          start_row, end_row = region
          @selection_anchor = [start_row, 0]
          @selection_end    = [end_row, @cols - 1]
        else
          @selection_anchor = [abs_row, 0]
          @selection_end    = [abs_row, @cols - 1]
        end
        @selection_word_anchor = nil
      elsif click_count == 2
        # Double-click: select word, and remember the word's bounds so
        # a subsequent drag extends from those bounds (keeping the
        # double-clicked word fully selected) instead of collapsing
        # to character-level from the click point.
        abs_row, col = pos
        row_data = row_at(tab, abs_row)
        if row_data
          bounds = word_boundaries_in_row(row_data, col)
          if bounds
            @selection_anchor = [abs_row, bounds[0]]
            @selection_end = [abs_row, bounds[1]]
            @selection_word_anchor = [abs_row, bounds[0], bounds[1]]
          end
        end
      else
        # Single click: start drag selection
        @selection_anchor = pos
        @selection_end = nil
        @selection_word_anchor = nil
      end

      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    def mouse_dragged(event_ptr)
      tab = current_tab
      return unless tab
      pos = grid_position(event_ptr)
      return unless pos

      if tab.screen.mouse_tracking == :button_event || tab.screen.mouse_tracking == :any_event
        row, col = pos
        send_mouse_event(tab, 32, col, row)  # 32 = left drag (button 0 + 32)
      elsif @selection_word_anchor
        extend_word_drag_selection(tab, pos)
      else
        @selection_end = pos
      end
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    end

    # When dragging after a double-click, snap each end of the
    # selection to whole-word boundaries — and never let it shrink
    # below the originally double-clicked word. Selection start is
    # min((anchor_word_start), (pointer's word_start)); end is
    # max((anchor_word_end), (pointer's word_end)). If the pointer
    # is sitting on whitespace the "word" at the pointer is just
    # that single cell, so the leading edge extends one char at a
    # time across gaps.
    def extend_word_drag_selection(tab, pointer_pos)
      a_row, a_start, a_end = @selection_word_anchor
      p_row, p_col = pointer_pos
      p_row_data = row_at(tab, p_row)
      p_bounds = p_row_data && word_boundaries_in_row(p_row_data, p_col)
      p_start = p_bounds ? p_bounds[0] : p_col
      p_end   = p_bounds ? p_bounds[1] : p_col

      sel_start =
        if p_row < a_row || (p_row == a_row && p_start < a_start)
          [p_row, p_start]
        else
          [a_row, a_start]
        end
      sel_end =
        if p_row > a_row || (p_row == a_row && p_end > a_end)
          [p_row, p_end]
        else
          [a_row, a_end]
        end
      @selection_anchor = sel_start
      @selection_end    = sel_end
    end

    def mouse_up(event_ptr)
      tab = current_tab
      return unless tab
      return if tab.screen.mouse_tracking == :off || tab.screen.mouse_tracking == :x10

      pos = grid_position(event_ptr)
      return unless pos
      row, col = pos
      send_mouse_event(tab, 3, col, row, release: true)  # 3 = release
    end

    # Pointer-was-hidden + user-shakes-the-mouse path: when the user
    # has hidden the cursor (Cmd+Shift+P) and then can't find it, the
    # OS's own "shake to locate" feature briefly enlarges the system
    # cursor — but ours is hidden, so there's nothing to enlarge. We
    # detect the shake ourselves and unhide so the user gets a
    # cursor to look at. After this fires, @pointer_hidden is reset
    # so re-hiding requires another deliberate Cmd+Shift+P.
    def mouse_moved(event_ptr)
      return unless @pointer_hidden
      @shake_detector ||= ShakeDetector.new
      x, y = event_location(event_ptr)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @shake_detector.observe(t, x, y)
        ObjC::MSG_VOID.call(ObjC.cls('NSCursor'), ObjC.sel('unhide'))
        @pointer_hidden = false
        @shake_detector.reset
      end
    end

    def right_mouse_down(event_ptr)
      tab = current_tab
      return unless tab
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
      return unless tab
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
      return unless tab
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
      return unless tab
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
      return unless tab
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
      return unless tab
      return if tab.screen.mouse_tracking == :off || tab.screen.mouse_tracking == :x10

      pos = grid_position(event_ptr)
      return unless pos
      row, col = pos
      send_mouse_event(tab, 3, col, row, release: true)
    rescue Errno::EIO, IOError
      close_tab(@active_tab)
    end

    def handle_resize(w, h)
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
      @window_focused = focused
      save_window_state
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1) if @view

      tab = current_tab
      pane = tab&.active_pane
      return unless pane&.screen&.focus_reporting?

      seq = focused ? "\e[I" : "\e[O"
      pane.write_input(seq)
    end

    # Switch the active profile (color theme) by name. Releases the
    # current NSColor cache, rebuilds default fg/bg/selection and
    # the 256-color palette from the new profile, and triggers a
    # full repaint so every existing cell picks up the new colors.
    # Per-pane gradient overlays (OSC 7772 bg-* commands) are left
    # alone — those are user-driven decoration, not theme.
    def apply_profile(name)
      profile = Echoes.config.all_profiles[name.to_s]
      return unless profile
      @active_profile = profile

      ObjC.release(@default_fg)        if @default_fg
      ObjC.release(@default_bg)        if @default_bg
      ObjC.release(@selection_color)   if @selection_color
      @colors&.each_value { |c| ObjC.release(c) }

      @colors = build_color_table
      @default_fg      = make_color(*@active_profile.foreground)
      @default_bg      = make_color(*@active_profile.background)
      @selection_color = make_color(*@active_profile.selection_color)
      @rgb_color_cache = {}  # truecolor cache stale after palette swap

      @window_states.each do |ws|
        ws[:tabs].each { |tab| tab.panes.each { |p| p.screen.mark_all_dirty } } if ws[:tabs]
        ObjC::MSG_VOID_I.call(ws[:nsview], ObjC.sel('setNeedsDisplay:'), 1) if ws[:nsview]
      end
    end

    def update_font(new_size, persist: true)
      @font_size = new_size
      Preferences.set_double(:font_size, new_size) if persist
      old_font = @font
      old_bold = @bold_font
      @font = ObjC.retain(create_nsfont(@font_size))
      @bold_font = ObjC.retain(create_bold_nsfont(@font))
      ObjC.release(old_font) if old_font
      ObjC.release(old_bold) if old_bold
      @font_cache.each_value { |f| ObjC.release(f) unless f.to_i == old_font&.to_i }
      @font_cache = {}
      @font_y_offset_cache = {}
      update_cell_metrics

      @window_states.each do |ws|
        load_window_state(ws)
        win_width = @cell_width * @cols
        win_height = tab_bar_height + @cell_height * @rows
        ObjC::MSG_VOID_2D.call(@window, ObjC.sel('setContentSize:'), win_width, win_height)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        save_window_state
      end
    end

    def perform_drag_operation(sender)
      pb = ObjC::MSG_PTR.call(sender, ObjC.sel('draggingPasteboard'))
      str = self.class.file_paths_from_pasteboard(pb)
      return false if str.nil?

      pane = current_tab.active_pane
      if pane.screen.bracketed_paste_mode?
        pane.write_input("\e[200~")
        pane.write_input(str)
        pane.write_input("\e[201~")
      else
        pane.write_input(str)
      end
      true
    rescue Errno::EIO, IOError
      false
    end

    def self.file_paths_from_pasteboard(pb)
      nsurl_class = ObjC.cls('NSURL')
      class_array = ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'), nsurl_class)
      urls = ObjC::MSG_PTR_2.call(pb, ObjC.sel('readObjectsForClasses:options:'), class_array, Fiddle::Pointer.new(0))
      return nil if urls.null?

      count = ObjC::MSG_RET_L.call(urls, ObjC.sel('count'))
      return nil if count == 0

      paths = count.times.map do |i|
        url = ObjC::MSG_PTR_L.call(urls, ObjC.sel('objectAtIndex:'), i)
        ns_path = ObjC::MSG_PTR.call(url, ObjC.sel('path'))
        ObjC.to_ruby_string(ns_path).shellescape
      end
      paths.join(' ')
    end

    private

    def open_new_window
      save_window_state

      # Create tab
      tab = Tab.new(command: @command, rows: @rows, cols: @cols, embedded: embedded_mode?)
      tab.title = "Shell"
      tab.panes.each { |pane| wire_screen_handlers(pane) }

      # Build window and view in locals — DO NOT touch @window / @view yet.
      # makeKeyAndOrderFront: below fires NSWindowDidResignKeyNotification on
      # the previously-key window synchronously; that handler calls
      # activate_for_view, which would mutate @view mid-construction and
      # corrupt the window-state mapping. Keeping the new pointers in locals
      # lets the focus handler operate on the OLD window's state safely.
      win_width = @cell_width * @cols
      win_height = @cell_height * @rows
      new_window = ObjC::MSG_PTR.call(ObjC.cls('NSWindow'), ObjC.sel('alloc'))
      new_window = ObjC::MSG_PTR_RECT_L_L_I.call(
        new_window, ObjC.sel('initWithContentRect:styleMask:backing:defer:'),
        0.0, 0.0, win_width, win_height,
        ObjC::NSWindowStyleMaskDefault,
        ObjC::NSBackingStoreBuffered,
        0
      )
      ObjC::MSG_VOID_1.call(new_window, ObjC.sel('setTitle:'), ObjC.nsstring(Echoes.config.window_title))
      ObjC::MSG_VOID_L.call(new_window, ObjC.sel('setCollectionBehavior:'), 1 << 7)
      # Required for mouseMoved: to fire on the content view. Used by
      # the shake-to-find-pointer detector (see #mouse_moved); without
      # this, AppKit only delivers move events while a button is held.
      ObjC::MSG_VOID_I.call(new_window, ObjC.sel('setAcceptsMouseMovedEvents:'), 1)

      new_view = ObjC::MSG_PTR.call(@view_class, ObjC.sel('alloc'))
      new_view = ObjC::MSG_PTR_RECT.call(
        new_view, ObjC.sel('initWithFrame:'),
        0.0, 0.0, win_width, win_height
      )

      # Register for file drag-and-drop
      drag_types = ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'), ObjC::NSPasteboardTypeFileURL)
      ObjC::MSG_VOID_1.call(new_view, ObjC.sel('registerForDraggedTypes:'), drag_types)

      # Connect view to window and show it. makeKeyAndOrderFront: triggers a
      # focus_lost handler on the prior key window that may call
      # activate_for_view; using locals here keeps it from mutating @view.
      ObjC::MSG_VOID_1.call(new_window, ObjC.sel('setContentView:'), new_view)
      ObjC::MSG_VOID_1.call(new_window, ObjC.sel('makeKeyAndOrderFront:'), @app)
      ObjC::MSG_VOID_1.call(new_window, ObjC.sel('makeFirstResponder:'), new_view)
      ObjC::MSG_VOID_I.call(@app, ObjC.sel('activateIgnoringOtherApps:'), 1)
      ObjC::MSG_VOID.call(new_window, ObjC.sel('center'))
      # Cocoa-managed cross-launch frame persistence: if a saved frame
      # exists for this name, AppKit moves the window to it (overriding
      # the `center` we just did) and auto-saves on later resize/move.
      ObjC::MSG_VOID_1.call(new_window, ObjC.sel('setFrameAutosaveName:'),
                            ObjC.nsstring('echoes.main'))

      # Focus notification observers (target the new view + new window)
      nc = ObjC::MSG_PTR.call(ObjC.cls('NSNotificationCenter'), ObjC.sel('defaultCenter'))
      ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
        new_view, ObjC.sel('windowDidBecomeKey:'),
        ObjC.nsstring('NSWindowDidBecomeKeyNotification'), new_window)
      ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
        new_view, ObjC.sel('windowDidResignKey:'),
        ObjC.nsstring('NSWindowDidResignKeyNotification'), new_window)

      # Now adopt the new window/view as the active state
      @window = new_window
      @view = new_view
      @tabs = [tab]
      @active_tab = 0
      @search_mode = false
      @search_query = +""
      @search_matches = []
      @search_index = -1
      @search_regex_mode = false
      @search_case_insensitive = false
      @bell_flash = 0
      @marked_text = nil
      @current_event = nil
      @selection_anchor = nil
      @selection_end = nil
      @window_focused = true

      # Register window state
      ws = {}
      @window_states << ws
      @view_to_ws[@view.to_i] = ws
      save_window_state
    end

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

    # Native macOS completion popup. Called from `key_down` when Tab
    # is pressed in an embedded pane and there are 2+ candidates. Builds
    # an NSMenu of items (one per candidate, tagged with the index),
    # anchors it under the cursor cell, and presents it. Selection
    # fires `completionPicked:` on the view, which routes to
    # `completion_picked` below.
    def show_completion_popup(pane, req)
      candidates = req[:candidates]
      menu = ObjC::MSG_PTR.call(ObjC.cls('NSMenu'), ObjC.sel('alloc'))
      menu = ObjC::MSG_PTR_1.call(menu, ObjC.sel('initWithTitle:'), ObjC.nsstring('completion'))
      candidates.each_with_index do |cand, i|
        item = ObjC::MSG_PTR.call(ObjC.cls('NSMenuItem'), ObjC.sel('alloc'))
        item = ObjC::MSG_PTR_3.call(item, ObjC.sel('initWithTitle:action:keyEquivalent:'),
          ObjC.nsstring(cand), ObjC.sel('completionPicked:'), ObjC.nsstring(''))
        ObjC::MSG_VOID_L.call(item, ObjC.sel('setTag:'), i)
        ObjC::MSG_VOID_1.call(menu, ObjC.sel('addItem:'), item)
      end

      @completion_state = {pane: pane, word_start: req[:word_start], candidates: candidates}
      x, y = completion_anchor_point(pane)
      ObjC::MSG_VOID_1_PT_1.call(menu, ObjC.sel('popUpMenuPositioningItem:atLocation:inView:'),
        Fiddle::Pointer.new(0), x, y, @view)
    end

    # NSPoint (in flipped view coords) of the cell *just below* the
    # current cursor row of the active pane, so the popup appears under
    # the cursor without occluding it. The pane's own (x,y) within the
    # tabbed view layout is included so splits land in the right spot.
    def completion_anchor_point(pane)
      tab = current_tab
      gy_off = grid_y_offset
      pane_rects = tab.pane_tree.layout(0, 0, @cols, @rows)
      rect = pane_rects.find { |r| r[:pane] == pane }
      return [0.0, gy_off] unless rect

      cursor = pane.screen.cursor
      x = (rect[:x] + cursor.col) * @cell_width
      y = gy_off + (rect[:y] + cursor.row + 1) * @cell_height
      [x, y]
    end

    # Action callback for an NSMenuItem in the completion popup. Reads
    # the sender's tag, looks up the chosen candidate, and asks the
    # pane to splice it into the input buffer.
    # Public — invoked from the @completion_picked_closure with an
    # explicit receiver (`gui.completion_picked(sender)`); the rest of
    # this section's helpers are private (called from inside the class).
    public def completion_picked(sender)
      state = @completion_state
      return unless state
      tag = ObjC::MSG_RET_L.call(sender, ObjC.sel('tag'))
      cand = state[:candidates][tag]
      return unless cand
      state[:pane].apply_completion(word_start: state[:word_start], completion: cand)
      ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
    ensure
      @completion_state = nil
    end

    # Show an NSOpenPanel for the user to pick a file to load into a
    # Editor pane. Returns the chosen path as a String, or nil if
    # the user canceled. Only single-file selection; directories not
    # accepted.
    def prompt_for_file_to_edit
      panel = ObjC::MSG_PTR.call(ObjC.cls('NSOpenPanel'), ObjC.sel('openPanel'))
      ObjC::MSG_VOID_I.call(panel, ObjC.sel('setCanChooseFiles:'), 1)
      ObjC::MSG_VOID_I.call(panel, ObjC.sel('setCanChooseDirectories:'), 0)
      ObjC::MSG_VOID_I.call(panel, ObjC.sel('setAllowsMultipleSelection:'), 0)

      # Open the dialog at the active pane's pwd (from OSC 7) so the
      # user lands at the directory they're shelling in. Fall back to
      # Echoes' own pwd when the pane hasn't announced a cwd or it
      # doesn't resolve locally.
      start_dir = self.class.pane_local_cwd(current_tab&.active_pane) || Dir.pwd
      if start_dir
        url = ObjC::MSG_PTR_1.call(ObjC.cls('NSURL'), ObjC.sel('fileURLWithPath:'),
                                   ObjC.nsstring(start_dir))
        ObjC::MSG_VOID_1.call(panel, ObjC.sel('setDirectoryURL:'), url)
      end

      result = ObjC::MSG_RET_L.call(panel, ObjC.sel('runModal'))
      return nil unless result == 1  # NSModalResponseOK
      url = ObjC::MSG_PTR.call(panel, ObjC.sel('URL'))
      return nil if url.null?
      path_ns = ObjC::MSG_PTR.call(url, ObjC.sel('path'))
      ObjC.to_ruby_string(path_ns)
    end

    # Curated allowlist of env vars to surface in the About panel —
    # locale, paths, and Echoes/Ruby-runtime knobs. Deliberately
    # NOT a full `ENV` dump: that would leak API keys, tokens,
    # AWS creds, etc. into anything the user screenshots.
    ABOUT_PANEL_ENV_KEYS = %w[
      LANG LC_ALL LC_CTYPE
      TERM SHELL HOME USER PWD
      PATH
      RBENV_VERSION RBENV_ROOT
      BUNDLE_GEMFILE GEM_HOME GEM_PATH
      ECHOES_EMBED ECHOES_HELPER_NO_RC
    ].freeze

    # Custom About panel: Cocoa's standard panel pulls name/version/icon
    # from Info.plist; we extend it with a Credits string showing the
    # Ruby runtime info (version, executable, platform), the
    # bundled-sibling versions (Echoes / rubish / rvim), and a
    # curated set of env vars (see ABOUT_PANEL_ENV_KEYS) so a user
    # can tell at a glance which interpreter and which environment
    # the running .app is wired to.
    def show_about_panel
      lines = [
        "Ruby #{RUBY_VERSION}p#{RUBY_PATCHLEVEL} (#{RUBY_PLATFORM})",
        RbConfig.ruby,
        '',
        "Echoes #{Echoes::VERSION}",
      ]
      lines << "rubish #{Rubish::VERSION}" if defined?(Rubish::VERSION)
      lines << "rvim #{Rvim::VERSION}"     if defined?(Rvim::VERSION)

      env_lines = ABOUT_PANEL_ENV_KEYS.filter_map do |k|
        v = ENV[k]
        v && !v.empty? ? "#{k}=#{v}" : nil
      end
      unless env_lines.empty?
        lines << ''
        lines << 'Environment:'
        lines.concat(env_lines)
      end

      credits_str = lines.join("\n")

      ns_credits = ObjC.nsstring(credits_str)
      attr_alloc = ObjC::MSG_PTR.call(ObjC.cls('NSAttributedString'), ObjC.sel('alloc'))
      attr_str   = ObjC::MSG_PTR_1.call(attr_alloc, ObjC.sel('initWithString:'), ns_credits)

      # Without ApplicationName/Version, Cocoa picks up the running
      # process name ("ruby" — the interpreter the launcher exec'd
      # into) and the generic Ruby folder icon. Override with our
      # bundle values so the panel reads "Echoes 0.1.0".
      options = ObjC.nsdict(
        ObjC.nsstring('ApplicationName')    => ObjC.nsstring('Echoes'),
        ObjC.nsstring('ApplicationVersion') => ObjC.nsstring(Echoes::VERSION),
        ObjC.nsstring('Credits')            => attr_str,
      )
      ObjC::MSG_VOID_1.call(@app, ObjC.sel('orderFrontStandardAboutPanelWithOptions:'), options)
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

      pane = current_tab.active_pane
      if pane.screen.bracketed_paste_mode?
        pane.write_input("\e[200~")
        pane.write_input(str)
        pane.write_input("\e[201~")
      else
        pane.write_input(str)
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
      y = view_frame_height - y_in_window
      gy_off = grid_y_offset
      grid_y = y - gy_off
      return nil if grid_y < 0 || grid_y >= @rows * @cell_height

      visible_row = (grid_y / @cell_height).to_i.clamp(0, @rows - 1)
      col = (x / @cell_width).to_i.clamp(0, @cols - 1)
      # Return absolute row (scrollback + grid index)
      tab = current_tab
      return nil unless tab
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

      cmd_held = (flags & ObjC::NSEventModifierFlagCommand) != 0

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
        # Cmd+R toggles regex; Cmd+I toggles case-insensitive.
        # Re-run the search live so the user sees results update
        # without having to retype.
        if cmd_held && chars.length == 1
          case chars.downcase
          when 'r'
            @search_regex_mode = !@search_regex_mode
            perform_search
          when 'i'
            @search_case_insensitive = !@search_case_insensitive
            perform_search
          end
        elsif !chars.empty? && chars[0].ord >= 0x20
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

      matcher = build_search_matcher(@search_query)
      return unless matcher    # invalid regex → no matches, no crash

      # Search scrollback
      scrollback.each_with_index do |row, abs_row|
        scan_row_for_matches(row, abs_row, matcher)
      end

      # Search grid
      screen.grid.each_with_index do |row, grid_row|
        abs_row = scrollback.size + grid_row
        scan_row_for_matches(row, abs_row, matcher)
      end

      @search_index = @search_matches.size - 1 if @search_matches.any?
      scroll_to_match if @search_index >= 0
    end

    # Returns an object that responds to `find_in(text, pos)` →
    # `[start_idx, length]` or nil. Encapsulates the two axes —
    # regex vs substring × case-sensitive vs case-insensitive —
    # so the row scan stays loop-shaped regardless of mode.
    # Returns nil if `query` is an invalid regex while in regex mode.
    def build_search_matcher(query)
      if @search_regex_mode
        flags = @search_case_insensitive ? Regexp::IGNORECASE : 0
        re = Regexp.new(query, flags) rescue nil
        return nil unless re
        ->(text, pos) {
          m = re.match(text, pos)
          m && [m.begin(0), m.end(0) - m.begin(0)]
        }
      elsif @search_case_insensitive
        needle = query.downcase
        len = needle.length
        ->(text, pos) {
          idx = text.downcase.index(needle, pos)
          idx && [idx, len]
        }
      else
        len = query.length
        ->(text, pos) {
          idx = text.index(query, pos)
          idx && [idx, len]
        }
      end
    end

    def scan_row_for_matches(row, abs_row, matcher)
      text = row.map(&:char).join
      pos = 0
      while pos <= text.length && (hit = matcher.call(text, pos))
        idx, len = hit
        # Ruby's `Regexp#match(s, pos)` past `s.length` still
        # returns the trailing zero-width match, so any
        # zero-width regex (`\b`, `(?=…)`, `^`, `$`) would
        # spin forever without these two guards: bail if the
        # match doesn't start at or after `pos`, and forcibly
        # advance by 1 cell when the match is zero-width.
        break if idx < pos
        step = [len, 1].max
        @search_matches << [abs_row, idx, step]
        pos = idx + step
      end
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
        # Skip cells that are placeholders for a multi-cell character —
        # the second half of a wide CJK/emoji glyph (width == 0) and
        # OSC 66 continuation cells (multicell == :cont). Their `char`
        # is a leftover space from the cell reset; including it
        # produces "T e x t" instead of "Text" for scaled output.
        chars = row[from..to].reject { |c| c.width == 0 || c.multicell == :cont }.map(&:char)
        lines << chars.join.rstrip
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

    # NSView's frame.size.height in points. Querying live (rather than caching
    # @view_height) avoids a class of bugs where the cached value got out of
    # sync after macOS state restoration resized the window asynchronously.
    def view_frame_height
      buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
      sig = ObjC::MSG_PTR_1.call(ObjC.cls('NSView'), ObjC.sel('instanceMethodSignatureForSelector:'), ObjC.sel('frame'))
      inv = ObjC::MSG_PTR_1.call(ObjC.cls('NSInvocation'), ObjC.sel('invocationWithMethodSignature:'), sig)
      ObjC::MSG_VOID_1.call(inv, ObjC.sel('setSelector:'), ObjC.sel('frame'))
      ObjC::MSG_VOID_1.call(inv, ObjC.sel('invokeWithTarget:'), @view)
      ObjC::MSG_VOID_1.call(inv, ObjC.sel('getReturnValue:'), buf)
      buf[0, 32].unpack('d4')[3]
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

    # Used by Screen#put_multicell when an OSC 66 cell carries a
    # proportional font family (`f=`) without an explicit `w=`.
    # Returns the AppKit-measured pixel width of `text` in `family`
    # at the effective rendered size — Screen rounds up to whole
    # cells from there.
    def measure_glyph(text, family, scale, frac_n, frac_d)
      effective_scale = scale.to_f
      if frac_d > 0 && frac_n > 0
        effective_scale *= frac_n.to_f / frac_d.to_f
      end
      font = ObjC.retain(create_nsfont(@font_size * effective_scale, family: family))
      ns = ObjC.nsstring(text)
      attrs = ObjC.nsdict(ObjC::NSFontAttributeName => font)
      width = ObjC::MSG_RET_D_1.call(ns, ObjC.sel('sizeWithAttributes:'), attrs)
      ObjC.release(font)
      width
    end

    # Single point that wires every host-callback a Screen needs
    # (clipboard, palette, glyph measurement, cell metrics, OSC 7772
    # capture). Called everywhere a new Screen comes into existence —
    # initial setup, create_tab, split_horizontal/vertical, and the
    # post-config update path.
    def wire_screen_handlers(pane)
      screen = pane.screen
      screen.clipboard_handler = method(:handle_clipboard)
      screen.glyph_measurer    = method(:measure_glyph)
      screen.cell_pixel_width  = @cell_width  if @cell_width
      screen.cell_pixel_height = @cell_height if @cell_height
      # Capture closure remembers which pane the OSC arrived for so
      # the renderer grabs the right sub-rect (split layouts have
      # several panes per view).
      screen.capture_handler   = ->(path) { capture_pane_to_png(pane, path) }
      screen.notification_handler = ->(title, message) { post_notification(pane, title, message) }
      screen.display_info_handler = -> { display_info_json(pane) }
      screen.open_window_handler  = ->(args) { open_window_from_osc(pane, args) }
    end

    # Post a macOS notification for an in-pane OSC 9 / OSC 777
    # request. Uses `osascript -e 'display notification …'` — the
    # one notification path that works without a properly-bundled
    # native launcher.
    #
    # macOS gates notifications by the calling app's bundle. UN
    # (UNUserNotificationCenter, the modern API) requires
    # `bundleProxyForCurrentProcess` to resolve, which only happens
    # when the process's `_NSGetExecutablePath` points inside a
    # `.app` bundle. Echoes' launcher is a bash script that `exec`s
    # into `ruby`, so the running process's main bundle is the
    # ruby install — UN throws on startup. NSUserNotification has
    # the same problem and is silently dropped on macOS 14+.
    #
    # osascript runs the AppleScript primitive `display notification`
    # which posts through the Script Editor host bundle. **If banners
    # don't appear, open System Settings → Notifications → Script
    # Editor and enable "Banners" or "Alerts"** — the notification
    # is being filed in Notification Center either way, but macOS's
    # display gating is per-host-bundle and Script Editor defaults
    # to "no banner alert". A proper fix is to ship Echoes with a
    # compiled native launcher so the .app's bundle context is
    # preserved across the exec into ruby; tracked as a follow-up.
    # Post a macOS notification for an in-pane OSC 9 / OSC 777
    # request. Prefers `terminal-notifier` when it's on $PATH —
    # it ships as its own .app with its own bundle ID, so the
    # notification registers under "terminal-notifier" in System
    # Settings → Notifications, where the user can toggle banner
    # permission and have it stick.
    #
    # Falls back to `osascript display notification` if
    # terminal-notifier isn't installed. The osascript path goes
    # through Script Editor's notification slot; whether a banner
    # actually shows depends on Script Editor's "Alert style"
    # setting in System Settings → Notifications (which is "None"
    # by default).
    #
    # The real fix for Echoes-attributed notifications needs a
    # compiled native launcher in Contents/MacOS/ so
    # NSBundle.mainBundle survives the exec into ruby; until then
    # `brew install terminal-notifier` is the recommended setup.
    def post_notification(pane, title, message)
      effective_title = (title && !title.empty? && title) || pane&.title || 'Echoes'
      if (tn = terminal_notifier_path)
        pid = Process.spawn(tn, '-title', effective_title.to_s, '-message', message.to_s,
                            in: '/dev/null', out: '/dev/null', err: '/dev/null')
      else
        script = "display notification #{applescript_quote(message)} " \
                 "with title #{applescript_quote(effective_title)}"
        pid = Process.spawn('osascript', '-e', script,
                            in: '/dev/null', out: '/dev/null', err: '/dev/null')
      end
      Process.detach(pid)
    rescue StandardError => e
      warn "echoes notification: #{e.class}: #{e.message}"
    end

    # Memoize the discovered path so we don't `which` on every call.
    def terminal_notifier_path
      return @terminal_notifier_path if defined?(@terminal_notifier_path)
      candidates = %w[
        /opt/homebrew/bin/terminal-notifier
        /usr/local/bin/terminal-notifier
      ]
      path = candidates.find { |p| File.executable?(p) }
      path ||= begin
        which = `command -v terminal-notifier 2>/dev/null`.strip
        which.empty? ? nil : which
      end
      @terminal_notifier_path = path
    end

    # AppleScript string literal: double-quoted, with `\` and `"`
    # escaped. Newlines pass through as `\n` which AppleScript
    # interprets as the literal two characters, which is fine for
    # the "build done" use case.
    def applescript_quote(str)
      escaped = str.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
      %("#{escaped}")
    end

    # OSC 7772 ;capture handler. Writes the given pane's pixel buffer
    # to `path`, dispatching format from the file extension:
    #   .png  → rasterized PNG via NSBitmapImageRep (matches the
    #           view's backing scale; 2× pixel dims on Retina).
    #   else  → vector PDF via [NSView dataWithPDFInsideRect:]
    #           (default; typical terminal screenshots are 5-20×
    #           smaller than the PNG equivalent because text and
    #           rects survive as drawing ops, not raster pixels).
    # No reply on the wire — the caller polls the filesystem.
    NS_BITMAP_IMAGE_FILE_TYPE_PNG = 4

    # Pick raster vs vector by file extension. PDF is the default
    # for anything other than `.png` — it's both the cheaper and
    # more useful format for terminal content.
    def self.capture_format_for(path)
      File.extname(path).downcase == '.png' ? :png : :pdf
    end

    # OSC 7772 ;display-info handler. Returns a JSON string of
    # one entry per NSScreen with pixel dimensions and two flags:
    # `primary` (the screen that owns the menu bar) and `current`
    # (the screen the requesting Echoes window is on). The caller
    # uses `current` to pick "anywhere but here" for a second-screen
    # presentation window. Empty `[]` on any AppKit failure.
    def display_info_json(pane)
      screens = ObjC::MSG_PTR.call(ObjC.cls('NSScreen'), ObjC.sel('screens'))
      return '[]' if screens.nil? || screens.null?
      count = ObjC::MSG_RET_L.call(screens, ObjC.sel('count'))

      main_screen = ObjC::MSG_PTR.call(ObjC.cls('NSScreen'), ObjC.sel('mainScreen'))
      win_screen = nsscreen_for_pane(pane)

      entries = []
      count.times do |i|
        s = ObjC::MSG_PTR_L.call(screens, ObjC.sel('objectAtIndex:'), i)
        _, _, w, h = nsrect_via_invocation(s, 'frame')
        entries << {
          'index'   => i,
          'w'       => w.to_i,
          'h'       => h.to_i,
          'primary' => s.to_i == main_screen.to_i,
          'current' => win_screen && s.to_i == win_screen.to_i,
        }
      end
      JSON.generate(entries)
    rescue StandardError => e
      warn "echoes display-info: #{e.class}: #{e.message}"
      '[]'
    end

    # Return the NSScreen of the NSWindow that owns `pane`, or nil
    # if the pane isn't currently parented to any window state.
    def nsscreen_for_pane(pane)
      ws = @window_states.find { |w| w[:tabs]&.any? { |t| t.panes.include?(pane) } }
      return nil unless ws && ws[:nswindow]
      ObjC::MSG_PTR.call(ws[:nswindow], ObjC.sel('screen'))
    end

    # Invoke a zero-arg method on `target` that returns an NSRect
    # (4 doubles). Fiddle can't model "return 4 doubles" directly,
    # so we route through NSInvocation — same pattern as
    # event_location does for NSPoint.
    def nsrect_via_invocation(target, sel_name)
      target_class = ObjC::MSG_PTR.call(target, ObjC.sel('class'))
      sig = ObjC::MSG_PTR_1.call(
        target_class, ObjC.sel('instanceMethodSignatureForSelector:'),
        ObjC.sel(sel_name)
      )
      inv = ObjC::MSG_PTR_1.call(
        ObjC.cls('NSInvocation'), ObjC.sel('invocationWithMethodSignature:'), sig
      )
      ObjC::MSG_VOID_1.call(inv, ObjC.sel('setSelector:'), ObjC.sel(sel_name))
      ObjC::MSG_VOID_1.call(inv, ObjC.sel('invokeWithTarget:'), target)
      buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
      ObjC::MSG_VOID_1.call(inv, ObjC.sel('getReturnValue:'), buf)
      buf[0, 32].unpack('dddd')  # x, y, w, h
    end

    # Build the env Hash for a child program spawned via OSC 7772
    # ;open-window. Starts from Echoes' own NSProcessInfo-equivalent
    # env (Ruby's ENV) so PATH / HOME / USER / LANG / TERM / any
    # ECHOES_* vars naturally propagate, then patches in defaults
    # for the basics — Echoes.app launched by launchd from Finder
    # inherits a minimal env, so a child that came in via a
    # presentation tool can otherwise wind up without a usable
    # PATH or LANG.
    def child_env_for_open_window
      env = ENV.to_h
      env['PATH']  = ENV['PATH'] || '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
      env['HOME']  = ENV['HOME'] || Dir.home
      env['USER']  ||= (ENV['LOGNAME'] || `id -un 2>/dev/null`.chomp)
      env['LANG']  ||= 'en_US.UTF-8'
      env['TERM']  ||= Echoes.config.term
      env
    end

    # OSC 7772 ;open-window handler. Parses
    # `display=N:program=<base64-argv>:fullscreen=yes|no`, decodes
    # the base64 JSON-encoded argv, and opens a new window on
    # NSScreen.screens[N] running that argv via PTY. fullscreen=yes
    # uses the screen's full frame with a borderless, above-menu-bar
    # window; otherwise visibleFrame with the default style mask.
    # Fire-and-forget: no reply. The caller polls for whatever
    # signal the launched program emits (e.g. a unix socket).
    def open_window_from_osc(pane, args_str)
      params = {}
      args_str.to_s.split(':').each do |pair|
        k, v = pair.split('=', 2)
        next if k.nil? || k.empty? || v.nil?
        params[k] = v
      end

      display_index = (params['display'] || '0').to_i
      fullscreen    = params['fullscreen'] == 'yes'
      program_b64   = params['program']
      return unless program_b64

      json_str = program_b64.delete("\r\n\t ").unpack1('m0')
      argv = JSON.parse(json_str)
      return unless argv.is_a?(Array) && !argv.empty?

      open_external_window(argv: argv, display_index: display_index, fullscreen: fullscreen)
    rescue StandardError => e
      warn "echoes open-window: #{e.class}: #{e.message}"
    end

    # Open a new window running `argv` (e.g. ["/usr/local/bin/przn",
    # "--audience", …]) on a specific display. Sizes the content
    # area to the screen's frame (fullscreen) or visibleFrame, picks
    # cell rows/cols that fit, and routes lifecycle through the
    # standard tab/pane/window-state pipeline so the window
    # auto-closes when the child program exits.
    def open_external_window(argv:, display_index:, fullscreen:)
      save_window_state

      screens = ObjC::MSG_PTR.call(ObjC.cls('NSScreen'), ObjC.sel('screens'))
      count = ObjC::MSG_RET_L.call(screens, ObjC.sel('count'))
      return if display_index < 0 || display_index >= count
      target = ObjC::MSG_PTR_L.call(screens, ObjC.sel('objectAtIndex:'), display_index)

      rect_sel = fullscreen ? 'frame' : 'visibleFrame'
      sx, sy, sw, sh = nsrect_via_invocation(target, rect_sel)

      cols = (sw / @cell_width).floor
      rows = (sh / @cell_height).floor
      cols = [cols, 20].max
      rows = [rows, 5].max

      tab = Tab.new(command: argv, rows: rows, cols: cols, embedded: false,
                    env: child_env_for_open_window)
      tab.title = File.basename(argv.first.to_s)
      tab.panes.each { |pn| wire_screen_handlers(pn) }

      # Borderless mask (0) for fullscreen; default chrome otherwise.
      style_mask = fullscreen ? 0 : ObjC::NSWindowStyleMaskDefault
      new_window = ObjC::MSG_PTR.call(ObjC.cls('NSWindow'), ObjC.sel('alloc'))
      new_window = ObjC::MSG_PTR_RECT_L_L_I.call(
        new_window, ObjC.sel('initWithContentRect:styleMask:backing:defer:'),
        sx, sy, sw, sh, style_mask, ObjC::NSBackingStoreBuffered, 0
      )
      ObjC::MSG_VOID_1.call(new_window, ObjC.sel('setTitle:'), ObjC.nsstring(tab.title))
      ObjC::MSG_VOID_L.call(new_window, ObjC.sel('setCollectionBehavior:'), 1 << 7)
      ObjC::MSG_VOID_I.call(new_window, ObjC.sel('setAcceptsMouseMovedEvents:'), 1)
      if fullscreen
        # NSMainMenuWindowLevel + 1 = 25 = NSStatusWindowLevel; floats
        # above the menu bar so the presentation truly fills the
        # screen even without going through AppKit's fullscreen
        # transition.
        ObjC::MSG_VOID_L.call(new_window, ObjC.sel('setLevel:'), 25)
      end

      new_view = ObjC::MSG_PTR.call(@view_class, ObjC.sel('alloc'))
      new_view = ObjC::MSG_PTR_RECT.call(new_view, ObjC.sel('initWithFrame:'),
                                          0.0, 0.0, sw, sh)
      drag_types = ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'),
                                         ObjC::NSPasteboardTypeFileURL)
      ObjC::MSG_VOID_1.call(new_view, ObjC.sel('registerForDraggedTypes:'), drag_types)

      ObjC::MSG_VOID_1.call(new_window, ObjC.sel('setContentView:'), new_view)
      ObjC::MSG_VOID_1.call(new_window, ObjC.sel('makeKeyAndOrderFront:'), @app)
      ObjC::MSG_VOID_1.call(new_window, ObjC.sel('makeFirstResponder:'), new_view)
      ObjC::MSG_VOID_I.call(@app, ObjC.sel('activateIgnoringOtherApps:'), 1)

      nc = ObjC::MSG_PTR.call(ObjC.cls('NSNotificationCenter'), ObjC.sel('defaultCenter'))
      ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
        new_view, ObjC.sel('windowDidBecomeKey:'),
        ObjC.nsstring('NSWindowDidBecomeKeyNotification'), new_window)
      ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
        new_view, ObjC.sel('windowDidResignKey:'),
        ObjC.nsstring('NSWindowDidResignKeyNotification'), new_window)

      @window = new_window
      @view = new_view
      @tabs = [tab]
      @active_tab = 0
      @search_mode = false
      @search_query = +""
      @search_matches = []
      @search_index = -1
      @search_regex_mode = false
      @search_case_insensitive = false
      @bell_flash = 0
      @marked_text = nil
      @current_event = nil
      @selection_anchor = nil
      @selection_end = nil
      @selection_word_anchor = nil
      @window_focused = true

      ws = {}
      @window_states << ws
      @view_to_ws[@view.to_i] = ws
      save_window_state
    end

    def capture_pane_to_png(pane, path)
      return unless @view
      tab = current_tab
      return unless tab
      rect_info = tab.pane_tree.layout(0, 0, @cols, @rows).find { |r| r[:pane] == pane }
      return unless rect_info

      gy = grid_y_offset
      px = rect_info[:x] * @cell_width
      py = gy + rect_info[:y] * @cell_height
      pw = rect_info[:w] * @cell_width
      ph = rect_info[:h] * @cell_height

      bytes =
        case self.class.capture_format_for(path)
        when :png then png_bytes_for_view_rect(px, py, pw, ph)
        else           pdf_bytes_for_view_rect(px, py, pw, ph)
        end
      return unless bytes
      File.binwrite(path, bytes)
    rescue => e
      warn "echoes capture: #{e.class}: #{e.message}"
    end

    def pdf_bytes_for_view_rect(px, py, pw, ph)
      data = ObjC::MSG_PTR_RECT.call(
        @view, ObjC.sel('dataWithPDFInsideRect:'),
        px, py, pw, ph
      )
      return nil if data.nil? || data.null?
      length    = ObjC::MSG_RET_L.call(data, ObjC.sel('length'))
      bytes_ptr = ObjC::MSG_PTR.call(data, ObjC.sel('bytes'))
      bytes_ptr.to_str(length)
    end

    def png_bytes_for_view_rect(px, py, pw, ph)
      rep = ObjC::MSG_PTR_RECT.call(
        @view, ObjC.sel('bitmapImageRepForCachingDisplayInRect:'),
        px, py, pw, ph
      )
      return nil if rep.nil? || rep.null?
      ObjC::MSG_VOID_RECT_1.call(
        @view, ObjC.sel('cacheDisplayInRect:toBitmapImageRep:'),
        px, py, pw, ph, rep
      )
      empty_dict = ObjC.nsdict({})
      data = ObjC::MSG_PTR_L_1.call(
        rep, ObjC.sel('representationUsingType:properties:'),
        NS_BITMAP_IMAGE_FILE_TYPE_PNG, empty_dict
      )
      return nil if data.nil? || data.null?
      length    = ObjC::MSG_RET_L.call(data, ObjC.sel('length'))
      bytes_ptr = ObjC::MSG_PTR.call(data, ObjC.sel('bytes'))
      bytes_ptr.to_str(length)
    end

    def create_nsfont(size, family: nil)
      family ||= Echoes.config.font_family
      if family
        font = ObjC::MSG_PTR_1D.call(
          ObjC.cls('NSFont'), ObjC.sel('fontWithName:size:'),
          ObjC.nsstring(family), size
        )
        # NSFont returns nil if the family isn't installed; fall back
        # to the monospaced system font so a bad OSC 66 `f=` doesn't
        # leave the cell unrendered.
        return font if font && font.to_i != 0
      end
      ObjC::MSG_PTR_2D.call(
        ObjC.cls('NSFont'), ObjC.sel('monospacedSystemFontOfSize:weight:'),
        size, 0.0
      )
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
      @font_default_line_height = ObjC::MSG_RET_D.call(@font, ObjC.sel('defaultLineHeightForFont'))
      @font_y_offset_cache = {}

      # Propagate cell metrics to all pane screens (sixel sizing,
      # OSC 66 proportional-glyph layout). Handler refs are
      # idempotent so re-wiring on every font change is fine.
      @window_states.each do |ws|
        ws[:tabs]&.each do |tab|
          tab.panes.each { |pane| wire_screen_handlers(pane) }
        end
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

    # AppKit's NSString drawing positions the line box using
    # defaultLineHeightForFont, which can differ between regular and bold
    # variants of the same font (e.g. PlemolJP35 Console NF: regular=24, bold=29).
    # That difference shifts the bold baseline downward versus regular by
    # `bold_lh - regular_lh` points. Compensate by shifting the draw origin
    # by the negative of that difference so all baselines coincide.
    def y_offset_for_font(font)
      return 0.0 if font.to_i == @font.to_i
      cached = @font_y_offset_cache[font.to_i]
      return cached if cached
      font_lh = ObjC::MSG_RET_D.call(font, ObjC.sel('defaultLineHeightForFont'))
      @font_y_offset_cache[font.to_i] = @font_default_line_height - font_lh
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

      # Override with active-profile palette (falls through to the
      # legacy top-level Echoes.config.color_palette when the user's
      # config doesn't declare any profiles).
      if (palette = @active_profile&.color_palette)
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
        tab.write_input("\e[<#{button};#{cx};#{cy}#{final}")
      else
        tab.write_input("\e[M#{(button + 32).chr}#{(cx + 32).chr}#{(cy + 32).chr}")
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
      ObjC::MSG_PTR_D.call(color, ObjC.sel('colorWithAlphaComponent:'), alpha)
    end

    def cached_nsstring(str)
      @nsstring_cache[str] ||= ObjC.retain(ObjC.nsstring(str))
    end

    def nsstring_from_input(obj_ptr)
      is_attr = ObjC::MSG_PTR_1.call(obj_ptr, ObjC.sel('isKindOfClass:'), ObjC.cls('NSAttributedString'))
      if is_attr.to_i != 0
        ns_str = ObjC::MSG_PTR.call(obj_ptr, ObjC.sel('string'))
        ObjC.to_ruby_string(ns_str)
      else
        ObjC.to_ruby_string(obj_ptr)
      end
    end

    def make_color(r, g, b, a = 1.0)
      ObjC.retain(ObjC::MSG_PTR_4D.call(
        ObjC.cls('NSColor'), ObjC.sel('colorWithRed:green:blue:alpha:'),
        r, g, b, a
      ))
    end

    # Paint the pane's background (set via OSC 7772). `spec` is the
    # hash the parser stored on `screen.background`:
    #   {type: :flat,   colors: [[r,g,b,a]]}
    #   {type: :linear, angle: Float, colors: [[r,g,b,a], ...]}
    # Cell-level bg colors paint on top, so selection / highlight /
    # themed cells still occlude correctly. Unknown types (e.g.
    # :radial — not implemented) are a no-op.
    def draw_pane_background(spec, px, py, pane_cols, pane_rows)
      colors = spec[:colors]
      return if !colors || colors.empty?
      w = pane_cols * @cell_width
      h = pane_rows * @cell_height

      case spec[:type]
      when :flat
        rgba  = colors.first
        color = make_color(*rgba)
        ObjC::MSG_VOID.call(color, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(px, py, w, h)
        ObjC.release(color)
      when :linear
        return if colors.size < 2
        # First cut supports two endpoint colors. If the spec carries
        # more, treat first/last as the endpoints — N-color NSArray
        # construction through Fiddle is awkward and isn't required
        # for the keynote-style two-color use case that motivated
        # this.
        start_rgba = colors.first
        end_rgba   = colors.last
        ns_start = make_color(*start_rgba)
        ns_end   = make_color(*end_rgba)
        alloc = ObjC::MSG_PTR.call(ObjC.cls('NSGradient'), ObjC.sel('alloc'))
        gradient = ObjC::MSG_PTR_2.call(alloc, ObjC.sel('initWithStartingColor:endingColor:'),
                                        ns_start, ns_end)

        ObjC::MSG_VOID_RECT_D.call(gradient, ObjC.sel('drawInRect:angle:'),
                                   px, py, w, h, spec[:angle].to_f)

        ObjC.release(gradient)
        ObjC.release(ns_start)
        ObjC.release(ns_end)
      end
    end

    # Paint each `bg-fill` overlay rectangle on top of the base pane
    # background but below cell content. `fills` is a list of
    # {rect: [r1,c1,r2,c2], color: [r,g,b,a]} hashes accumulated by
    # the OSC 7772 `bg-fill` parser. Coordinates are 0-indexed and
    # inclusive on both ends; the rect is clipped to the pane bounds
    # so out-of-range emitter values don't draw outside the pane.
    def draw_pane_fills(fills, px, py, pane_cols, pane_rows)
      fills.each do |fill|
        rect  = fill[:rect]
        rgba  = fill[:color]
        next unless rect && rgba && rect.size == 4
        r1, c1, r2, c2 = rect
        r1 = r1.clamp(0, pane_rows - 1)
        r2 = r2.clamp(0, pane_rows - 1)
        c1 = c1.clamp(0, pane_cols - 1)
        c2 = c2.clamp(0, pane_cols - 1)
        next if r1 > r2 || c1 > c2

        x = px + c1 * @cell_width
        y = py + r1 * @cell_height
        w = (c2 - c1 + 1) * @cell_width
        h = (r2 - r1 + 1) * @cell_height

        ns = make_color(*rgba)
        ObjC::MSG_VOID.call(ns, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(x, y, w, h)
        ObjC.release(ns)
      end
    end
  end

  # Detect a "shake to find pointer" gesture from a stream of mouse
  # samples. Looks at the trailing WINDOW seconds of motion: a shake
  # is several quick direction reversals over a meaningful distance.
  # Tuned for casual wrist-shakes; not a substitute for the OS's own
  # accessibility feature, which kicks in for the visible system
  # cursor regardless of what apps are doing.
  class ShakeDetector
    WINDOW   = 0.5    # seconds of history to consider
    MIN_REVS = 3      # direction reversals required
    MIN_PATH = 150.0  # cumulative pixels of motion required

    def initialize
      @samples = []
    end

    # Add a (time, x, y) sample. Returns true on the call where a
    # shake first crosses the threshold; callers should treat this
    # as edge-triggered and follow up with #reset.
    def observe(t, x, y)
      @samples << [t, x, y]
      cutoff = t - WINDOW
      @samples.shift while @samples.first && @samples.first[0] < cutoff
      return false if @samples.size < 4
      detect
    end

    def reset
      @samples.clear
    end

    private

    def detect
      reversals = 0
      path = 0.0
      prev_dx = nil
      prev_dy = nil
      (1...@samples.size).each do |i|
        _, x0, y0 = @samples[i - 1]
        _, x1, y1 = @samples[i]
        dx = x1 - x0
        dy = y1 - y0
        next if dx.zero? && dy.zero?
        path += Math.sqrt(dx * dx + dy * dy)
        if prev_dx
          if (prev_dx * dx < 0) || (prev_dy * dy < 0)
            reversals += 1
          end
        end
        prev_dx = dx
        prev_dy = dy
      end
      reversals >= MIN_REVS && path >= MIN_PATH
    end
  end
end
