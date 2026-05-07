# frozen_string_literal: true

module Echoes
  # Helpers that emit Echoes-private OSC sequences for tools running
  # inside an Echoes pane (e.g. a Ruby presentation tool that wants
  # Keynote-style gradient slide backgrounds). Other terminals ignore
  # the OSC code, so emitters degrade gracefully.
  #
  # Example:
  #   Echoes::Client.bg_gradient(from: '#1a1a2e', to: '#16213e', angle: 90)
  #   # ...later, restore the solid background:
  #   Echoes::Client.bg_clear
  module Client
    OSC = "\e]7772"
    BEL = "\a"

    module_function

    # Paint a linear gradient as the pane's background. `angle` is in
    # degrees (0 = left→right, 90 = bottom→top, matches NSGradient).
    # Pass an array of hex strings via `colors:` for endpoints beyond
    # two (the renderer currently uses first/last only).
    def bg_gradient(from: nil, to: nil, colors: nil, angle: 0, type: :linear, io: $stdout)
      colors ||= [from, to]
      colors = colors.compact.map(&:to_s)
      raise ArgumentError, 'need at least 2 colors' if colors.size < 2

      args = "type=#{type}:angle=#{angle}:colors=#{colors.join(',')}"
      io.write("#{OSC};bg-gradient;#{args}#{BEL}")
      io.flush if io.respond_to?(:flush)
      nil
    end

    # Drop any pane background override and revert to the solid
    # default_bg. Safe to call when no gradient is set.
    def bg_clear(io: $stdout)
      io.write("#{OSC};bg-clear#{BEL}")
      io.flush if io.respond_to?(:flush)
      nil
    end
  end
end
