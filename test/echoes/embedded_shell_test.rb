# frozen_string_literal: true

require "test_helper"
require "echoes/embedded_shell"

class Echoes::EmbeddedShellTest < Test::Unit::TestCase
  def setup
    @shell = Echoes::EmbeddedShell.new
    @original_dir = Dir.pwd
  end

  def teardown
    Dir.chdir(@original_dir)
  end

  test "captures stdout from a builtin" do
    # Capture is via a pty, so the kernel's ONLCR converts "\n" to "\r\n"
    # — the same shape a real terminal would see from the same builtin.
    @shell.submit_and_wait("echo hello")
    assert_equal "hello\r\n", @shell.read_available_output
  end

  test "read_available_output drains the buffer" do
    @shell.submit_and_wait("echo a")
    @shell.read_available_output
    @shell.submit_and_wait("echo b")
    assert_equal "b\r\n", @shell.read_available_output
  end

  test "cd changes the embedded shell's cwd" do
    @shell.submit_and_wait("cd /tmp")
    assert_equal "/private/tmp", @shell.cwd
  end

  test "complete_at returns command completions" do
    candidates = @shell.complete_at(line: "ec", point: 2)
    assert_kind_of Array, candidates
    assert_includes candidates, "echo"
  end

  test "complete_at returns file completions for a path-like word" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "fileone.txt"), "")
      File.write(File.join(dir, "filetwo.txt"), "")
      input = "ls #{dir}/file"
      candidates = @shell.complete_at(line: input, point: input.length)
      assert candidates.any? { |c| c.include?("fileone.txt") }, "expected fileone.txt in #{candidates.inspect}"
      assert candidates.any? { |c| c.include?("filetwo.txt") }, "expected filetwo.txt in #{candidates.inspect}"
    end
  end

  test "prompt_segments returns at least one segment" do
    segs = @shell.prompt_segments
    assert_kind_of Array, segs
    assert_operator segs.size, :>=, 1
    assert segs.all? { |s| s.key?(:text) }, "every segment should have :text"
  end

  test "last_status reflects the last command's exit status" do
    @shell.submit_and_wait("true")
    assert_equal 0, @shell.last_status
  end

  test "captures stdout from a forked external command" do
    # /bin/echo is a real fork+exec; the StringIO trick wouldn't catch
    # this. The pty-redirect path must.
    @shell.submit_and_wait("/bin/echo external hello")
    assert_equal "external hello\r\n", @shell.read_available_output
  end

  test "captures stdout from an external command in a pipeline" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.txt"), "")
      File.write(File.join(dir, "b.txt"), "")
      @shell.submit_and_wait("ls #{dir}")
      out = @shell.read_available_output
      assert_includes out, "a.txt"
      assert_includes out, "b.txt"
    end
  end

  test "external commands see a real TTY on stdout" do
    # Programs branch on isatty(stdout) — the pipe-based capture would
    # have failed this test (children's FD 1 was a pipe, not a tty).
    # With the pty-based capture, FD 1 is a pty slave (a real tty
    # device), so isatty returns true.
    @shell.submit_and_wait("test -t 1 && echo TTY || echo NO_TTY")
    assert_equal "TTY\r\n", @shell.read_available_output
  end

  test "captures larger external output (exceeds pty buffer if not drained)" do
    # seq writes to FD 1 quickly; the reader thread must drain
    # concurrently or the child blocks at the kernel pty buffer.
    @shell.submit_and_wait("seq 5000")
    out = @shell.read_available_output
    lines = out.split("\r\n")
    assert_equal 5000, lines.size
    assert_equal "1", lines.first
    assert_equal "5000", lines.last
  end

  test "submit_and_wait sets the pty winsize so programs see the right dimensions" do
    @shell.submit_and_wait("/usr/bin/tput cols", rows: 30, cols: 132)
    out = @shell.read_available_output.strip
    assert_equal "132", out
  end

  test "submit_line appends the line to history" do
    before = @shell.history.dup
    @shell.submit_and_wait("echo hi")
    assert_equal before + ["echo hi"], @shell.history
  end

  test "submit_line ignores empty/blank input for history" do
    before = @shell.history.dup
    @shell.submit_and_wait("")
    @shell.submit_and_wait("   ")
    assert_equal before, @shell.history
  end

  test "resize updates the pty winsize for a running command" do
    # Loop that prints the column count once a tick. After we resize
    # mid-loop, a later iteration's tput should report the new size.
    @shell.submit_line(
      "for i in 1 2 3 4 5 6 7 8; do tput cols; sleep 0.1; done",
      rows: 24, cols: 80,
    )
    sleep 0.25
    @shell.resize(rows: 30, cols: 132)
    deadline = Time.now + 5
    sleep 0.05 while @shell.running? && Time.now < deadline
    @shell.reap_if_done
    out = @shell.read_available_output
    cols_seen = out.scan(/\d+/).map(&:to_i).uniq
    assert_includes cols_seen, 132, "expected later iterations to see 132 cols, saw #{cols_seen.inspect}"
  end

  test "submit_line returns immediately while the command runs" do
    # Async contract: the call site shouldn't block. We give the
    # command a short sleep so we have a window to inspect state in.
    t0 = Time.now
    @shell.submit_line("/bin/sleep 0.5")
    elapsed = Time.now - t0
    assert_operator elapsed, :<, 0.2,
      "submit_line should return immediately, took #{elapsed}s"
    assert @shell.running?, "command should still be running"
    @shell.submit_and_wait("true")  # waits for the prior sleep too
  end
