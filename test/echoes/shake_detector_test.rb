# frozen_string_literal: true

require "test_helper"
require "echoes/gui"

class Echoes::ShakeDetectorTest < Test::Unit::TestCase
  def setup
    @det = Echoes::ShakeDetector.new
  end

  # Helper: feed samples spaced 20ms apart. Returns whichever observe
  # call first returned true, or false if none did.
  def feed(points, dt: 0.02)
    t = 0.0
    fired = false
    points.each do |x, y|
      t += dt
      fired ||= @det.observe(t, x, y)
    end
    fired
  end

  test "slow steady drift does not fire" do
    points = (0..20).map { |i| [i * 5.0, 0.0] }  # 100px straight, no reversals
    refute feed(points)
  end

  test "many reversals over a short distance does not fire" do
    # Lots of reversals (jitter) but path is too short.
    points = (0..20).map { |i| [(i.even? ? 0.0 : 3.0), 0.0] }
    refute feed(points)
  end

  test "long sweep without reversals does not fire" do
    points = (0..20).map { |i| [i * 30.0, 0.0] }  # 600px straight
    refute feed(points)
  end

  test "rapid back-and-forth with sufficient path fires" do
    # Sweep right 200px, left 200px, right 200px, left 200px — three
    # reversals with ~800px of total path inside the 0.5s window.
    points = []
    [0, 200, 0, 200, 0].each_cons(2) do |a, b|
      6.times { |i| points << [a + (b - a) * i / 5.0, 0.0] }
    end
    assert feed(points)
  end

  test "samples older than the window are discarded" do
    # Drift slowly for a long time, then start a real shake — the
    # old drift samples should fall out of the window before the
    # shake samples accumulate, so the shake fires cleanly.
    @det.observe(0.0,   0.0, 0.0)
    @det.observe(10.0,  5.0, 0.0)  # huge time gap; window cutoff drops the older one
    refute @det.observe(10.02, 5.0, 0.0)
    # Now feed a real shake at t ~= 10.x:
    t = 10.0
    fired = false
    [0, 200, 0, 200, 0].each_cons(2) do |a, b|
      6.times do |i|
        t += 0.02
        fired ||= @det.observe(t, a + (b - a) * i / 5.0, 0.0)
      end
    end
    assert fired
  end

  test "reset clears the sample window" do
    points = []
    [0, 200, 0, 200, 0].each_cons(2) do |a, b|
      6.times { |i| points << [a + (b - a) * i / 5.0, 0.0] }
    end
    assert feed(points)
    @det.reset
    # A single sample after reset can't possibly fire — needs >= 4
    # samples to even attempt detection.
    refute @det.observe(100.0, 0.0, 0.0)
  end
end
