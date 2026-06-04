# frozen_string_literal: true

require 'zlib'
require_relative 'svg_sniffer'

module Echoes
  # Minimum-viable Kitty graphics protocol decoder. Wire format:
  #
  #   \e_G<comma-separated-options>;<base64-payload>\e\
  #
  # Parser hands us the body (sans `\e_G…\e\\` framing) split into
  # `meta` and the still-base64 `payload`. We accumulate chunks
  # keyed by image id (m=1 = more, m=0 = last), base64-decode the
  # full payload, decode PNG (f=100, the default) into RGBA via
  # AppKit, then either cache the image (a=t) or display it via
  # `screen.put_kitty_image` (a=T or a=p).
  #
  # State lives on the parser (per-pane) — not module globals —
  # so chunks from different panes don't collide.
  module KittyGraphics
    CHUNK_LIMIT_BYTES = 16 * 1024 * 1024
    # Most-recent N images, LRU. Slide-deck tooling (przn) uploads one
    # image per shape primitive (`<rect>`, `<line>`, etc.) plus regular
    # `<img>` tags, so a single slide easily crosses double digits. 16
    # was a leftover sized for typical TUI clients that only stream a
    # few inline images; bumping to 128 keeps memory bounded
    # (~50 MB at typical slide-image sizes) while comfortably handling
    # a busy slide and a few previous slides' images cached in.
    CACHE_LIMIT       = 128
    DEFAULT_FORMAT    = '100'.freeze  # PNG

    module_function

    # Parse "a=T,f=100,i=1" into {"a"=>"T", "f"=>"100", "i"=>"1"}.
    # Keys with no `=` map to '' so the caller can still tell they
    # were present.
    def parse_options(meta)
      out = {}
      meta.to_s.split(',').each do |pair|
        k, v = pair.split('=', 2)
        next if k.nil? || k.empty?
        out[k] = (v || '').to_s
      end
      out
    end

    # Add one APC chunk's payload to the per-id buffer. Returns the
    # full assembled payload + final-options Hash when this chunk
    # closes the image (m=0 or no m=); returns nil while more
    # chunks are still expected.
    def assemble_chunk(state, meta, payload)
      opts = parse_options(meta)
      id   = opts['i'] || opts['I'] || ''
      more = opts['m'] == '1'

      buf = state[:chunks][id]
      if buf
        # Subsequent chunk: append payload, update saved-options
        # only with newly-seen non-id keys (Kitty's spec: only `m`
        # / `q` / `S` / size differ across chunks).
        return nil if buf[1].bytesize + payload.bytesize > CHUNK_LIMIT_BYTES
        buf[0]['m'] = opts['m'] if opts.key?('m')
        buf[0]['q'] = opts['q'] if opts.key?('q')
        buf[1] << payload
      else
        # First chunk: stash both options and payload.
        return nil if payload.bytesize > CHUNK_LIMIT_BYTES
        buf = [opts, +"".b]
        buf[1] << payload
        state[:chunks][id] = buf
      end

      return nil if more

      state[:chunks].delete(id)
      [buf[0], buf[1]]
    end

    # Top-level dispatcher — one call per APC frame.
    def handle_chunk(state, meta, payload, screen:, writer:)
      assembled = assemble_chunk(state, meta, payload)
      return unless assembled
      opts, b64 = assembled

      action = opts['a'].to_s
      action = 'T' if action.empty?  # default action

      case action
      when 'T', 't'
        bytes = decode_payload(b64)
        return respond(writer, opts, error: 'EBADPNG') unless bytes

        # Transmission medium (`t=…`):
        #   d (default) — payload is the image bytes (already decoded above)
        #   f          — payload is an absolute file path; we read it
        #   t          — same as `f`, then delete the file (temp file)
        #   s          — shared memory; not supported
        bytes = resolve_transmission(bytes, opts)
        return respond(writer, opts, error: 'ENOENT') unless bytes

        # Compression (`o=…`):
        #   (unset) — payload is uncompressed
        #   z       — payload is raw zlib (deflate). kitten icat
        #             defaults to o=z for any non-PNG transmission,
        #             so this is the common case in the wild.
        bytes = inflate_if_needed(bytes, opts['o'])
        return respond(writer, opts, error: 'EBADDATA') unless bytes

        image = decode_image(bytes, opts['f'] || DEFAULT_FORMAT, opts, screen: screen)
        return respond(writer, opts, error: 'EBADPNG') unless image

        cache_image(state, opts['i'] || opts['I'] || '', image)
        if action == 'T'
          display_image(screen, image, opts)
        end
        respond(writer, opts, ok: true)

      when 'p'
        id    = opts['i'] || opts['I'] || ''
        image = state[:cache][id]
        if image
          display_image(screen, image, opts)
          respond(writer, opts, ok: true)
        else
          respond(writer, opts, error: 'ENOENT')
        end

      when 'd'
        # kitty spec: a=d deletes placements (lowercase d-selector)
        # or placements + images (uppercase selector). Default
        # selector is 'a' (all placements on the visible screen).
        #
        # Supported selectors (subset; expand as use cases arrive):
        #   d=a / d=A  — all placements; uppercase also flushes
        #                 the bitmap cache so the next a=p has to
        #                 re-decode.
        #   d=i / d=I  — placements matching i= / I=; uppercase
        #                 also flushes that one cache entry.
        #   (omitted)  — treated as d=a per spec.
        sel    = (opts['d'] || 'a').to_s
        target = opts['i'] || opts['I']
        upper  = sel == sel.upcase && !sel.empty?
        case sel.downcase
        when 'a', ''
          screen.placements.clear if screen.respond_to?(:placements)
          state[:cache].clear if upper
        when 'i', 'n'
          if target && !target.empty?
            if screen.respond_to?(:placements)
              screen.placements.reject! { |pl| pl[:image_id] == target }
            end
            state[:cache].delete(target) if upper
          end
        end
        respond(writer, opts, ok: true)

      when 'q'
        # Capability probe. kitten icat (and others) send a tiny
        # dummy frame with a=q before transmitting real images;
        # they read the OK/error reply to decide whether the
        # terminal supports the protocol. We don't decode the
        # payload — just answer whether we'd accept this
        # format / transmission / compression combo.
        if supported_format?(opts['f']) &&
           supported_transmission?(opts['t']) &&
           supported_compression?(opts['o'])
          respond(writer, opts, ok: true)
        else
          respond(writer, opts, error: 'EBADF')
        end
      end
    end

    def supported_format?(f)
      case f.to_s
      when '', '100', '24', '32' then true
      else false
      end
    end

    def supported_transmission?(t)
      case t.to_s
      when '', 'd', 'f', 't' then true   # direct, file, tempfile
      else false                          # 's' (shared mem) etc.
      end
    end

    def supported_compression?(o)
      case o.to_s
      when '', 'z' then true   # uncompressed, or raw zlib
      else false
      end
    end

    # Raw-zlib inflate when the wire says `o=z`. Returns the
    # original bytes when no compression was applied, or nil on a
    # corrupt stream (so the caller can answer EBADDATA).
    def inflate_if_needed(bytes, compression)
      case compression.to_s
      when ''  then bytes
      when 'z' then Zlib::Inflate.inflate(bytes)
      else          nil
      end
    rescue Zlib::Error
      nil
    end

    # Tolerant base64 decode: strips whitespace (some clients
    # line-wrap APC payloads) and returns nil on invalid input.
    # Avoids `require 'base64'` (no longer in default gems on
    # Ruby 3.4+) by going through `String#unpack1('m0')`.
    #
    # The kitty spec explicitly permits omitted padding, and
    # `kitten icat --transfer-mode stream` splits its base64 at
    # arbitrary byte boundaries — the *assembled* payload across
    # all m=1 chunks can therefore end mid-quad. Pad to a multiple
    # of 4 before strict decode so we don't silently EBADPNG.
    def decode_payload(b64)
      cleaned = b64.to_s.delete("\r\n\t ")
      return ''.b if cleaned.empty?
      pad = (4 - cleaned.bytesize % 4) % 4
      cleaned += '=' * pad if pad > 0
      cleaned.unpack1('m0')
    rescue ArgumentError
      nil
    end

    # Read image bytes off the filesystem when the wire requested
    # `t=f` or `t=t`. Returns nil on missing / unreadable file or
    # any read error. For `t=t` the file is unlinked after a
    # successful read; the kitty client uses this when sending a
    # one-shot tempfile it owns.
    def resolve_transmission(decoded_payload, opts)
      case opts['t'].to_s
      when '', 'd'
        decoded_payload
      when 'f', 't'
        path = decoded_payload.dup.force_encoding('UTF-8')
        return nil if path.empty? || !File.file?(path) || !File.readable?(path)
        data = File.binread(path)
        File.delete(path) if opts['t'] == 't'
        data
      else
        nil  # 's' / anything else — not supported
      end
    rescue StandardError
      nil
    end

    # Decode an image payload to {rgba:, width:, height:}.
    #   <sniffed SVG> — render via WKWebView regardless of f=
    #   f=100 / unset — PNG (and anything else NSBitmapImageRep
    #                   eats: JPEG, GIF, TIFF, BMP)
    #   f=24          — raw RGB packed, dims from s= / v=
    #   f=32          — raw RGBA packed, dims from s= / v=
    def decode_image(bytes, format, opts = {}, screen: nil)
      return decode_svg(bytes, opts, screen) if SvgSniffer.svg?(bytes)
      case format.to_s
      when '100', ''
        decode_png(bytes)
      when '24'
        load_appkit
        AppKitPng.from_rgb(bytes, opts['s'].to_i, opts['v'].to_i)
      when '32'
        load_appkit
        AppKitPng.from_rgba(bytes, opts['s'].to_i, opts['v'].to_i)
      end
    end

    # SVG → {rgba:, width:, height:}. Picks the rasterization target
    # before handing off to SvgRenderer (vector input has no intrinsic
    # raster size, so the renderer needs explicit pixel dims).
    def decode_svg(bytes, opts, screen)
      require_relative 'svg_renderer'
      w, h = svg_target_pixels(opts, screen, bytes)
      SvgRenderer.rasterize(bytes, width: w, height: h)
    end

    # Priority: explicit pixels (s= / v=) → explicit cells (c= / r=)
    # × cell pixel size → SVG intrinsic → 512² fallback. Capped at
    # 4096 per axis so a runaway `viewBox="0 0 1e6 1e6"` can't ask
    # for gigabyte buffers.
    def svg_target_pixels(opts, screen, bytes)
      cell_w = screen&.cell_pixel_width.to_f
      cell_h = screen&.cell_pixel_height.to_f
      w = svg_explicit_pixels(opts['s'], opts['c'], cell_w)
      h = svg_explicit_pixels(opts['v'], opts['r'], cell_h)
      if w.nil? || h.nil?
        iw, ih = SvgSniffer.intrinsic_size(bytes)
        w ||= iw if iw
        h ||= ih if ih
      end
      w ||= 512
      h ||= 512
      [w.clamp(1, 4096), h.clamp(1, 4096)]
    end

    def svg_explicit_pixels(px_val, cell_val, cell_px)
      if px_val && !px_val.empty? && px_val.to_i > 0
        return px_val.to_i
      end
      if cell_val && !cell_val.empty? && cell_val.to_i > 0 && cell_px > 0
        return (cell_val.to_i * cell_px).round
      end
      nil
    end

    # PNG → {rgba:, width:, height:}. Implemented in
    # kitty_graphics_appkit.rb; loaded lazily so non-GUI tests
    # (which don't link AppKit) still pass.
    def decode_png(bytes)
      load_appkit
      AppKitPng.decode(bytes)
    end

    def load_appkit
      require_relative 'kitty_graphics_appkit'
    end

    def cache_image(state, id, image)
      return if id.empty?
      state[:cache].delete(id)         # touch (LRU)
      state[:cache][id] = image
      state[:cache].shift while state[:cache].size > CACHE_LIMIT
    end

    def display_image(screen, image, opts)
      return unless screen.respond_to?(:put_kitty_image)
      raw_id = opts['i'].to_s
      raw_id = opts['I'].to_s if raw_id.empty?
      screen.put_kitty_image(
        rgba:             image[:rgba],
        width:            image[:width],
        height:           image[:height],
        cells_w:          (opts['c'] && !opts['c'].empty?) ? opts['c'].to_i : nil,
        cells_h:          (opts['r'] && !opts['r'].empty?) ? opts['r'].to_i : nil,
        # Sub-cell pixel offsets for fine alignment. The kitty spec
        # caps these at one cell minus one pixel; we let them
        # through as-is — the renderer clips at the cell rect, so
        # anything larger just gets cropped.
        px_x_offset:      opts['X'].to_i,
        px_y_offset:      opts['Y'].to_i,
        suppress_cursor:  opts['C'] == '1',
        image_id:         raw_id.empty? ? nil : raw_id,
        # z<0 layers the image beneath cell text (the GUI splits the
        # placement blit into pre-cell and post-cell passes by z sign);
        # z>=0 (the spec default of 0 included) layers on top.
        z_index:          opts['z'].to_i,
      )
    end

    # Spec: q=0 verbose, q=1 suppress success, q=2 suppress all.
    # We always carry `i=`/`I=` back so the client can correlate.
    def respond(writer, opts, ok: false, error: nil)
      return unless writer
      quiet = opts['q'].to_s
      return if quiet == '2'
      return if quiet == '1' && ok

      id_part =
        if (id = opts['i']) && !id.empty? then "i=#{id}"
        elsif (n = opts['I']) && !n.empty? then "I=#{n}"
        else ''
        end
      msg = ok ? 'OK' : error.to_s
      writer.call("\e_G#{id_part};#{msg}\e\\")
    rescue StandardError
      # Writing to a closed pty etc. — never let response failure
      # break the pane.
    end
  end
end
