# frozen_string_literal: true

module Nutty
  class Cursor
    attr_accessor :row, :col, :visible

    def initialize(row: 0, col: 0)
      @row = row
      @col = col
      @visible = true
    end

    def move_to(row, col)
      @row = row
      @col = col
    end
  end
end
