# frozen_string_literal: true

require_relative "echoes/version"
require_relative "echoes/configuration"
require_relative "echoes/cell"
require_relative "echoes/cursor"
require_relative "echoes/screen"
require_relative "echoes/parser"
require_relative "echoes/tab"
require_relative "echoes/sixel_decoder"
require_relative "echoes/terminal"
require_relative "echoes/objc"
require_relative "echoes/gui"

module Echoes
  class Error < StandardError; end
end

Echoes.load_config