end

class Echoes::EmbeddedPaneTest < Test::Unit::TestCase
  # Phase-1 line editor lives on Pane; verify keystroke -> echo -> submit
  # cycle works end-to-end against an embedded shell.

  def setup
    require "echoes/pane"
    @pane = Echoes::Pane.new(command: "/bin/sh", rows: 24, cols: 80, embedded: true)
    @original_dir = Dir.pwd
  end

  def teardown
    Dir.chdir(@original_dir)
  end

  def grid_rows(n = 8)
    @pane.screen.grid.first(n).map { |row|
      row.map { |c| c.char || " " }.join.rstrip
    }.reject(&:empty?)
  end

  # Drive a tick loop until the embedded shell has finished its in-flight
  # command (mirrors what the GUI's NSTimer does).
  def settle(timeout: 5)
    deadline = Time.now + timeout
    while Time.now < deadline
      out = @pane.read_available_output
      @pane.process_output(out) unless out.empty?
      break unless @pane.embedded_shell.running?
      sleep 0.01
    end
    # one final drain to capture trailing output + new prompt
    out = @pane.read_available_output
    @pane.process_output(out) unless out.empty?
  end

  test "embedded pane renders an initial prompt on construction" do
    assert_operator grid_rows.size, :>=, 1
    assert_match(/\$\s*$/, grid_rows.first)
  end

  test "typing echoes characters to the screen and Enter submits the line" do
    "echo hi".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    rows = grid_rows
    assert(rows.any? { |r| r.include?("echo hi") }, "expected typed line in #{rows.inspect}")
    assert_includes rows, "hi"
    # New prompt should appear after the output
    assert_match(/\$\s*$/, rows.last)
  end

  test "up arrow pulls the previous history entry into the input line" do
    "echo first".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "echo second".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    # browse with ↑
    @pane.handle_key(chars: "\u{F700}")
    rows = grid_rows
    # The current prompt line should now show "echo second" (most recent)
    assert_match(/echo second\z/, rows.last)
    @pane.handle_key(chars: "\u{F700}")
    rows = grid_rows
    assert_match(/echo first\z/, rows.last)
  end

  test "down arrow at the newest entry restores the in-progress input" do
    "echo prior".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "in-progress".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F700}")  # ↑ → "echo prior"
    @pane.handle_key(chars: "\u{F701}")  # ↓ → restore "in-progress"
    rows = grid_rows
    assert_match(/in-progress\z/, rows.last)
  end

  # Long file paths cause the input line to wrap across multiple rows
  # in the cell grid; join with no separator to reconstruct it.
  def grid_text
    @pane.screen.grid.map { |row| row.map { |c| c.char || ' ' }.join.rstrip }.join
  end

  test "tab completion with a unique candidate inserts the full word" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "uniquefilename.txt"), "")
      "ls #{dir}/u".chars.each { |c| @pane.handle_key(chars: c) }
      @pane.handle_key(chars: "\t")
      assert_match(/uniquefilename\.txt/, grid_text)
    end
  end

  test "tab completion with multiple candidates lists them and re-prompts" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "alpha.txt"), "")
      File.write(File.join(dir, "alphabet.txt"), "")
      "ls #{dir}/al".chars.each { |c| @pane.handle_key(chars: c) }
      @pane.handle_key(chars: "\t")
      assert_match(/alpha\.txt/, grid_text)
      assert_match(/alphabet\.txt/, grid_text)
    end
  end

  # Direct accessors for assertions about the editing state. The buffer
  # and cursor are private-ish implementation details, but tests need to
  # see them.
  def buf;     @pane.instance_variable_get(:@input_buffer); end
  def cursor;  @pane.instance_variable_get(:@input_cursor); end

  test "left arrow moves the cursor back one position" do
    "abc".chars.each { |c| @pane.handle_key(chars: c) }
    assert_equal 3, cursor
    @pane.handle_key(chars: "\u{F702}")
    assert_equal 2, cursor
    @pane.handle_key(chars: "\u{F702}")
    @pane.handle_key(chars: "\u{F702}")
    @pane.handle_key(chars: "\u{F702}")  # past start, stays
    assert_equal 0, cursor
  end

  test "right arrow moves the cursor forward, capped at length" do
    "abc".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F702}")  # cursor = 2
    @pane.handle_key(chars: "\u{F703}")  # back to 3
    assert_equal 3, cursor
    @pane.handle_key(chars: "\u{F703}")  # past end, stays
    assert_equal 3, cursor
  end

  test "home and end jump the cursor" do
    "hello".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F729}")  # Home
    assert_equal 0, cursor
    @pane.handle_key(chars: "\u{F72B}")  # End
    assert_equal 5, cursor
  end

  test "inserting a char in the middle splices it in correctly" do
    "abce".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F702}")  # cursor = 3 (before e)
    @pane.handle_key(chars: "d")
    assert_equal "abcde", buf
    assert_equal 4, cursor
  end

  test "backspace mid-line removes the char before the cursor" do
    "abxcd".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F702}")  # before d
    @pane.handle_key(chars: "\u{F702}")  # before c
    @pane.handle_key(chars: "\u{F702}")  # before x; cursor = 2
    @pane.handle_key(chars: "\u{7F}")    # backspace deletes "b"
    assert_equal "axcd", buf
    assert_equal 1, cursor
  end

  test "forward delete removes the char at the cursor" do
    "abcd".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F729}")  # home; cursor = 0
    @pane.handle_key(chars: "\u{F728}")  # forward delete removes 'a'
    assert_equal "bcd", buf
    assert_equal 0, cursor
  end

  CTRL   = 0x40000  # NSEventModifierFlagControl
  OPTION = 0x80000  # NSEventModifierFlagOption

  test "Option+Left jumps the cursor by a word" do
    "echo hello world".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F702}", flags: OPTION)
    assert_equal "echo hello ".length, cursor
    @pane.handle_key(chars: "\u{F702}", flags: OPTION)
    assert_equal "echo ".length, cursor
    @pane.handle_key(chars: "\u{F702}", flags: OPTION)
    assert_equal 0, cursor
  end

  test "Option+Right jumps the cursor by a word" do
    "echo hello world".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F729}")  # Home
    @pane.handle_key(chars: "\u{F703}", flags: OPTION)
    assert_equal "echo ".length, cursor
    @pane.handle_key(chars: "\u{F703}", flags: OPTION)
    assert_equal "echo hello ".length, cursor
    @pane.handle_key(chars: "\u{F703}", flags: OPTION)
    assert_equal "echo hello world".length, cursor
  end


  test "Ctrl-A jumps cursor to start, Ctrl-E to end" do
    "abcdef".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "a", flags: CTRL)
    assert_equal 0, cursor
    @pane.handle_key(chars: "e", flags: CTRL)
    assert_equal 6, cursor
  end

  test "Ctrl-B / Ctrl-F move the cursor by one" do
    "xyz".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "b", flags: CTRL)
    assert_equal 2, cursor
    @pane.handle_key(chars: "f", flags: CTRL)
    assert_equal 3, cursor
  end

  test "Ctrl-K kills from cursor to end of line" do
    # 19 chars; 9 lefts puts cursor at offset 10 (before "drop this")
    "keep this drop this".chars.each { |c| @pane.handle_key(chars: c) }
    9.times { @pane.handle_key(chars: "\u{F702}") }
    @pane.handle_key(chars: "k", flags: CTRL)
    assert_equal "keep this ", buf
    assert_equal 10, cursor
  end

  test "Ctrl-U kills from cursor back to start of line" do
    # 19 chars; 9 lefts puts cursor at offset 10 (before "keep this")
    "drop this keep this".chars.each { |c| @pane.handle_key(chars: c) }
    9.times { @pane.handle_key(chars: "\u{F702}") }
    @pane.handle_key(chars: "u", flags: CTRL)
    assert_equal "keep this", buf
    assert_equal 0, cursor
  end

  test "Ctrl-W kills the word to the left of the cursor" do
    "echo  hello world".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "w", flags: CTRL)
    assert_equal "echo  hello ", buf
    @pane.handle_key(chars: "w", flags: CTRL)
    assert_equal "echo  ", buf
  end

  test "Ctrl-C at prompt clears the input and drops a fresh prompt" do
    "half typed".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "c", flags: CTRL)
    assert_equal "", buf
    assert_equal 0, cursor
  end

  test "Enter submits the buffer regardless of cursor position" do
    "echo mid-cursor".chars.each { |c| @pane.handle_key(chars: c) }
    5.times { @pane.handle_key(chars: "\u{F702}") }  # cursor != end
    @pane.handle_key(chars: "\r")
    settle
    assert_equal "", buf
    assert_equal 0, cursor
    flat = grid_text
    assert_match(/mid-cursor/, flat)
  end

  test "backspace pops the input buffer and erases the last cell" do
    "echo abc".chars.each { |c| @pane.handle_key(chars: c) }
    3.times { @pane.handle_key(chars: "\u{7F}") }  # erase "abc"
    "x".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    rows = grid_rows
    assert rows.any? { |r| r.include?("echo x") }, "expected 'echo x' line in #{rows.inspect}"
    assert_includes rows, "x"
  end
end
