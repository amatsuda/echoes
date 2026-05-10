# frozen_string_literal: true

require "test_helper"
require "echoes/configuration"
require "echoes/profile"

class Echoes::ProfileTest < Test::Unit::TestCase
  test "stores and returns its name" do
    p = Echoes::Profile.new("Solarized Dark")
    assert_equal "Solarized Dark", p.name
  end

  test "foreground/background accept hex strings and parse to RGB triples" do
    p = Echoes::Profile.new("X")
    p.foreground "#ffcc99"
    assert_in_delta 1.0,        p.foreground[0], 0.001
    assert_in_delta 0xCC/255.0, p.foreground[1], 0.001
    assert_in_delta 0x99/255.0, p.foreground[2], 0.001

    p.background "#112233"
    assert_in_delta 0x11/255.0, p.background[0], 0.001
  end

  test "color_palette accepts an array of 16 hex strings" do
    p = Echoes::Profile.new("X")
    p.color_palette %w[#000000 #cc0000 #00cc00 #cccc00 #0000cc #cc00cc #00cccc #cccccc
                       #555555 #ff0000 #00ff00 #ffff00 #0000ff #ff00ff #00ffff #ffffff]
    palette = p.color_palette
    assert_equal 16, palette.size
    assert_in_delta 0xCC / 255.0, palette[1][0], 0.001
  end

  test "unset attributes fall back to Echoes.config" do
    p = Echoes::Profile.new("Partial")
    # Foreground left unset.
    assert_equal Echoes.config.foreground, p.foreground
  end

  test "configuration#profile DSL declares a Profile and stores it by name" do
    cfg = Echoes::Configuration.new
    p = cfg.profile("Light") do
      foreground "#000000"
      background "#ffffff"
    end
    assert_kind_of Echoes::Profile, p
    assert_equal({"Light" => p}, cfg.profiles)
    assert_in_delta 0.0, p.foreground[0], 0.001
    assert_in_delta 1.0, p.background[0], 0.001
  end

  test "default_profile(name) picks an active profile by name" do
    cfg = Echoes::Configuration.new
    cfg.profile("A") { background "#100000" }
    cfg.profile("B") { background "#001000" }
    cfg.default_profile "B"
    assert_equal "B", cfg.default_profile.name
  end

  test "default_profile falls back to the first declared profile when none picked" do
    cfg = Echoes::Configuration.new
    a = cfg.profile("A") { foreground "#aaaaaa" }
    cfg.profile("B") { foreground "#bbbbbb" }
    assert_equal a, cfg.default_profile
  end

  test "default_profile synthesizes a Default from flat config when no profiles exist" do
    cfg = Echoes::Configuration.new
    cfg.foreground "#abcdef"
    cfg.background "#012345"
    profile = cfg.default_profile
    assert_equal "Default", profile.name
    assert_in_delta 0xAB / 255.0, profile.foreground[0], 0.001
    assert_in_delta 0x01 / 255.0, profile.background[0], 0.001
  end
end
