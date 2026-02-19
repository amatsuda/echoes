# frozen_string_literal: true

module Nutty
  class Cell
    attr_accessor :char, :fg, :bg, :bold, :underline, :inverse, :width

    def initialize(char = " ", fg: nil, bg: nil, bold: false, underline: false, inverse: false, width: 1)
      @char = char
      @fg = fg
      @bg = bg
      @bold = bold
      @underline = underline
      @inverse = inverse
      @width = width
    end

    def reset!
      @char = " "
      @fg = nil
      @bg = nil
      @bold = false
      @underline = false
      @inverse = false
      @width = 1
    end

    def copy_from(other)
      @char = other.char
      @fg = other.fg
      @bg = other.bg
      @bold = other.bold
      @underline = other.underline
      @inverse = other.inverse
    end
  end
end
