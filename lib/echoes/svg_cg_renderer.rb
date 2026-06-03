# frozen_string_literal: true

require 'fiddle'
require_relative 'objc'
require_relative 'svg_sniffer'
require_relative 'svg_walker'
require_relative 'svg_color'
require_relative 'svg_transform'
require_relative 'svg_path_parser'

module Echoes
  # Native CoreGraphics SVG rasterizer. Tried first by SvgRenderer
  # before falling back to WKWebView. Covers "path-only" SVGs —
  # <path>, basic shapes, <g> with attribute inheritance, transforms
  # — and returns nil for anything outside that subset so the caller
  # bails to WebKit.
  #
  # Wire format: {rgba:, width:, height:} or nil.
  module SvgCgRenderer
    # Tags whose presence forces a bail. Everything else we either
    # render or silently ignore (e.g. <title>, <desc>, <metadata>).
    # Using a Hash for O(1) lookup without requiring `set`.
    BAIL_TAGS = %w[
      text textPath tspan tref
      image foreignObject
      filter mask clipPath
      linearGradient radialGradient pattern
      use symbol defs
      animate animateTransform animateMotion set
      script style
    ].each_with_object({}) { |t, h| h[t] = true }.freeze

    # Tags we know how to draw.
    SHAPE_TAGS = %w[path rect circle ellipse line polygon polyline]
      .each_with_object({}) { |t, h| h[t] = true }.freeze

    # Initial graphics state inherited by the root <svg> element.
    DEFAULT_ATTRS = {
      'fill'             => 'black',
      'stroke'           => 'none',
      'stroke-width'     => '1',
      'fill-rule'        => 'nonzero',
      'stroke-linecap'   => 'butt',
      'stroke-linejoin'  => 'miter',
      'stroke-miterlimit' => '4',
      'opacity'          => '1',
      'fill-opacity'     => '1',
      'stroke-opacity'   => '1',
    }.freeze

    module_function

    # Entry point. Returns {rgba:, width:, height:} or nil.
    def rasterize(svg_bytes, width:, height:)
      return nil if svg_bytes.nil? || svg_bytes.empty?
      return nil if width <= 0 || height <= 0

      events = collect_events(svg_bytes)
      return nil unless events

      root_attrs = find_root_attrs(events)
      return nil unless root_attrs

      buf = Fiddle::Pointer.malloc(width * height * 4, Fiddle::RUBY_FREE)
      cs  = ObjC::CGColorSpaceCreateDeviceRGB.call
      begin
        ctx = ObjC::CGBitmapContextCreate.call(
          buf, width, height, 8, width * 4, cs,
          ObjC::KCGImageAlphaPremultipliedLast,
        )
        return nil if ctx.null?
        begin
          ObjC::CGContextClearRect.call(ctx, 0.0, 0.0, width.to_f, height.to_f)
          setup_root_ctm(ctx, width, height, root_attrs)
          return nil unless render_events(ctx, events)
          rgba = buf.to_str(width * height * 4)
          {rgba: rgba, width: width, height: height}
        ensure
          ObjC::CGContextRelease.call(ctx)
        end
      ensure
        ObjC::CGColorSpaceRelease.call(cs)
      end
    rescue StandardError => e
      warn "echoes SvgCgRenderer: #{e.class}: #{e.message}"
      nil
    end

    # Walk the SVG bytes once into a flat event list. Bails (returns
    # nil) on any blacklisted tag.
    def collect_events(svg_bytes)
      events = []
      SvgWalker.events(svg_bytes) do |kind, tag, attrs|
        if (kind == :open || kind == :self_close) && BAIL_TAGS.include?(tag)
          return nil
        end
        events << [kind, tag, attrs]
      end
      events
    end

    def find_root_attrs(events)
      events.each do |kind, tag, attrs|
        return attrs if (kind == :open || kind == :self_close) && tag == 'svg'
      end
      nil
    end

    # Translate y-flip + viewBox onto the bitmap-context CTM. After
    # this, drawing at SVG coord (x, y) lands at the right pixel —
    # origin top-left, y down, scaled to fit.
    def setup_root_ctm(ctx, width, height, root_attrs)
      # CG is y-up; SVG is y-down. Flip the destination canvas first.
      ObjC::CGContextTranslateCTM.call(ctx, 0.0, height.to_f)
      ObjC::CGContextScaleCTM.call(ctx, 1.0, -1.0)

      vb = parse_viewbox(root_attrs['viewBox'])
      if vb
        vbx, vby, vbw, vbh = vb
        return if vbw <= 0 || vbh <= 0
        ObjC::CGContextScaleCTM.call(ctx, width.to_f / vbw, height.to_f / vbh)
        ObjC::CGContextTranslateCTM.call(ctx, -vbx, -vby)
      else
        # No viewBox — use intrinsic width/height attrs if they parse,
        # else 1:1 (SVG with no sizing was authored at target-pixel units).
        iw = parse_length(root_attrs['width'])
        ih = parse_length(root_attrs['height'])
        if iw && ih && iw.positive? && ih.positive?
          ObjC::CGContextScaleCTM.call(ctx, width.to_f / iw, height.to_f / ih)
        end
      end
    end

    # Numeric SVG length: a number with an optional CSS unit. px / pt /
    # unitless treated as user units; em / % return nil (need layout
    # context we don't have).
    def parse_length(str)
      return nil if str.nil? || str.empty?
      m = /\A\s*([0-9]*\.?[0-9]+)\s*([a-z%]*)\s*\z/i.match(str)
      return nil unless m
      unit = m[2].downcase
      return nil if unit == 'em' || unit == '%'
      n = m[1].to_f
      n.positive? ? n : nil
    end

    def parse_viewbox(str)
      return nil if str.nil? || str.empty?
      parts = str.strip.split(/[\s,]+/).map { |p| Float(p) rescue nil }
      return nil unless parts.size == 4 && parts.none?(&:nil?)
      parts
    end

    # Walk the event list, maintaining a stack of inherited paint
    # attribute hashes. Group elements (`<svg>` / `<g>`) also push a
    # CGState frame so their `transform=` applies to children. Each
    # shape uses its OWN transform locally via SaveGState/Restore.
    #
    # Returns true on full success, false if any shape signaled an
    # unrenderable element (e.g. unparseable path data) — the caller
    # treats that as a bail and falls through to WKWebView.
    def render_events(ctx, events)
      attr_stack    = [DEFAULT_ATTRS]
      gstate_stack  = []   # parallel to opens; entries are :saved or nil
      ok = true
      events.each do |kind, tag, attrs|
        case kind
        when :open
          if tag == 'svg' || tag == 'g'
            ObjC::CGContextSaveGState.call(ctx)
            apply_transform(ctx, attrs['transform'])
            gstate_stack.push(:saved)
            attr_stack.push(merge_attrs(attr_stack.last, attrs))
          else
            gstate_stack.push(nil)
            attr_stack.push(attr_stack.last)
            if SHAPE_TAGS[tag]
              ok &&= draw_shape(ctx, tag, attrs, attr_stack.last)
            end
          end
        when :close
          ObjC::CGContextRestoreGState.call(ctx) if gstate_stack.last == :saved
          gstate_stack.pop
          attr_stack.pop if attr_stack.size > 1
        when :self_close
          if SHAPE_TAGS[tag]
            ok &&= draw_shape(ctx, tag, attrs, attr_stack.last)
          end
        end
        break unless ok
      end
      # Defensive: if input was unbalanced (close missing), restore
      # any GStates we still hold so we don't leak state.
      gstate_stack.count(:saved).times { ObjC::CGContextRestoreGState.call(ctx) }
      ok
    end

    # Effective attrs = inherited + element attrs + style= overrides.
    # Style overrides per CSS specificity ranking.
    def merge_attrs(parent, attrs)
      style = parse_style(attrs['style'])
      parent.merge(attrs).merge(style)
    end

    def parse_style(str)
      return {} if str.nil? || str.empty?
      out = {}
      str.split(';').each do |decl|
        k, v = decl.split(':', 2)
        next unless k && v
        out[k.strip] = v.strip
      end
      out
    end

    # --- shape dispatch ---

    # `inherited` is the merged paint attrs from enclosing <svg>/<g>
    # frames. `attrs` is the element's own attributes (geometry and
    # any element-local paint overrides). The shape's own `transform=`
    # is applied locally so the rest of the path's coordinates aren't
    # affected.
    #
    # Returns true on success, false to bail the whole render (used
    # only when a `<path>` has unparseable `d=` data). Missing /
    # malformed geometry on other shapes silently skips the draw.
    def draw_shape(ctx, tag, attrs, inherited)
      effective = merge_attrs(inherited, attrs)
      ObjC::CGContextSaveGState.call(ctx)
      apply_transform(ctx, attrs['transform'])
      ObjC::CGContextBeginPath.call(ctx)
      built = case tag
              when 'path'     then build_path(ctx, attrs['d'])
              when 'rect'     then build_rect(ctx, attrs)
              when 'circle'   then build_circle(ctx, attrs)
              when 'ellipse'  then build_ellipse(ctx, attrs)
              when 'line'     then build_line(ctx, attrs)
              when 'polygon'  then build_polygon(ctx, attrs, close: true)
              when 'polyline' then build_polygon(ctx, attrs, close: false)
              end
      return false if built.nil?    # bail signal from build_*
      paint(ctx, effective) if built
      true
    ensure
      ObjC::CGContextRestoreGState.call(ctx)
    end

    def apply_transform(ctx, str)
      return if str.nil? || str.empty?
      ops = SvgTransform.parse(str)
      return unless ops
      ops.each do |op, args|
        case op
        when :translate
          ObjC::CGContextTranslateCTM.call(ctx, args[0], args[1])
        when :scale
          ObjC::CGContextScaleCTM.call(ctx, args[0], args[1])
        when :rotate
          # SVG rotates around (cx, cy): translate to cx,cy, rotate,
          # translate back.
          deg, cx, cy = args
          rad = deg * Math::PI / 180.0
          if cx != 0.0 || cy != 0.0
            ObjC::CGContextTranslateCTM.call(ctx, cx, cy)
            ObjC::CGContextRotateCTM.call(ctx, rad)
            ObjC::CGContextTranslateCTM.call(ctx, -cx, -cy)
          else
            ObjC::CGContextRotateCTM.call(ctx, rad)
          end
        when :matrix
          a, b, c, d, e, f = args
          ObjC::CGContextConcatCTM.call(ctx, a, b, c, d, e, f)
        when :skewx
          # skewX(angle) = matrix(1, 0, tan(angle), 1, 0, 0)
          t = Math.tan(args[0] * Math::PI / 180.0)
          ObjC::CGContextConcatCTM.call(ctx, 1.0, 0.0, t, 1.0, 0.0, 0.0)
        when :skewy
          t = Math.tan(args[0] * Math::PI / 180.0)
          ObjC::CGContextConcatCTM.call(ctx, 1.0, t, 0.0, 1.0, 0.0, 0.0)
        end
      end
    end

    # --- basic-shape builders ---

    def build_rect(ctx, attrs)
      x = attr_num(attrs['x'], 0.0)
      y = attr_num(attrs['y'], 0.0)
      w = attr_num(attrs['width'])
      h = attr_num(attrs['height'])
      return false if w.nil? || h.nil? || w <= 0 || h <= 0
      rx = attr_num(attrs['rx'])
      ry = attr_num(attrs['ry'])
      # SVG: missing rx/ry mirror each other; both missing = sharp.
      rx ||= ry
      ry ||= rx
      if rx.nil? || rx <= 0 || ry <= 0
        # Sharp rect.
        ObjC::CGContextMoveToPoint.call(ctx, x, y)
        ObjC::CGContextAddLineToPoint.call(ctx, x + w, y)
        ObjC::CGContextAddLineToPoint.call(ctx, x + w, y + h)
        ObjC::CGContextAddLineToPoint.call(ctx, x, y + h)
        ObjC::CGContextClosePath.call(ctx)
      else
        # Rounded rect via four arcs. Clip radii to half the side.
        rx = [rx, w / 2.0].min
        ry = [ry, h / 2.0].min
        build_rounded_rect(ctx, x, y, w, h, rx, ry)
      end
      true
    end

    def build_rounded_rect(ctx, x, y, w, h, rx, ry)
      # Trace: start at (x+rx, y), go around clockwise (in SVG's
      # y-down sense) emitting straight edges and corner arcs.
      # Each corner arc is approximated as a cubic Bezier with the
      # standard kappa = (4/3)(sqrt(2)-1) ≈ 0.5523 multiplier.
      k = 4.0 / 3.0 * (Math.sqrt(2.0) - 1.0)
      kx = rx * k
      ky = ry * k

      ObjC::CGContextMoveToPoint.call(ctx, x + rx, y)
      ObjC::CGContextAddLineToPoint.call(ctx, x + w - rx, y)
      ObjC::CGContextAddCurveToPoint.call(ctx,
        x + w - rx + kx, y,    x + w, y + ry - ky,   x + w, y + ry)
      ObjC::CGContextAddLineToPoint.call(ctx, x + w, y + h - ry)
      ObjC::CGContextAddCurveToPoint.call(ctx,
        x + w, y + h - ry + ky,  x + w - rx + kx, y + h,  x + w - rx, y + h)
      ObjC::CGContextAddLineToPoint.call(ctx, x + rx, y + h)
      ObjC::CGContextAddCurveToPoint.call(ctx,
        x + rx - kx, y + h,  x, y + h - ry + ky,  x, y + h - ry)
      ObjC::CGContextAddLineToPoint.call(ctx, x, y + ry)
      ObjC::CGContextAddCurveToPoint.call(ctx,
        x, y + ry - ky,  x + rx - kx, y,  x + rx, y)
      ObjC::CGContextClosePath.call(ctx)
    end

    def build_circle(ctx, attrs)
      cx = attr_num(attrs['cx'], 0.0)
      cy = attr_num(attrs['cy'], 0.0)
      r  = attr_num(attrs['r'])
      return false if r.nil? || r <= 0
      ObjC::CGContextAddArc.call(ctx, cx, cy, r, 0.0, 2.0 * Math::PI, 0)
      ObjC::CGContextClosePath.call(ctx)
      true
    end

    def build_ellipse(ctx, attrs)
      cx = attr_num(attrs['cx'], 0.0)
      cy = attr_num(attrs['cy'], 0.0)
      rx = attr_num(attrs['rx'])
      ry = attr_num(attrs['ry'])
      return false if rx.nil? || ry.nil? || rx <= 0 || ry <= 0
      # Build a unit circle scaled into an ellipse via cubic Beziers
      # (avoids CTM games that would distort other path elements).
      ellipse_path(ctx, cx, cy, rx, ry)
      true
    end

    def ellipse_path(ctx, cx, cy, rx, ry)
      k = 4.0 / 3.0 * (Math.sqrt(2.0) - 1.0)
      kx = rx * k
      ky = ry * k
      ObjC::CGContextMoveToPoint.call(ctx, cx + rx, cy)
      ObjC::CGContextAddCurveToPoint.call(ctx,
        cx + rx, cy + ky,  cx + kx, cy + ry,  cx, cy + ry)
      ObjC::CGContextAddCurveToPoint.call(ctx,
        cx - kx, cy + ry,  cx - rx, cy + ky,  cx - rx, cy)
      ObjC::CGContextAddCurveToPoint.call(ctx,
        cx - rx, cy - ky,  cx - kx, cy - ry,  cx, cy - ry)
      ObjC::CGContextAddCurveToPoint.call(ctx,
        cx + kx, cy - ry,  cx + rx, cy - ky,  cx + rx, cy)
      ObjC::CGContextClosePath.call(ctx)
    end

    def build_line(ctx, attrs)
      x1 = attr_num(attrs['x1'], 0.0)
      y1 = attr_num(attrs['y1'], 0.0)
      x2 = attr_num(attrs['x2'], 0.0)
      y2 = attr_num(attrs['y2'], 0.0)
      ObjC::CGContextMoveToPoint.call(ctx, x1, y1)
      ObjC::CGContextAddLineToPoint.call(ctx, x2, y2)
      true
    end

    def build_polygon(ctx, attrs, close:)
      pts = parse_points(attrs['points'])
      return false unless pts && pts.size >= 2
      x, y = pts.shift
      ObjC::CGContextMoveToPoint.call(ctx, x, y)
      pts.each { |px, py| ObjC::CGContextAddLineToPoint.call(ctx, px, py) }
      ObjC::CGContextClosePath.call(ctx) if close
      true
    end

    def parse_points(str)
      return nil if str.nil? || str.strip.empty?
      flat = str.scan(/-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/).map(&:to_f)
      return nil if flat.empty? || flat.size.odd?
      flat.each_slice(2).to_a
    end

    # --- path data ---

    def build_path(ctx, d)
      return true if d.nil? || d.empty?   # empty path is valid, no-op
      ops = SvgPathParser.parse(d)
      return nil unless ops                 # nil = bail signal

      cur_x = 0.0
      cur_y = 0.0
      start_x = 0.0
      start_y = 0.0
      last_cubic = nil   # [cp2x, cp2y] for S reflection
      last_quad  = nil   # [cpx, cpy]   for T reflection

      ops.each do |cmd, args|
        abs = cmd.to_s.match?(/[A-Z]/)
        case cmd
        when :M, :m
          x, y = args
          if abs
            cur_x, cur_y = x, y
          else
            cur_x += x; cur_y += y
          end
          start_x, start_y = cur_x, cur_y
          ObjC::CGContextMoveToPoint.call(ctx, cur_x, cur_y)
          last_cubic = nil; last_quad = nil
        when :L, :l
          x, y = args
          if abs
            cur_x, cur_y = x, y
          else
            cur_x += x; cur_y += y
          end
          ObjC::CGContextAddLineToPoint.call(ctx, cur_x, cur_y)
          last_cubic = nil; last_quad = nil
        when :H, :h
          x = args[0]
          cur_x = abs ? x : cur_x + x
          ObjC::CGContextAddLineToPoint.call(ctx, cur_x, cur_y)
          last_cubic = nil; last_quad = nil
        when :V, :v
          y = args[0]
          cur_y = abs ? y : cur_y + y
          ObjC::CGContextAddLineToPoint.call(ctx, cur_x, cur_y)
          last_cubic = nil; last_quad = nil
        when :C, :c
          c1x, c1y, c2x, c2y, x, y = args
          unless abs
            c1x += cur_x; c1y += cur_y
            c2x += cur_x; c2y += cur_y
            x   += cur_x; y   += cur_y
          end
          ObjC::CGContextAddCurveToPoint.call(ctx, c1x, c1y, c2x, c2y, x, y)
          cur_x, cur_y = x, y
          last_cubic = [c2x, c2y]; last_quad = nil
        when :S, :s
          c2x, c2y, x, y = args
          unless abs
            c2x += cur_x; c2y += cur_y
            x   += cur_x; y   += cur_y
          end
          c1x, c1y = if last_cubic
                       [2 * cur_x - last_cubic[0], 2 * cur_y - last_cubic[1]]
                     else
                       [cur_x, cur_y]
                     end
          ObjC::CGContextAddCurveToPoint.call(ctx, c1x, c1y, c2x, c2y, x, y)
          cur_x, cur_y = x, y
          last_cubic = [c2x, c2y]; last_quad = nil
        when :Q, :q
          cpx, cpy, x, y = args
          unless abs
            cpx += cur_x; cpy += cur_y
            x   += cur_x; y   += cur_y
          end
          ObjC::CGContextAddQuadCurveToPoint.call(ctx, cpx, cpy, x, y)
          cur_x, cur_y = x, y
          last_quad = [cpx, cpy]; last_cubic = nil
        when :T, :t
          x, y = args
          unless abs
            x += cur_x; y += cur_y
          end
          cpx, cpy = if last_quad
                       [2 * cur_x - last_quad[0], 2 * cur_y - last_quad[1]]
                     else
                       [cur_x, cur_y]
                     end
          ObjC::CGContextAddQuadCurveToPoint.call(ctx, cpx, cpy, x, y)
          cur_x, cur_y = x, y
          last_quad = [cpx, cpy]; last_cubic = nil
        when :A, :a
          rx, ry, phi_deg, fa, fs, x, y = args
          unless abs
            x += cur_x; y += cur_y
          end
          arc_to_beziers(ctx, cur_x, cur_y, rx, ry, phi_deg, fa.to_i, fs.to_i, x, y)
          cur_x, cur_y = x, y
          last_cubic = nil; last_quad = nil
        when :Z, :z
          ObjC::CGContextClosePath.call(ctx)
          cur_x, cur_y = start_x, start_y
          last_cubic = nil; last_quad = nil
        end
      end
      true
    end

    # SVG endpoint-arc → cubic-Bezier segments in user space (no CTM
    # tricks, so we don't disturb path coordinates emitted by other
    # commands). Per SVG 1.1 appendix F.6.5 + the standard Bezier
    # approximation for circular arcs.
    def arc_to_beziers(ctx, x1, y1, rx, ry, phi_deg, fa, fs, x2, y2)
      # Degenerate cases: zero radius or coincident endpoints → line.
      if rx.abs < 1e-9 || ry.abs < 1e-9 || (x1 == x2 && y1 == y2)
        ObjC::CGContextAddLineToPoint.call(ctx, x2, y2)
        return
      end
      rx = rx.abs
      ry = ry.abs
      phi = phi_deg * Math::PI / 180.0
      cos_phi = Math.cos(phi)
      sin_phi = Math.sin(phi)

      # Step 1: midpoint transform.
      dx = (x1 - x2) / 2.0
      dy = (y1 - y2) / 2.0
      x1p =  cos_phi * dx + sin_phi * dy
      y1p = -sin_phi * dx + cos_phi * dy

      # Step 2: ensure radii are big enough; otherwise scale them up.
      lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
      if lambda > 1
        s = Math.sqrt(lambda)
        rx *= s
        ry *= s
      end

      # Step 3: compute center in the rotated frame.
      sign = (fa == fs ? -1 : 1)
      num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
      den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
      coef = sign * Math.sqrt([num / den, 0.0].max)
      cxp =  coef * (rx * y1p) / ry
      cyp = -coef * (ry * x1p) / rx

      # Step 4: rotate back + translate to actual center.
      cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2.0
      cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2.0

      # Step 5: angles.
      theta1 = angle_between(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
      delta_raw = angle_between((x1p - cxp) / rx, (y1p - cyp) / ry,
                                 (-x1p - cxp) / rx, (-y1p - cyp) / ry)
      delta = delta_raw
      if fs == 0 && delta > 0
        delta -= 2 * Math::PI
      elsif fs == 1 && delta < 0
        delta += 2 * Math::PI
      end

      # Step 6: split the sweep into ≤ 90° pieces and emit cubics.
      segments = (delta.abs / (Math::PI / 2.0)).ceil
      segments = 1 if segments < 1
      seg_delta = delta / segments
      t = 4.0 / 3.0 * Math.tan(seg_delta / 4.0)

      cur_theta = theta1
      segments.times do
        a1 = cur_theta
        a2 = cur_theta + seg_delta
        cos_a1 = Math.cos(a1); sin_a1 = Math.sin(a1)
        cos_a2 = Math.cos(a2); sin_a2 = Math.sin(a2)

        # Control points on the unit ellipse.
        p1x = cos_a1 - t * sin_a1
        p1y = sin_a1 + t * cos_a1
        p2x = cos_a2 + t * sin_a2
        p2y = sin_a2 - t * cos_a2
        p3x = cos_a2
        p3y = sin_a2

        # Transform: scale by (rx, ry), rotate by phi, translate by (cx, cy).
        c1x, c1y = ellipse_xform(p1x, p1y, rx, ry, cos_phi, sin_phi, cx, cy)
        c2x, c2y = ellipse_xform(p2x, p2y, rx, ry, cos_phi, sin_phi, cx, cy)
        ex,  ey  = ellipse_xform(p3x, p3y, rx, ry, cos_phi, sin_phi, cx, cy)

        ObjC::CGContextAddCurveToPoint.call(ctx, c1x, c1y, c2x, c2y, ex, ey)
        cur_theta = a2
      end
    end

    def ellipse_xform(px, py, rx, ry, cos_phi, sin_phi, cx, cy)
      sx = px * rx
      sy = py * ry
      [cos_phi * sx - sin_phi * sy + cx,
       sin_phi * sx + cos_phi * sy + cy]
    end

    # Signed angle from vector (ux, uy) to (vx, vy), in radians.
    def angle_between(ux, uy, vx, vy)
      dot = ux * vx + uy * vy
      mag = Math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
      c = (dot / mag).clamp(-1.0, 1.0)
      a = Math.acos(c)
      (ux * vy - uy * vx) < 0 ? -a : a
    end

    # --- paint ---

    def paint(ctx, attrs)
      cur_color = SvgColor.parse(attrs['color']) || [0.0, 0.0, 0.0, 1.0]
      cur_color = [0.0, 0.0, 0.0, 1.0] if cur_color == :none

      fill   = SvgColor.parse(attrs['fill'],   current_color: cur_color)
      stroke = SvgColor.parse(attrs['stroke'], current_color: cur_color)
      sw     = parse_float(attrs['stroke-width'], 1.0)
      sw     = 0.0 if sw < 0.0
      sw     = nil if stroke == :none
      f_op   = parse_opacity(attrs['fill-opacity'])
      s_op   = parse_opacity(attrs['stroke-opacity'])
      o      = parse_opacity(attrs['opacity'])
      fill_rule = (attrs['fill-rule'] == 'evenodd') ? :evenodd : :nonzero

      apply_line_attrs(ctx, attrs, sw)

      if !fill.nil? && fill != :none
        r, g, b, a = fill
        ObjC::CGContextSetRGBFillColor.call(ctx, r, g, b, a * f_op * o)
      end
      if !stroke.nil? && stroke != :none && sw && sw > 0
        r, g, b, a = stroke
        ObjC::CGContextSetRGBStrokeColor.call(ctx, r, g, b, a * s_op * o)
      end

      do_fill   = !fill.nil?   && fill   != :none
      do_stroke = !stroke.nil? && stroke != :none && sw && sw > 0

      mode = if do_fill && do_stroke
               fill_rule == :evenodd ? ObjC::KCG_PATH_EO_FILL_STROKE : ObjC::KCG_PATH_FILL_STROKE
             elsif do_fill
               fill_rule == :evenodd ? ObjC::KCG_PATH_EO_FILL : ObjC::KCG_PATH_FILL
             elsif do_stroke
               ObjC::KCG_PATH_STROKE
             else
               return
             end
      ObjC::CGContextDrawPath.call(ctx, mode)
    end

    def apply_line_attrs(ctx, attrs, sw)
      ObjC::CGContextSetLineWidth.call(ctx, sw) if sw && sw > 0
      case attrs['stroke-linecap']
      when 'round'  then ObjC::CGContextSetLineCap.call(ctx, ObjC::KCG_LINE_CAP_ROUND)
      when 'square' then ObjC::CGContextSetLineCap.call(ctx, ObjC::KCG_LINE_CAP_SQUARE)
      when 'butt'   then ObjC::CGContextSetLineCap.call(ctx, ObjC::KCG_LINE_CAP_BUTT)
      end
      case attrs['stroke-linejoin']
      when 'round' then ObjC::CGContextSetLineJoin.call(ctx, ObjC::KCG_LINE_JOIN_ROUND)
      when 'bevel' then ObjC::CGContextSetLineJoin.call(ctx, ObjC::KCG_LINE_JOIN_BEVEL)
      when 'miter' then ObjC::CGContextSetLineJoin.call(ctx, ObjC::KCG_LINE_JOIN_MITER)
      end
      if (ml = parse_float(attrs['stroke-miterlimit'], nil))
        ObjC::CGContextSetMiterLimit.call(ctx, ml) if ml > 0
      end
    end

    def parse_opacity(str)
      return 1.0 if str.nil? || str.empty?
      f = Float(str) rescue nil
      f.nil? ? 1.0 : f.clamp(0.0, 1.0)
    end

    def parse_float(str, default)
      return default if str.nil? || str.empty?
      f = Float(str) rescue nil
      f.nil? ? default : f
    end

    def attr_num(str, default = nil)
      return default if str.nil? || str.empty?
      f = Float(str) rescue nil
      f.nil? ? default : f
    end
  end
end
