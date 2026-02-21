# frozen_string_literal: true

module Echoes
  class SixelDecoder
    attr_reader :width, :height

    def initialize(params = [])
      @background_mode = params[1] || 0
      @color_registers = default_color_registers
      @current_color = 0
      @cursor_x = 0
      @cursor_y = 0
      @width = 0
      @height = 0
      @pixels = {}
      @declared_width = 0
      @declared_height = 0
    end

    def decode(data)
      i = 0
      len = data.bytesize

      while i < len
        byte = data.getbyte(i)

        case byte
        when 0x21 # '!' repeat
          i, count, ch = parse_repeat(data, i + 1)
          paint_sixel(ch, count) if ch
        when 0x22 # '"' raster attributes
          i, _, _, ph, pv = parse_raster_attributes(data, i + 1)
          @declared_width = ph if ph > 0
          @declared_height = pv if pv > 0
        when 0x23 # '#' color
          i = parse_color(data, i + 1)
        when 0x24 # '$' graphics CR
          @cursor_x = 0
          i += 1
        when 0x2D # '-' graphics newline
          @cursor_x = 0
          @cursor_y += 6
          i += 1
        when 0x3F..0x7E # sixel character
          paint_sixel(byte, 1)
          i += 1
        else
          i += 1
        end
      end

      @width = @declared_width if @declared_width > @width
      @height = @declared_height if @declared_height > @height
      self
    end

    def to_rgba
      buf = "\x00".b * (@width * @height * 4)
      transparent = @background_mode == 1

      @pixels.each do |(x, y), color|
        next if x >= @width || y >= @height

        offset = (y * @width + x) * 4
        buf.setbyte(offset,     color[0])
        buf.setbyte(offset + 1, color[1])
        buf.setbyte(offset + 2, color[2])
        buf.setbyte(offset + 3, 255)
      end

      unless transparent
        # Set alpha=255 for unset pixels (background fill)
        (@width * @height).times do |i|
          offset = i * 4
          buf.setbyte(offset + 3, 255) if buf.getbyte(offset + 3) == 0
        end
      end

      buf
    end

    private

    def default_color_registers
      {
        0  => [0,   0,   0],
        1  => [51,  51, 204],
        2  => [204, 51,  51],
        3  => [51, 204,  51],
        4  => [204, 51, 204],
        5  => [51, 204, 204],
        6  => [204, 204, 51],
        7  => [135, 135, 135],
        8  => [68,  68,  68],
        9  => [84,  84, 255],
        10 => [255, 84,  84],
        11 => [84, 255,  84],
        12 => [255, 84, 255],
        13 => [84, 255, 255],
        14 => [255, 255, 84],
        15 => [255, 255, 255],
      }
    end

    def paint_sixel(byte, count)
      bits = byte - 0x3F
      color = @color_registers[@current_color] || [0, 0, 0]

      6.times do |bit|
        next unless (bits >> bit) & 1 == 1

        y = @cursor_y + bit
        count.times do |dx|
          x = @cursor_x + dx
          @pixels[[x, y]] = color
          @width = x + 1 if x + 1 > @width
        end
        @height = y + 1 if y + 1 > @height
      end

      @cursor_x += count
      @width = @cursor_x if @cursor_x > @width
    end

    def parse_repeat(data, i)
      len = data.bytesize
      num_str = +""
      while i < len && data.getbyte(i) >= 0x30 && data.getbyte(i) <= 0x39
        num_str << data.getbyte(i).chr
        i += 1
      end
      count = num_str.empty? ? 1 : num_str.to_i
      ch = nil
      if i < len
        byte = data.getbyte(i)
        ch = byte if byte >= 0x3F && byte <= 0x7E
        i += 1
      end
      [i, count, ch]
    end

    def parse_raster_attributes(data, i)
      values, i = parse_numeric_params(data, i)
      [i, values[0] || 0, values[1] || 0, values[2] || 0, values[3] || 0]
    end

    def parse_color(data, i)
      values, i = parse_numeric_params(data, i)

      if values.size == 1
        @current_color = values[0]
      elsif values.size >= 5
        pc, pu, px, py, pz = values
        if pu == 1
          @color_registers[pc] = hls_to_rgb(px, py, pz)
        else
          @color_registers[pc] = [
            (px * 255 / 100.0).round.clamp(0, 255),
            (py * 255 / 100.0).round.clamp(0, 255),
            (pz * 255 / 100.0).round.clamp(0, 255),
          ]
        end
        @current_color = pc
      end
      i
    end

    def parse_numeric_params(data, i)
      values = []
      num_str = +""
      len = data.bytesize
      while i < len
        byte = data.getbyte(i)
        if byte >= 0x30 && byte <= 0x39
          num_str << byte.chr
          i += 1
        elsif byte == 0x3B
          values << (num_str.empty? ? 0 : num_str.to_i)
          num_str = +""
          i += 1
        else
          values << (num_str.empty? ? 0 : num_str.to_i)
          break
        end
      end
      [values, i]
    end

    def hls_to_rgb(h, l, s)
      hh = h / 360.0
      ll = l / 100.0
      ss = s / 100.0

      if ss == 0
        v = (ll * 255).round.clamp(0, 255)
        return [v, v, v]
      end

      q = ll < 0.5 ? ll * (1.0 + ss) : ll + ss - ll * ss
      p = 2.0 * ll - q

      r = hue_to_rgb(p, q, hh + 1.0 / 3)
      g = hue_to_rgb(p, q, hh)
      b = hue_to_rgb(p, q, hh - 1.0 / 3)

      [(r * 255).round.clamp(0, 255),
       (g * 255).round.clamp(0, 255),
       (b * 255).round.clamp(0, 255)]
    end

    def hue_to_rgb(p, q, t)
      t += 1.0 if t < 0
      t -= 1.0 if t > 1
      return p + (q - p) * 6.0 * t if t < 1.0 / 6
      return q if t < 1.0 / 2
      return p + (q - p) * (2.0 / 3 - t) * 6.0 if t < 2.0 / 3

      p
    end
  end
end
