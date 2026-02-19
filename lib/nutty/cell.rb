# frozen_string_literal: true

module Nutty
  class Cell
    attr_accessor :char, :fg, :bg, :bold, :underline, :inverse

    def initialize(char = " ", fg: nil, bg: nil, bold: false, underline: false, inverse: false)
      @char = char
      @fg = fg
      @bg = bg
      @bold = bold
      @underline = underline
      @inverse = inverse
    end

    def reset!
      @char = " "
      @fg = nil
      @bg = nil
      @bold = false
      @underline = false
      @inverse = false
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
