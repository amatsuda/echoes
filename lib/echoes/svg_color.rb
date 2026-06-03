# frozen_string_literal: true

module Echoes
  # SVG color parser for the CG fast-path renderer. Returns
  # [r, g, b, a] (each 0..1), :none ("don't paint this stroke/fill"),
  # or nil ("unsupported — bail to WKWebView").
  module SvgColor
    # 20 CSS / SVG named colors covering the common cases. Anything
    # outside this set returns nil so the caller falls through to
    # the WKWebView renderer (which has the full CSS palette).
    NAMED = {
      'black'       => [  0,   0,   0],
      'white'       => [255, 255, 255],
      'red'         => [255,   0,   0],
      'green'       => [  0, 128,   0],
      'blue'        => [  0,   0, 255],
      'yellow'      => [255, 255,   0],
      'cyan'        => [  0, 255, 255],
      'aqua'        => [  0, 255, 255],
      'magenta'     => [255,   0, 255],
      'fuchsia'     => [255,   0, 255],
      'gray'        => [128, 128, 128],
      'grey'        => [128, 128, 128],
      'orange'      => [255, 165,   0],
      'purple'      => [128,   0, 128],
      'pink'        => [255, 192, 203],
      'brown'       => [165,  42,  42],
      'lime'        => [  0, 255,   0],
      'navy'        => [  0,   0, 128],
      'teal'        => [  0, 128, 128],
      'silver'      => [192, 192, 192],
      'maroon'      => [128,   0,   0],
      'olive'       => [128, 128,   0],
    }.freeze

    HEX_RE = /\A#([0-9a-f]{3,8})\z/i
    RGB_RE = /\Argba?\(\s*([^)]*)\)\z/i

    module_function

    def parse(str, current_color: [0.0, 0.0, 0.0, 1.0])
      return nil if str.nil?
      s = str.strip
      return nil if s.empty?

      down = s.downcase
      return :none                if down == 'none'
      return current_color.dup    if down == 'currentcolor'
      return [0.0, 0.0, 0.0, 0.0] if down == 'transparent'

      if (m = NAMED[down])
        return [m[0] / 255.0, m[1] / 255.0, m[2] / 255.0, 1.0]
      end

      if (m = HEX_RE.match(s))
        return parse_hex(m[1])
      end

      if (m = RGB_RE.match(s))
        return parse_rgb_func(m[1])
      end

      nil
    end

    def parse_hex(hex)
      case hex.length
      when 3
        r, g, b = hex.chars.map { |c| (c + c).to_i(16) }
        [r / 255.0, g / 255.0, b / 255.0, 1.0]
      when 4
        r, g, b, a = hex.chars.map { |c| (c + c).to_i(16) }
        [r / 255.0, g / 255.0, b / 255.0, a / 255.0]
      when 6
        r = hex[0, 2].to_i(16)
        g = hex[2, 2].to_i(16)
        b = hex[4, 2].to_i(16)
        [r / 255.0, g / 255.0, b / 255.0, 1.0]
      when 8
        r = hex[0, 2].to_i(16)
        g = hex[2, 2].to_i(16)
        b = hex[4, 2].to_i(16)
        a = hex[6, 2].to_i(16)
        [r / 255.0, g / 255.0, b / 255.0, a / 255.0]
      else
        nil
      end
    end

    # Parse the body of `rgb(...)` or `rgba(...)`. Components can be
    # int 0..255 or `N%` (0..100). Alpha (if present) is a plain
    # 0..1 float, not a percentage.
    def parse_rgb_func(inner)
      parts = inner.split(',').map(&:strip)
      return nil unless parts.size == 3 || parts.size == 4
      rgb = parts[0, 3].map { |p| parse_component(p) }
      return nil if rgb.any?(&:nil?)
      a = if parts.size == 4
            f = Float(parts[3]) rescue nil
            return nil if f.nil?
            f.clamp(0.0, 1.0)
          else
            1.0
          end
      [*rgb, a]
    end

    def parse_component(p)
      if p.end_with?('%')
        f = Float(p[0..-2]) rescue nil
        return nil if f.nil?
        (f / 100.0).clamp(0.0, 1.0)
      else
        i = Integer(p, 10) rescue nil
        return nil if i.nil?
        (i / 255.0).clamp(0.0, 1.0)
      end
    end
  end
end
