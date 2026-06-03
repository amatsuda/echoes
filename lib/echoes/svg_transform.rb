# frozen_string_literal: true

module Echoes
  # SVG `transform=` attribute parser. Returns an ordered list of
  # `[op_symbol, [args…]]` tuples, or nil for unknown functions /
  # malformed input. Caller applies them left-to-right via CG's CTM
  # setters (CGContextTranslateCTM, ScaleCTM, RotateCTM, ConcatCTM).
  module SvgTransform
    FN_RE = /([a-zA-Z]+)\s*\(([^)]*)\)/
    NUM_RE = /-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/

    module_function

    def parse(str)
      return nil if str.nil? || str.strip.empty?
      ops = []
      str.scan(FN_RE) do |name, body|
        nums = body.scan(NUM_RE).map(&:to_f)
        op = build(name.downcase, nums)
        return nil if op.nil?
        ops << op
      end
      return nil if ops.empty?
      ops
    end

    def build(name, nums)
      case name
      when 'translate'
        return nil unless (1..2).cover?(nums.size)
        [:translate, [nums[0], nums[1] || 0.0]]
      when 'scale'
        return nil unless (1..2).cover?(nums.size)
        [:scale, [nums[0], nums[1] || nums[0]]]
      when 'rotate'
        return nil unless [1, 3].include?(nums.size)
        deg = nums[0]
        cx, cy = nums.size == 3 ? [nums[1], nums[2]] : [0.0, 0.0]
        [:rotate, [deg, cx, cy]]
      when 'matrix'
        return nil unless nums.size == 6
        [:matrix, nums]
      when 'skewx'
        return nil unless nums.size == 1
        [:skewx, [nums[0]]]
      when 'skewy'
        return nil unless nums.size == 1
        [:skewy, [nums[0]]]
      else
        nil
      end
    end
  end
end
