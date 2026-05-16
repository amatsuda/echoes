# frozen_string_literal: true

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
    CACHE_LIMIT       = 16   # most-recent N images, LRU
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

        image = decode_image(bytes, opts['f'] || DEFAULT_FORMAT, opts)
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
        id = opts['i'] || opts['I']
        if id && state[:cache].delete(id)
          respond(writer, opts, ok: true)
        end
      end
    end

    # Tolerant base64 decode: strips whitespace (some clients
    # line-wrap APC payloads) and returns nil on invalid input.
    # Avoids `require 'base64'` (no longer in default gems on
    # Ruby 3.4+) by going through `String#unpack1('m0')`.
    def decode_payload(b64)
      cleaned = b64.to_s.delete("\r\n\t ")
      return ''.b if cleaned.empty?
      out = cleaned.unpack1('m0')
      out
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
    #   f=100 / unset — PNG (and anything else NSBitmapImageRep
    #                   eats: JPEG, GIF, TIFF, BMP)
    #   f=24          — raw RGB packed, dims from s= / v=
    #   f=32          — raw RGBA packed, dims from s= / v=
    def decode_image(bytes, format, opts = {})
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
      screen.put_kitty_image(
        rgba:             image[:rgba],
        width:            image[:width],
        height:           image[:height],
        cells_w:          (opts['c'] && !opts['c'].empty?) ? opts['c'].to_i : nil,
        cells_h:          (opts['r'] && !opts['r'].empty?) ? opts['r'].to_i : nil,
        suppress_cursor:  opts['C'] == '1',
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
