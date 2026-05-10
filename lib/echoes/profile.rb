# frozen_string_literal: true

module Echoes
  # A named color theme — foreground / background / cursor / selection
  # plus the 16-entry ANSI palette that drives the 256-color table.
  # Defined in `~/.config/echoes/echoes.conf` via the `profile` DSL:
  #
  #   profile "Solarized Dark" do
  #     foreground "#93a1a1"
  #     background "#002b36"
  #     cursor_color "#93a1a1", 0.7
  #     selection_color "#586e75"
  #     color_palette %w[#073642 #dc322f #859900 #b58900 #268bd2
  #                      #d33682 #2aa198 #eee8d5 #002b36 #cb4b16
  #                      #586e75 #657b83 #839496 #6c71c4 #93a1a1 #fdf6e3]
  #   end
  #
  # Attributes left unset inherit from `Echoes.config` so a profile
  # can be a partial override.
  class Profile
    attr_reader :name

    def initialize(name)
      @name = name.to_s
      @foreground = nil
      @background = nil
      @cursor_color = nil
      @selection_color = nil
      @color_palette = nil
    end

    def foreground(*args)
      args.empty? ? (@foreground || Echoes.config.foreground) : @foreground = parse_color(args)
    end

    def background(*args)
      args.empty? ? (@background || Echoes.config.background) : @background = parse_color(args)
    end

    def cursor_color(*args)
      args.empty? ? (@cursor_color || Echoes.config.cursor_color) : @cursor_color = parse_color(args)
    end

    def selection_color(*args)
      args.empty? ? (@selection_color || Echoes.config.selection_color) : @selection_color = parse_color(args)
    end

    def color_palette(val = nil)
      if val
        @color_palette = val.map { |c| c.is_a?(String) ? parse_color([c]) : c.map(&:to_f) }
      else
        @color_palette || Echoes.config.color_palette
      end
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
end
