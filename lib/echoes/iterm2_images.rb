# frozen_string_literal: true

module Echoes
  # iTerm2 inline-image protocol (OSC 1337 with the `File=` verb).
  # Wire format:
  #
  #   \e]1337;File=<key=value>[;<key=value>...]:<base64-payload>\a
  #
  # Most of the heavy lifting (NSBitmapImageRep PNG/JPEG/TIFF/GIF
  # decode, RGBA pixmap storage on the screen, blit through the
  # multicell renderer) is already shipped for the Kitty graphics
  # protocol — this module just parses the OSC 1337 envelope and
  # delegates to Echoes::KittyGraphics::AppKitPng /
  # Screen#put_kitty_image.
  #
  # Out of scope (follow-ups, if anyone hits them):
  #   - `inline=0` (save to disk / clipboard) — we ignore these.
  #   - `preserveAspectRatio=0` (non-uniform stretch) — we always
  #     preserve aspect; user can request explicit `width=` + `height=`.
  #   - The `name=`-base64 metadata — useful for "Save As" UIs we
  #     don't have.
  module Iterm2Images
    module_function

    # Top-level entry point. `rest` is everything between
    # `\e]1337;` and the terminating BEL/ST. Returns truthy on
    # successful image display; nil otherwise (silently).
    def handle(rest, screen:, writer: nil)
      verb_args = rest.to_s
      return nil unless verb_args.start_with?('File=')

      params_str, payload_b64 = verb_args.byteslice(5..).split(':', 2)
      return nil if payload_b64.nil? || payload_b64.empty?

      params = parse_params(params_str || '')

      # iTerm2 only inlines images when `inline=1`. Absent means
      # "save to disk", which we don't support — bail.
      return nil unless params['inline'] == '1'

      bytes = decode_payload(payload_b64)
      return nil unless bytes

      image = decode_image(bytes)
      return nil unless image

      cells_w, cells_h = compute_cell_dimensions(params, image, screen)
      screen.put_kitty_image(
        rgba:    image[:rgba],
        width:   image[:width],
        height:  image[:height],
        cells_w: cells_w,
        cells_h: cells_h,
      )
      true
    end

    # Parse "k1=v1;k2=v2" into {"k1"=>"v1", "k2"=>"v2"}.
    def parse_params(str)
      out = {}
      str.split(';').each do |pair|
        k, v = pair.split('=', 2)
        next if k.nil? || k.empty?
        out[k] = (v || '').to_s
      end
      out
    end

    # Tolerant base64 decode (allows wrapped / whitespace payloads).
    # Mirrors KittyGraphics.decode_payload to keep the two paths
    # symmetric.
    def decode_payload(b64)
      cleaned = b64.to_s.delete("\r\n\t ")
      return nil if cleaned.empty?
      cleaned.unpack1('m0')
    rescue ArgumentError
      nil
    end

    # Bytes → {rgba:, width:, height:}. Despite the name,
    # AppKitPng handles every format NSBitmapImageRep recognizes
    # (PNG / JPEG / GIF / TIFF / BMP) because it draws the
    # decoded CGImage into a known RGBA8 CGBitmapContext.
    def decode_image(bytes)
      require_relative 'kitty_graphics_appkit'
      KittyGraphics::AppKitPng.decode(bytes)
    end

    # Translate the wire's `width=` / `height=` into cell counts
    # for the renderer. Supported forms (per iTerm2 docs):
    #   N      — N character cells
    #   Npx    — N pixels; rounded up to a whole cell
    #   N%     — N% of the screen dimension
    #   auto   — natural pixel size / cell pixel size (default)
    # nil or unrecognized → `auto`.
    def compute_cell_dimensions(params, image, screen)
      cell_w_px = screen.cell_pixel_width.to_f
      cell_h_px = screen.cell_pixel_height.to_f
      cells_w = parse_dim(params['width'],
                          natural_px: image[:width],
                          cell_px:    cell_w_px,
                          screen_size: screen.cols)
      cells_h = parse_dim(params['height'],
                          natural_px: image[:height],
                          cell_px:    cell_h_px,
                          screen_size: screen.rows)
      [cells_w, cells_h]
    end

    def parse_dim(value, natural_px:, cell_px:, screen_size:)
      return nil if value.nil? || value.empty? || value == 'auto'
      if value.end_with?('px')
        return nil if cell_px <= 0
        (value.to_f / cell_px).ceil
      elsif value.end_with?('%')
        (screen_size * value.to_f / 100.0).ceil
      else
        value.to_i
      end
    end
  end
end
