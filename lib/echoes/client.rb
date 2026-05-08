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

    # Paint the pane's background with a single solid color. The
    # color paints beneath cell content, so cells with their own
    # bg color (selection, themed cells, etc.) still occlude
    # correctly. Pair with bg_clear to revert.
    #
    # Example:
    #   Echoes::Client.bg_color('#1a1a2e')
    def bg_color(color, io: $stdout)
      io.write("#{OSC};bg-color;#{color}#{BEL}")
      io.flush if io.respond_to?(:flush)
      nil
    end

    # Paint a rectangular region of the pane on top of the base
    # background. Calls accumulate — emit several to build up a
    # layout (header/footer bars, sidebars, accent stripes, etc.).
    # `bg_clear` wipes the whole list along with the base background.
    #
    # Coordinates are 0-indexed cell positions, inclusive on both
    # ends — i.e. row1=0, col1=0, row2=2, col2=9 paints a 3x10 block.
    #
    # Example:
    #   Echoes::Client.bg_fill('#222',  row1: 0,  col1: 0, row2: 0,  col2: 79)  # status bar
    #   Echoes::Client.bg_fill('#3a3', row1: 24, col1: 0, row2: 24, col2: 79)  # footer
    def bg_fill(color, row1:, col1:, row2:, col2:, io: $stdout)
      args = "color=#{color}:rect=#{row1},#{col1},#{row2},#{col2}"
      io.write("#{OSC};bg-fill;#{args}#{BEL}")
      io.flush if io.respond_to?(:flush)
      nil
    end

    # Drop any pane background override (bg-color/bg-gradient) AND
    # all bg-fill overlays. Safe to call when nothing is set.
    def bg_clear(io: $stdout)
      io.write("#{OSC};bg-clear#{BEL}")
      io.flush if io.respond_to?(:flush)
      nil
    end

    # Emit text via OSC 66 (multicell), with optional cell-scale,
    # sub-cell fraction, vertical/horizontal alignment, and font
    # family. `family:` is an Echoes-specific extension other
    # terminals ignore. On unknown families, Echoes falls back to the
    # monospaced system font.
    #
    # Examples:
    #   Echoes::Client.styled_text("Title",   scale: 3, family: "Helvetica Neue")
    #   Echoes::Client.styled_text("• item",  scale: 1, family: "Menlo")
    def styled_text(text, scale: 1, width: nil, frac_n: nil, frac_d: nil,
                    valign: nil, halign: nil, family: nil, io: $stdout)
      meta = +"s=#{scale}"
      meta << ":w=#{width}"   if width
      meta << ":n=#{frac_n}"  if frac_n
      meta << ":d=#{frac_d}"  if frac_d
      meta << ":v=#{valign}"  if valign
      meta << ":h=#{halign}"  if halign
      meta << ":f=#{family}"  if family
      io.write("\e]66;#{meta};#{text}\a")
      io.flush if io.respond_to?(:flush)
      nil
    end
  end
end
