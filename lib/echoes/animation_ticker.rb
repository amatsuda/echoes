# frozen_string_literal: true

module Echoes
  # Pure-state helpers for advancing an animated image's current
  # frame on the GUI timer. The actual NSBitmapImageRep / CGImage
  # round-trip lives in gui.rb; this module just owns the math so
  # it stays testable without standing up AppKit.
  module AnimationTicker
    module_function

    # Returns true when the time elapsed since the last frame
    # advance is at least the current frame's duration. Both args
    # are seconds (CLOCK_MONOTONIC for elapsed; per-frame duration
    # read once at decode time).
    #
    # Non-positive duration → false. We never advance on a
    # zero/negative duration because some pathological GIFs report
    # 0 ms per frame and we'd spin the redraw loop at 60 Hz for
    # no benefit. The decoder normalizes such inputs to a sane
    # minimum before storing, but defending here keeps the helper
    # safe to call without trusting upstream sanitization.
    def should_advance?(elapsed_s, frame_duration_s)
      return false if frame_duration_s.nil? || frame_duration_s <= 0
      elapsed_s >= frame_duration_s
    end

    # Next frame index, wrapping at total. total <= 1 is a static
    # image (or a misconfigured animated one); we keep returning 0
    # so the renderer never reads past the only frame.
    def next_frame_index(current, total)
      return 0 if total.nil? || total <= 1
      (current + 1) % total
    end
  end
end
