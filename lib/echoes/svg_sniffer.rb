# frozen_string_literal: true

module Echoes
  # Detect SVG payloads in arbitrary image bytes. Used by the Kitty
  # graphics and iTerm2 inline-image decoders to fork off to the
  # SvgRenderer instead of NSBitmapImageRep (which is raster-only).
  module SvgSniffer
    # Skip optional UTF-8 BOM, whitespace, an XML prologue, and a
    # DOCTYPE before the `<svg` element. Case-insensitive so `<SVG`
    # and `<Svg` both match. `n` flag forces ASCII-8BIT so we can
    # match against the binary payloads the decoders hand us.
    SVG_RE = /\A(?:\xEF\xBB\xBF)?\s*(?:<\?xml[^>]*\?>\s*)?(?:<!DOCTYPE\s+svg[^>]*>\s*)?<svg\b/imn

    # Capture the leading `<svg ...>` opening tag so intrinsic_size can
    # work on just the attribute soup, ignoring the rest of the document.
    OPEN_SVG_RE = /<svg\b([^>]*)>/imn

    # Numeric attribute on the SVG root, optionally suffixed with a CSS
    # length unit. We extract the number; unit conversion is best-effort
    # (px / pt / unitless treated as pixels; em / % yield nil because
    # they need layout context we don't have).
    DIM_RE = /\A\s*([0-9]*\.?[0-9]+)\s*([a-z%]*)\s*\z/i

    module_function

    def svg?(bytes)
      return false if bytes.nil? || bytes.empty?
      head = bytes.byteslice(0, 4096).b
      SVG_RE.match?(head)
    end

    # Returns [width_px, height_px] or nil. Parses the <svg> tag's
    # width/height attributes first; falls back to viewBox dimensions
    # if either is missing or non-pixel.
    def intrinsic_size(bytes)
      return nil if bytes.nil? || bytes.empty?
      head = bytes.byteslice(0, 4096).b
      m = OPEN_SVG_RE.match(head)
      return nil unless m
      attrs = m[1].to_s

      w = parse_dim(extract_attr(attrs, 'width'))
      h = parse_dim(extract_attr(attrs, 'height'))

      if w.nil? || h.nil?
        vb = extract_attr(attrs, 'viewBox')
        if vb
          parts = vb.strip.split(/[\s,]+/)
          if parts.size == 4
            vw = parts[2].to_f
            vh = parts[3].to_f
            w ||= vw if vw.positive?
            h ||= vh if vh.positive?
          end
        end
      end

      return nil unless w && h && w.positive? && h.positive?
      [w.round, h.round]
    end

    def extract_attr(attrs, name)
      m = attrs.match(/\s#{name}\s*=\s*["']([^"']*)["']/i)
      m && m[1]
    end

    def parse_dim(str)
      return nil if str.nil? || str.empty?
      m = DIM_RE.match(str)
      return nil unless m
      unit = m[2].downcase
      # Unitless / px / pt are treated as pixels (pt is technically
      # 1.333px but the difference is invisible at typical SVG sizes
      # and we'd be guessing the renderer's DPI anyway). em / % need
      # layout context, so we punt.
      return nil if unit == 'em' || unit == '%'
      n = m[1].to_f
      n.positive? ? n : nil
    end
  end
end
