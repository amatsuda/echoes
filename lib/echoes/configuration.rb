# frozen_string_literal: true

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

    def color_palette(val = nil)
      if val
        @color_palette = val.map { |c| c.is_a?(String) ? parse_color([c]) : c.map(&:to_f) }
      else
        @color_palette
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

  CONFIG_PATH = File.join(Dir.home, '.config', 'echoes', 'echoes.conf')

  def self.config
    @config ||= Configuration.new
  end

  def self.load_config
    if File.exist?(CONFIG_PATH)
      config.instance_eval(File.read(CONFIG_PATH), CONFIG_PATH)
    end
  end
end
