# frozen_string_literal: true

require "test_helper"

class Echoes::PaneTest < Test::Unit::TestCase
  setup do
    @pane = Echoes::Pane.new(command: "/bin/cat", rows: 24, cols: 80)
  end

  teardown do
    @pane.close
  end

  test "initialize creates screen with given dimensions" do
    assert_instance_of(Echoes::Screen, @pane.screen)
    assert_equal(24, @pane.screen.rows)
    assert_equal(80, @pane.screen.cols)
  end

  test "initialize creates parser" do
    assert_instance_of(Echoes::Parser, @pane.parser)
  end

  test "initialize spawns pty" do
    assert_not_nil(@pane.pty_read)
    assert_not_nil(@pane.pty_write)
    assert_not_nil(@pane.pty_pid)
  end

  test "initialize sets winsize" do
    assert_equal([24, 80], @pane.pty_read.winsize)
  end

  test "initialize sets scroll defaults" do
    assert_equal(0, @pane.scroll_offset)
    assert_equal(0.0, @pane.scroll_accum)
  end

  test "initialize sets title from command basename" do
    assert_equal("cat", @pane.title)
  end

  test "initialize sets copy_mode to nil" do
    assert_nil(@pane.copy_mode)
  end

  test "alive? returns true for running process" do
    assert_equal(true, @pane.alive?)
  end

  test "alive? returns false after process exits" do
    pane = Echoes::Pane.new(command: "/usr/bin/true", rows: 5, cols: 10)
    sleep 0.2
    assert_equal(false, pane.alive?)
    pane.close
  end

  test "resize changes screen dimensions" do
    @pane.resize(30, 100)
    assert_equal(30, @pane.screen.rows)
    assert_equal(100, @pane.screen.cols)
  end

  test "resize updates pty winsize" do
    @pane.resize(30, 100)
    assert_equal([30, 100], @pane.pty_read.winsize)
  end

  test "close closes pty streams" do
    @pane.close
    assert_equal(true, @pane.pty_write.closed?)
    assert_equal(true, @pane.pty_read.closed?)
  end

  test "close can be called multiple times" do
    assert_nothing_raised do
      @pane.close
      @pane.close
    end
  end

  test "process_output feeds data to parser" do
    @pane.process_output("hello")
    # The parser should have processed the data and put it on screen
    text = @pane.screen.grid[0].map(&:char).join.strip
    assert_equal("hello", text)
  end

  test "pty communication" do
    @pane.pty_write.print("hello")
    output = @pane.pty_read.readpartial(1024)
    assert_equal("hello", output)
  end
end

class Echoes::PaneLifecycleTest < Test::Unit::TestCase
  def wait_until(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
    true
  end

  def process_gone?(pid)
    !system("ps", "-p", pid.to_s, out: File::NULL, err: File::NULL)
  end

  test "close reaps the child instead of leaving a zombie" do
    pane = Echoes::Pane.new(command: "/bin/sleep 30", rows: 5, cols: 10)
    pid = pane.pty_pid
    pane.close
    # Without reaping, `ps` keeps listing the HUP'd child as <defunct>.
    assert wait_until(3) { process_gone?(pid) }, "pid #{pid} is still around (zombie?)"
  end

  test "close ends a child that ignores HUP" do
    # trap "" makes HUP ignored, and SIG_IGN survives exec, so this is
    # a child the hangup alone would never reach. It's also how a CI
    # runner that ignores HUP in the parent hands children to us.
    pane = Echoes::Pane.new(command: ["/bin/sh", "-c", 'trap "" HUP; exec sleep 30'], rows: 5, cols: 10)
    pid = pane.pty_pid
    pane.close
    assert wait_until(5) { process_gone?(pid) }, "pid #{pid} survived close"
  end

  test "close after the child was already reaped does nothing" do
    pane = Echoes::Pane.new(command: "/usr/bin/true", rows: 5, cols: 10)
    assert wait_until(3) { !pane.alive? }
    assert_nothing_raised { pane.close }
    refute pane.alive?
  end

  test "write_input never blocks when the other side isn't reading" do
    pane = Echoes::Pane.allocate
    reader, writer = IO.pipe
    pane.pty_write = writer
    big = "x" * (2 * 1024 * 1024)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pane.write_input(big)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 1.0
    assert_operator pane.pending_input_bytes, :>, 0

    received = +''
    drain = Thread.new { received << reader.read(big.bytesize) }
    assert wait_until(5) { pane.flush_outbox; pane.pending_input_bytes.zero? }
    writer.close
    drain.join
    assert_equal big, received
  end
end

class Echoes::PaneChildEnvTest < Test::Unit::TestCase
  test "normalizing the child's env does not touch the GUI's own ENV" do
    saved = ENV.to_h
    ENV['RBENV_VERSION'] = '9.9.9'
    ENV['TERM'] = 'dumb'
    ENV.delete('LANG')
    pane = Echoes::Pane.new(command: ["/bin/sh", "-c", "echo T=$TERM R=${RBENV_VERSION:-unset} L=$LANG"],
                            rows: 5, cols: 60)
    out = +''
    deadline = Time.now + 5
    out << pane.read_available_output while Time.now < deadline && !out.include?('L=')
    assert_includes out, "T=#{Echoes.config.term} R=unset L=en_US.UTF-8"
    assert_equal '9.9.9', ENV['RBENV_VERSION']
    assert_equal 'dumb', ENV['TERM']
    assert_nil ENV['LANG']
    pane.close
  ensure
    ENV.replace(saved) if saved
  end
end

class Echoes::PaneUnsavedChangesTest < Test::Unit::TestCase
  FakeEditor = Struct.new(:modified) do
    def modified? = modified
    def closed? = false
  end

  test "unsaved_changes? is true only for an editor pane with a modified buffer" do
    pane = Echoes::Pane.allocate
    refute pane.unsaved_changes?                          # not an editor pane
    pane.instance_variable_set(:@editor, FakeEditor.new(false))
    refute pane.unsaved_changes?
    pane.instance_variable_set(:@editor, FakeEditor.new(true))
    assert pane.unsaved_changes?
  end
end

class Echoes::PaneBusyTest < Test::Unit::TestCase
  def wait_until(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
    true
  end

  test "busy? reports a foreground job that isn't the shell itself" do
    # A job-control shell puts `sleep` in its own process group and
    # hands it the terminal; `fg` keeps the shell alive behind it.
    pane = Echoes::Pane.new(command: ["/bin/sh", "-c", "set -m; sleep 30 & fg %1"], rows: 5, cols: 20)
    assert wait_until(3) { pane.busy? }, "expected the pane to be busy while sleep holds the terminal"
    assert_equal 'sleep', pane.foreground_process_name
    pane.close
  end

  test "busy? is false for an idle shell and for closed panes" do
    pane = Echoes::Pane.new(command: ["/bin/sh", "-c", "sleep 30"], rows: 5, cols: 20)
    sleep 0.2
    refute pane.busy?   # sh exec'd sleep (same pid) or runs it in its own group
    pane.close
    refute pane.busy?
  end
end
