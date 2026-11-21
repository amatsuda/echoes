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
      # One RGBA byte string per painted pixel row, grown as runs
      # land in it; a repeat of N paints with a single string copy
      # rather than N hash inserts. Gaps between runs hold the
      # background pixel (transparent in mode 1, opaque black else).
      @rows = {}
      @bg_px = (@background_mode == 1 ? "\x00\x00\x00\x00" : "\x00\x00\x00\xFF").b
      @color_px = {}
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
      stride = @width * 4
      buf = @bg_px * (@width * @height)
      @rows.each do |y, row|
        next if y >= @height
        n = [row.bytesize, stride].min
        buf[y * stride, n] = row.byteslice(0, n)
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

    # Largest image either axis may reach. A repeat count comes off
    # the wire (`!999999999~` is 13 bytes), so painting stops at this
    # edge instead of inserting billions of pixels.
    MAX_DIMENSION = 4096

    def paint_sixel(byte, count)
      return if @cursor_y >= MAX_DIMENSION
      count = [count, MAX_DIMENSION - @cursor_x].min
      return if count <= 0

      bits = byte - 0x3F
      color = @color_registers[@current_color] || [0, 0, 0]
      run = nil

      6.times do |bit|
        next unless (bits >> bit) & 1 == 1

        y = @cursor_y + bit
        next if y >= MAX_DIMENSION
        run ||=(@color_px[color] ||= [color[0], color[1], color[2], 255].pack('C4')) * count
        row = (@rows[y] ||= +''.b)
        start = @cursor_x * 4
        row << @bg_px * ((start - row.bytesize) / 4) if row.bytesize < start
        row[start, run.bytesize] = run
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
      # DEC's HLS hue circle starts at blue (0°), with red at 120° and
      # green at 240°, unlike CSS/HSL where red is 0°.
      hh = ((h + 240) % 360) / 360.0
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
