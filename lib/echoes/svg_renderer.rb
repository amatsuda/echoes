# frozen_string_literal: true

require 'fiddle'
require_relative 'objc'
require_relative 'kitty_graphics_appkit'

module Echoes
  # SVG → RGBA8 rasterizer backed by WKWebView. The Kitty graphics
  # and iTerm2 inline-image protocols both detect SVG payloads via
  # SvgSniffer and route here instead of NSBitmapImageRep (which
  # can't decode vector formats).
  #
  # WebKit's snapshot API is async, but the decoders are synchronous.
  # We bridge by pumping a nested NSRunLoop until the completion
  # handler fires, with a hard per-call timeout so a runaway SVG
  # can't hang the GUI. Re-entrant calls during the pump are
  # short-circuited by a recursion guard.
  #
  # JavaScript is disabled and baseURL is nil so the SVG sandbox
  # can't execute scripts or fetch external resources.
  module SvgRenderer
    WEBKIT     = Fiddle.dlopen('/System/Library/Frameworks/WebKit.framework/WebKit')
    LIBSYSTEM  = Fiddle.dlopen('/usr/lib/libSystem.B.dylib')
    COREGRAPHICS = Fiddle.dlopen('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')

    P = ObjC::P
    D = ObjC::D
    L = ObjC::L
    I = ObjC::I
    V = ObjC::V

    # `initWithFrame:configuration:` — CGRect (4 doubles) + id.
    MSG_PTR_RECT_1 = ObjC.new_msg([P, P, D, D, D, D, P], P)

    # CG functions for snapshot pixel-dim lookup.
    CGImageGetWidth  = Fiddle::Function.new(COREGRAPHICS['CGImageGetWidth'],  [P], L)
    CGImageGetHeight = Fiddle::Function.new(COREGRAPHICS['CGImageGetHeight'], [P], L)

    # Foundation exports NSDefaultRunLoopMode as an NSString* symbol.
    # Same dereference-the-symbol trick as ObjC.appkit_const, just
    # against Foundation instead of AppKit.
    NS_DEFAULT_RUN_LOOP_MODE = begin
      sym_ptr = Fiddle::Pointer.new(ObjC::FOUNDATION['NSDefaultRunLoopMode'])
      Fiddle::Pointer.new(sym_ptr[0, Fiddle::SIZEOF_VOIDP].unpack1('J'))
    end

    # Objective-C global block plumbing. Snapshot's completion handler
    # is `void (^)(NSImage *, NSError *)`, which we fabricate via Fiddle
    # by building a Block_layout struct that points at a Fiddle closure.
    # Global blocks live forever and never copy/dispose, so the layout
    # is minimal.
    NS_CONCRETE_GLOBAL_BLOCK = Fiddle::Pointer.new(LIBSYSTEM['_NSConcreteGlobalBlock'])
    BLOCK_HAS_STRET = 1 << 29     # not set
    BLOCK_HAS_SIGNATURE = 1 << 30 # not set; we omit the type signature
    BLOCK_IS_GLOBAL = 1 << 28

    @rendering = false
    @web_view = nil
    @configuration = nil
    @delegate_class = nil
    @delegate_instance = nil

    # Snapshot completion handler state, captured by the global block's
    # invoke closure. Per-call values are stashed in instance variables
    # because the block can only carry a stable function pointer.
    @snap_image = nil
    @snap_error = false
    @snap_done = false
    @nav_done = false
    @nav_error = false

    # Build the global block once at module load. The same block is
    # passed to every takeSnapshotWithConfiguration: call; the per-call
    # result is read back through module state.
    @snap_invoke_closure = Fiddle::Closure::BlockCaller.new(
      V, [P, P, P]
    ) do |_block, image_ptr, error_ptr|
      @snap_image = image_ptr.null? ? nil : image_ptr
      @snap_error = !error_ptr.null?
      @snap_done = true
    end

    @snap_block_descriptor = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
    @snap_block_descriptor[0, 8]  = [0].pack('Q')   # reserved
    @snap_block_descriptor[8, 8]  = [32].pack('Q')  # sizeof(Block_layout)

    @snap_block = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
    @snap_block[0, 8]  = [NS_CONCRETE_GLOBAL_BLOCK.to_i].pack('Q')
    @snap_block[8, 4]  = [BLOCK_IS_GLOBAL].pack('l')
    @snap_block[12, 4] = [0].pack('l')
    @snap_block[16, 8] = [@snap_invoke_closure.to_i].pack('Q')
    @snap_block[24, 8] = [@snap_block_descriptor.to_i].pack('Q')

    class << self
      # Returns {rgba:, width:, height:} or nil. `width` and `height`
      # are the target pixel dimensions for the rasterized output;
      # the renderer respects them via the WKWebView frame, but the
      # final pixel count may exceed them on Retina displays (we use
      # whatever the snapshot reports back).
      #
      # Tries the native CoreGraphics renderer first (fast, synchronous,
      # no WebContent XPC process); falls back to WKWebView when the
      # SVG uses anything outside that subset (text, filters, gradients,
      # etc.) — see SvgCgRenderer for the precise contract.
      def rasterize(svg_bytes, width:, height:)
        return nil if svg_bytes.nil? || svg_bytes.empty?
        return nil if width <= 0 || height <= 0
        return nil if @rendering   # recursion guard — nested runloop can re-enter
        @rendering = true

        begin
          require_relative 'svg_cg_renderer'
          fast = SvgCgRenderer.rasterize(svg_bytes, width: width, height: height)
          return fast if fast

          ensure_setup
          html = build_html(svg_bytes)

          ObjC::MSG_VOID_2D.call(@web_view, ObjC.sel('setFrameSize:'),
                                 width.to_f, height.to_f)

          @nav_done = false
          @nav_error = false
          @snap_done = false
          @snap_error = false
          @snap_image = nil

          ObjC::MSG_VOID_2.call(@web_view, ObjC.sel('loadHTMLString:baseURL:'),
                                ObjC.nsstring(html), Fiddle::Pointer.new(0))

          return nil unless pump_until(2.0) { @nav_done }
          return nil if @nav_error

          snap_config = build_snapshot_config(width, height)
          ObjC::MSG_VOID_2.call(@web_view,
                                ObjC.sel('takeSnapshotWithConfiguration:completionHandler:'),
                                snap_config, @snap_block)

          return nil unless pump_until(2.0) { @snap_done }
          return nil if @snap_error || @snap_image.nil?

          cgimage = ns_image_to_cgimage(@snap_image, width, height)
          return nil if cgimage.nil? || cgimage.null?

          w_px = CGImageGetWidth.call(cgimage)
          h_px = CGImageGetHeight.call(cgimage)
          return nil if w_px <= 0 || h_px <= 0

          KittyGraphics::AppKitPng.cgimage_to_rgba(cgimage, w_px, h_px)
        rescue StandardError => e
          warn "echoes SvgRenderer: #{e.class}: #{e.message}"
          nil
        ensure
          @rendering = false
        end
      end

      private

      def ensure_setup
        return if @web_view
        @configuration = ObjC::MSG_PTR.call(ObjC.cls('WKWebViewConfiguration'),
                                             ObjC.sel('alloc'))
        @configuration = ObjC::MSG_PTR.call(@configuration, ObjC.sel('init'))
        ObjC.retain(@configuration)

        prefs = ObjC::MSG_PTR.call(@configuration, ObjC.sel('preferences'))
        ObjC::MSG_VOID_I.call(prefs, ObjC.sel('setJavaScriptEnabled:'), 0)

        # macOS 11+ moved JS control to defaultWebpagePreferences; set
        # both for forward/backward compatibility. The selector is a
        # no-op on older systems (NSObject swallows it via msgSend),
        # so the old setJavaScriptEnabled: is the actual guarantee.
        wpp_sel = ObjC.sel('defaultWebpagePreferences')
        if ObjC::MSG_RET_L.call(@configuration, ObjC.sel('respondsToSelector:'),
                                wpp_sel) != 0
          wpp = ObjC::MSG_PTR.call(@configuration, wpp_sel)
          unless wpp.null?
            ObjC::MSG_VOID_I.call(wpp, ObjC.sel('setAllowsContentJavaScript:'), 0)
            ObjC::MSG_VOID_1.call(@configuration,
                                   ObjC.sel('setDefaultWebpagePreferences:'), wpp)
          end
        end

        @delegate_class = build_delegate_class
        @delegate_instance = ObjC::MSG_PTR.call(@delegate_class, ObjC.sel('alloc'))
        @delegate_instance = ObjC::MSG_PTR.call(@delegate_instance, ObjC.sel('init'))
        ObjC.retain(@delegate_instance)

        @web_view = ObjC::MSG_PTR.call(ObjC.cls('WKWebView'), ObjC.sel('alloc'))
        @web_view = MSG_PTR_RECT_1.call(@web_view,
                                         ObjC.sel('initWithFrame:configuration:'),
                                         0.0, 0.0, 1.0, 1.0, @configuration)
        ObjC.retain(@web_view)
        ObjC::MSG_VOID_1.call(@web_view, ObjC.sel('setNavigationDelegate:'),
                              @delegate_instance)
      end

      def build_delegate_class
        finish = Fiddle::Closure::BlockCaller.new(V, [P, P, P, P]) do |_s, _c, _wv, _nav|
          @nav_done = true
        end
        fail_nav = Fiddle::Closure::BlockCaller.new(V, [P, P, P, P, P]) do |_s, _c, _wv, _nav, _err|
          @nav_done = true
          @nav_error = true
        end
        fail_prov = Fiddle::Closure::BlockCaller.new(V, [P, P, P, P, P]) do |_s, _c, _wv, _nav, _err|
          @nav_done = true
          @nav_error = true
        end
        # Hold strong refs so Fiddle doesn't GC the closure thunks.
        @delegate_closures = [finish, fail_nav, fail_prov]

        ObjC.define_class('EchoesSvgNavDelegate', 'NSObject', {
          'webView:didFinishNavigation:' => ['v@:@@', finish],
          'webView:didFailNavigation:withError:' => ['v@:@@@', fail_nav],
          'webView:didFailProvisionalNavigation:withError:' => ['v@:@@@', fail_prov],
        })
      end

      def build_snapshot_config(width, height)
        cfg = ObjC::MSG_PTR.call(ObjC.cls('WKSnapshotConfiguration'), ObjC.sel('alloc'))
        cfg = ObjC::MSG_PTR.call(cfg, ObjC.sel('init'))
        # Default rect = view bounds; default snapshotWidth = view width.
        # We just leave both at defaults so the snapshot matches the
        # frame we set on the web view.
        cfg
      end

      def build_html(svg_bytes)
        svg = svg_bytes.dup.force_encoding(Encoding::UTF_8)
        # Replace invalid byte sequences so a malformed SVG doesn't
        # crash NSString creation.
        svg = svg.scrub('')
        <<~HTML
          <!doctype html>
          <html><head><style>
          html, body { margin: 0; padding: 0; background: transparent; width: 100%; height: 100%; overflow: hidden; }
          svg { display: block; width: 100%; height: 100%; }
          </style></head><body>#{svg}</body></html>
        HTML
      end

      def ns_image_to_cgimage(ns_image, width, height)
        rect_buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
        rect_buf[0, 32] = [0.0, 0.0, width.to_f, height.to_f].pack('d4')
        ObjC::MSG_PTR_3.call(ns_image,
                              ObjC.sel('CGImageForProposedRect:context:hints:'),
                              rect_buf, Fiddle::Pointer.new(0), Fiddle::Pointer.new(0))
      end

      # Pump the main run loop briefly until the block returns true or
      # the deadline expires. Returns true if the condition was met,
      # false on timeout. Uses 50 ms slices so the runloop stays
      # responsive to other events (timer ticks, IO callbacks) while
      # we wait.
      def pump_until(timeout_s)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
        rl = ObjC::MSG_PTR.call(ObjC.cls('NSRunLoop'), ObjC.sel('currentRunLoop'))
        until yield
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          date = ObjC::MSG_PTR_D.call(ObjC.cls('NSDate'),
                                       ObjC.sel('dateWithTimeIntervalSinceNow:'),
                                       0.05)
          ObjC::MSG_VOID_2.call(rl, ObjC.sel('runMode:beforeDate:'),
                                 NS_DEFAULT_RUN_LOOP_MODE, date)
        end
        true
      end
    end
  end
end
