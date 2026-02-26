# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "stringio"

class Echoes::ConfigurationTest < Test::Unit::TestCase
  setup do
    @config = Echoes::Configuration.new
  end

  test "default values" do
    assert_nil(@config.font_family)
    assert_equal(14.0, @config.font_size)
    assert_equal(24, @config.rows)
    assert_equal(80, @config.cols)
    assert_equal(ENV['SHELL'] || '/bin/bash', @config.shell)
    assert_equal(1000, @config.scrollback_limit)
    assert_equal([0.9, 0.9, 0.9], @config.foreground)
    assert_equal([0.0, 0.0, 0.0], @config.background)
    assert_equal([0.7, 0.7, 0.7, 0.5], @config.cursor_color)
    assert_equal('Echoes', @config.window_title)
  end

  test "DSL setters" do
    @config.instance_eval do
      font_family 'Menlo'
      font_size 18
      rows 30
      cols 120
      shell '/bin/zsh'
      scrollback_limit 2000
      foreground 1.0, 1.0, 1.0
      background 0.1, 0.1, 0.1
      cursor_color 0.5, 0.5, 0.5, 0.8
      window_title 'My Terminal'
    end

    assert_equal('Menlo', @config.font_family)
    assert_equal(18.0, @config.font_size)
    assert_equal(30, @config.rows)
    assert_equal(120, @config.cols)
    assert_equal('/bin/zsh', @config.shell)
    assert_equal(2000, @config.scrollback_limit)
    assert_equal([1.0, 1.0, 1.0], @config.foreground)
    assert_equal([0.1, 0.1, 0.1], @config.background)
    assert_equal([0.5, 0.5, 0.5, 0.8], @config.cursor_color)
    assert_equal('My Terminal', @config.window_title)
  end

  test "load_config reads conf file" do
    Tempfile.create(['echoes', '.conf']) do |f|
      f.write("font_size 20\nrows 40\n")
      f.flush

      original_path = Echoes::CONFIG_PATH
      silence_warnings { Echoes.const_set(:CONFIG_PATH, f.path) }
      Echoes.instance_variable_set(:@config, nil)
      begin
        Echoes.load_config
        assert_equal(20.0, Echoes.config.font_size)
        assert_equal(40, Echoes.config.rows)
      ensure
        silence_warnings { Echoes.const_set(:CONFIG_PATH, original_path) }
        Echoes.instance_variable_set(:@config, nil)
      end
    end
  end

  test "hex color" do
    @config.instance_eval do
      foreground '#ff8000'
    end
    assert_equal([1.0, 128 / 255.0, 0.0], @config.foreground)
  end

  test "hex color with alpha" do
    @config.instance_eval do
      cursor_color '#b3b3b380'
    end
    assert_equal([179 / 255.0, 179 / 255.0, 179 / 255.0, 128 / 255.0], @config.cursor_color)
  end

  test "Echoes.config returns singleton" do
    Echoes.instance_variable_set(:@config, nil)
    begin
      assert_same(Echoes.config, Echoes.config)
    ensure
      Echoes.instance_variable_set(:@config, nil)
    end
  end

  test "load_config with syntax error falls back to defaults" do
    Tempfile.create(['echoes', '.conf']) do |f|
      f.write("font_size 20\nthis is invalid syntax !!!\n")
      f.flush

      original_path = Echoes::CONFIG_PATH
      silence_warnings { Echoes.const_set(:CONFIG_PATH, f.path) }
      Echoes.instance_variable_set(:@config, nil)
      begin
        _stderr = capture_stderr { Echoes.load_config }
        # Config should still have defaults (font_size may or may not be set
        # depending on where the error occurs, but it should not crash)
        assert_instance_of(Echoes::Configuration, Echoes.config)
      ensure
        silence_warnings { Echoes.const_set(:CONFIG_PATH, original_path) }
        Echoes.instance_variable_set(:@config, nil)
      end
    end
  end

  private

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  def silence_warnings
    old_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = old_verbose
  end
end
