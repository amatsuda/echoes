# frozen_string_literal: true

require_relative 'profile'

module Echoes
  class Configuration
    def initialize
      @font_size = 14.0
      @rows = 24
      @cols = 80
      @shell = ENV['SHELL'] || '/bin/bash'
      @scrollback_limit = 1000
      @foreground = [0.9, 0.9, 0.9]
      @background = [0.0, 0.0, 0.0]
      @cursor_color = [0.7, 0.7, 0.7, 0.5]
      @font_family = nil
      @window_title = 'Echoes'
      @tab_position = :top
      @color_palette = nil
      @term = 'xterm-256color'
      @word_separators = ' @*.:/\\()"\'-:,.;<>~!#$%^&*|+=[]{}~?│'
      @selection_color = [0.2, 0.4, 0.7]
      @pane_divider_color = [0.4, 0.4, 0.4]
      @active_pane_border_color = [0.3, 0.5, 0.8]
      @copy_mode_cursor_color = [0.8, 0.7, 0.2]
      register_default_profiles
    end

    # Two opinionated-but-recognizable profiles ship with Echoes so
    # the View → Profile submenu has alternatives the moment the
    # user opens it, without forcing them to write any DSL. Users
    # can declare more (or override these) in their config file —
    # `profile "Solarized Dark" do …` redeclaring an existing name
    # replaces the entry.
    def register_default_profiles
      profile "Solarized Dark" do
        foreground "#93a1a1"
        background "#002b36"
        cursor_color "#93a1a1"
        selection_color "#586e75"
        color_palette %w[
          #073642 #dc322f #859900 #b58900 #268bd2 #d33682 #2aa198 #eee8d5
          #002b36 #cb4b16 #586e75 #657b83 #839496 #6c71c4 #93a1a1 #fdf6e3
        ]
      end
      profile "Solarized Light" do
        foreground "#586e75"
        background "#fdf6e3"
        cursor_color "#586e75"
        selection_color "#93a1a1"
        color_palette %w[
          #073642 #dc322f #859900 #b58900 #268bd2 #d33682 #2aa198 #eee8d5
          #002b36 #cb4b16 #586e75 #657b83 #839496 #6c71c4 #93a1a1 #fdf6e3
        ]
      end
    end

    def font_family(val = nil)
      val ? @font_family = val : @font_family
    end

    def font_size(val = nil)
      val ? @font_size = val.to_f : @font_size
    end

    def rows(val = nil)
      val ? @rows = val.to_i : @rows
    end

    def cols(val = nil)
      val ? @cols = val.to_i : @cols
    end

    def shell(val = nil)
      val ? @shell = val : @shell
    end

    def scrollback_limit(val = nil)
      val ? @scrollback_limit = val.to_i : @scrollback_limit
    end

    def foreground(*args)
      args.empty? ? @foreground : @foreground = parse_color(args)
    end

    def background(*args)
      args.empty? ? @background : @background = parse_color(args)
    end

    def cursor_color(*args)
      args.empty? ? @cursor_color : @cursor_color = parse_color(args)
    end

    def window_title(val = nil)
      val ? @window_title = val : @window_title
    end

    def tab_position(val = nil)
      val ? @tab_position = val.to_sym : @tab_position
    end

    def term(val = nil)
      val ? @term = val : @term
    end

    def word_separators(val = nil)
      val ? @word_separators = val : @word_separators
    end

    def selection_color(*args)
      args.empty? ? @selection_color : @selection_color = parse_color(args)
    end

    def pane_divider_color(*args)
      args.empty? ? @pane_divider_color : @pane_divider_color = parse_color(args)
    end

    def active_pane_border_color(*args)
      args.empty? ? @active_pane_border_color : @active_pane_border_color = parse_color(args)
    end

    def copy_mode_cursor_color(*args)
      args.empty? ? @copy_mode_cursor_color : @copy_mode_cursor_color = parse_color(args)
    end

    def color_palette(val = nil)
      if val
        @color_palette = val.map { |c| c.is_a?(String) ? parse_color([c]) : c.map(&:to_f) }
      else
        @color_palette
      end
    end

    # Define a named profile (color theme). Anything not set inside
    # the block falls back to the top-level config attrs, so a profile
    # is a partial override.
    #
    #   profile "Light" do
    #     foreground "#1a1a1a"
    #     background "#ffffff"
    #   end
    def profile(name, &block)
      p = Profile.new(name)
      p.instance_eval(&block) if block
      profiles[p.name] = p
      p
    end

    def profiles
      @profiles ||= {}
    end

    # Profiles plus the synthesized "Default" — the menu / GUI uses
    # this so the View → Profile submenu always has at least a
    # discoverable "Default" entry even when the user hasn't
    # declared any profiles.
    def all_profiles
      base = {'Default' => synthesized_profile}
      base.merge(profiles)
    end

    # Rebind a menu shortcut. The first arg is a shortcut string
    # like "Cmd+Shift+S" (Cmd / Shift / Ctrl / Option modifiers,
    # case-insensitive); pass an empty string to disable the
    # shortcut entirely. The second is the action symbol — one
    # of the symbols Echoes documents (:new_window, :split_right,
    # :toggle_find, etc.).
    #
    #   keybind "Cmd+Shift+T", :new_tab
    #   keybind "",            :toggle_pointer     # disable
    def keybind(shortcut, action)
      keybinds[action.to_sym] = parse_shortcut(shortcut.to_s)
    end

    def keybinds
      @keybinds ||= {}
    end

    # Returns {key:, modifiers:} or nil if no override is set.
    def keybind_for(action)
      keybinds[action.to_sym]
    end

    # Matches the NSEvent modifier flag bits — kept in sync with
    # `ObjC::NSEventModifierFlag*` in objc.rb. Defined here so
    # Configuration can resolve shortcut strings without depending
    # on the AppKit-loading objc.rb at config-load time.
    SHORTCUT_MODIFIERS = {
      'shift'   => 1 << 17,
      'control' => 1 << 18,
      'ctrl'    => 1 << 18,
      'option'  => 1 << 19,
      'opt'     => 1 << 19,
      'alt'     => 1 << 19,
      'cmd'     => 1 << 20,
      'command' => 1 << 20,
      'super'   => 1 << 20,
    }.freeze

    def parse_shortcut(str)
      return {key: '', modifiers: 0} if str.nil? || str.empty?
      parts = str.split('+').map(&:strip)
      key = parts.pop.to_s.downcase
      modifiers = parts.sum { |p| SHORTCUT_MODIFIERS[p.downcase] || 0 }
      {key: key, modifiers: modifiers}
    end

    # Pick / look up the active profile by name. With no arg, returns
    # whatever the user named via `default_profile "Foo"`, falling
    # back to the synthesized "Default" so legacy configs (just
    # foreground/background/etc.) keep working unchanged.
    def default_profile(name = nil)
      if name
        @default_profile_name = name.to_s
      else
        profiles[@default_profile_name] || synthesized_profile
      end
    end

    # Build a "Default" Profile from the flat config attrs every
    # time it's asked for — never memoized, because the user's
    # config might mutate the flat attrs after our first call.
    def synthesized_profile
      p = Profile.new('Default')
      p.instance_variable_set(:@foreground,      @foreground)
      p.instance_variable_set(:@background,      @background)
      p.instance_variable_set(:@cursor_color,    @cursor_color)
      p.instance_variable_set(:@selection_color, @selection_color)
      p.instance_variable_set(:@color_palette,   @color_palette)
      p
    end

    private

    def parse_color(args)
      if args.size == 1 && args[0].is_a?(String)
        hex = args[0].delete_prefix('#')
        r = hex[0, 2].to_i(16) / 255.0
        g = hex[2, 2].to_i(16) / 255.0
        b = hex[4, 2].to_i(16) / 255.0
        if hex.size == 8
          a = hex[6, 2].to_i(16) / 255.0
          [r, g, b, a]
        else
          [r, g, b]
        end
      else
        args.map(&:to_f)
      end
    end
  end

  CONFIG_PATH = File.join(Dir.home, '.config', 'echoes', 'echoes.conf')

  def self.config
    @config ||= Configuration.new
  end

  def self.load_config
    if File.exist?(CONFIG_PATH)
      config.instance_eval(File.read(CONFIG_PATH), CONFIG_PATH)
    end
  rescue SyntaxError, StandardError => e
    warn "echoes: error loading #{CONFIG_PATH}: #{e.message}"
  end
end
