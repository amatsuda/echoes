# frozen_string_literal: true

require_relative "nutty/version"
require_relative "nutty/cell"
require_relative "nutty/cursor"
require_relative "nutty/screen"
require_relative "nutty/parser"
require_relative "nutty/terminal"

module Nutty
  class Error < StandardError; end
end
