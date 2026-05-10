# frozen_string_literal: true

require 'fiddle'
require_relative 'objc'

module Echoes
  module KittyGraphics
    # AppKit + CoreGraphics-backed PNG decoder, isolated in its own
    # file so headless tests don't pull CoreGraphics into the
    # process. Decoding takes raw PNG bytes through
    # NSBitmapImageRep → CGImage → CGBitmapContext (RGBA8 layout we
    # control), then reads the bitmap context's backing buffer as a
    # Ruby string. Format conversion (palette PNG, 16-bit, etc.) is
    # handled inside CoreGraphics so we always get RGBA8 out.
    module AppKitPng
      CG = Fiddle.dlopen('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')

      P = ObjC::P
      D = ObjC::D
      L = ObjC::L
      I = ObjC::I
      V = ObjC::V

      ColorSpaceCreateDeviceRGB = Fiddle::Function.new(
        CG['CGColorSpaceCreateDeviceRGB'], [], P
      )
      ColorSpaceRelease = Fiddle::Function.new(
        CG['CGColorSpaceRelease'], [P], V
      )
      # CGBitmapContextCreate(data, w, h, bitsPerComp, bytesPerRow, cs, bitmapInfo)
      BitmapContextCreate = Fiddle::Function.new(
        CG['CGBitmapContextCreate'], [P, L, L, L, L, P, I], P
      )
      # CGContextDrawImage(ctx, rect, image) — CGRect inlined as 4 doubles
      ContextDrawImage = Fiddle::Function.new(
        CG['CGContextDrawImage'], [P, D, D, D, D, P], V
      )
      ContextRelease = Fiddle::Function.new(
        CG['CGContextRelease'], [P], V
      )

      # kCGImageAlphaPremultipliedLast (RGBA byte order, alpha last)
      ALPHA_PREMULTIPLIED_LAST = 1

      module_function

      def decode(bytes)
        return nil if bytes.nil? || bytes.bytesize.zero?

        ns_data = ObjC::MSG_PTR_1L.call(
          ObjC.cls('NSData'), ObjC.sel('dataWithBytes:length:'),
          Fiddle::Pointer[bytes], bytes.bytesize
        )
        return nil if ns_data.null?

        rep = ObjC::MSG_PTR_1.call(
          ObjC.cls('NSBitmapImageRep'),
          ObjC.sel('imageRepWithData:'),
          ns_data
        )
        return nil if rep.null?

        width  = ObjC::MSG_RET_L.call(rep, ObjC.sel('pixelsWide'))
        height = ObjC::MSG_RET_L.call(rep, ObjC.sel('pixelsHigh'))
        return nil if width <= 0 || height <= 0

        cgimage = ObjC::MSG_PTR.call(rep, ObjC.sel('CGImage'))
        return nil if cgimage.null?

        bytes_per_row = width * 4
        buf = Fiddle::Pointer.malloc(width * height * 4, Fiddle::RUBY_FREE)
        cs  = ColorSpaceCreateDeviceRGB.call
        begin
          ctx = BitmapContextCreate.call(
            buf, width, height, 8, bytes_per_row, cs,
            ALPHA_PREMULTIPLIED_LAST
          )
          return nil if ctx.null?
          begin
            # CoreGraphics' coordinate system has y up; PNGs decode
            # top-down. The renderer expects pixel row 0 at the top,
            # which matches CGContextDrawImage's natural output here
            # because the bitmap context we created has the same
            # orientation we'll later read from.
            ContextDrawImage.call(ctx, 0.0, 0.0, width.to_f, height.to_f, cgimage)
            rgba = buf.to_str(width * height * 4)
            {rgba: rgba, width: width, height: height}
          ensure
            ContextRelease.call(ctx)
          end
        ensure
          ColorSpaceRelease.call(cs)
        end
      end
    end
  end
end
