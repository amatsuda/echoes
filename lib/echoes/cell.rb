# frozen_string_literal: true

module Echoes
  class Cell
    attr_accessor :char, :fg, :bg, :bold, :italic, :underline, :inverse, :faint, :strikethrough, :width, :multicell

    def initialize(char = " ", fg: nil, bg: nil, bold: false, underline: false, inverse: false, width: 1)
      @char = char
      @fg = fg
      @bg = bg
      @bold = bold
      @italic = false
      @underline = underline
      @inverse = inverse
      @faint = false
      @strikethrough = false
      @width = width
    end

    def reset!
      @char = " "
      @fg = nil
      @bg = nil
      @bold = false
      @italic = false
      @underline = false
      @inverse = false
      @faint = false
      @strikethrough = false
      @width = 1
      @multicell = nil
    end

    def copy_from(other)
      @char = other.char
      @fg = other.fg
      @bg = other.bg
      @bold = other.bold
      @italic = other.italic
      @underline = other.underline
      @inverse = other.inverse
      @faint = other.faint
      @strikethrough = other.strikethrough
    end
  end
end
