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
    require "reline"
    # Reline::HISTORY is class-level state shared across tests; reset
    # it so per-test history walks aren't contaminated by prior tests'
    # submissions.
    Reline::HISTORY.clear
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

  CTRL   = 0x40000   # NSEventModifierFlagControl
  OPTION = 0x80000   # NSEventModifierFlagOption
  SHIFT  = 0x20000   # NSEventModifierFlagShift
  CMD    = 0x100000  # NSEventModifierFlagCommand

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

  test "Option+Backspace deletes the word before the cursor" do
    "echo hello world".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{7F}", flags: OPTION)
    assert_equal "echo hello ", buf
    @pane.handle_key(chars: "\u{7F}", flags: OPTION)
    assert_equal "echo ", buf
    @pane.handle_key(chars: "\u{7F}", flags: OPTION)
    assert_equal "", buf
  end

  test "Option+Delete deletes the word at the cursor" do
    "echo hello world".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F729}")  # Home
    @pane.handle_key(chars: "\u{F728}", flags: OPTION)
    assert_equal " hello world", buf
    @pane.handle_key(chars: "\u{F728}", flags: OPTION)
    assert_equal " world", buf
    @pane.handle_key(chars: "\u{F728}", flags: OPTION)
    assert_equal "", buf
  end

  test "Option+Backspace mid-line removes the word before the cursor and preserves the tail" do
    "alpha beta gamma".chars.each { |c| @pane.handle_key(chars: c) }
    # cursor at end. move left into "gamma" so cursor sits before 'a' at end of beta-space
    "alpha beta ".length.tap do |target|
      back = "alpha beta gamma".length - target
      back.times { @pane.handle_key(chars: "\u{F702}") }
    end
    @pane.handle_key(chars: "\u{7F}", flags: OPTION)
    assert_equal "alpha gamma", buf
    assert_equal "alpha ".length, cursor
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

  test "Ctrl-H deletes the char before the cursor (alias for Backspace)" do
    "abc".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "h", flags: CTRL)
    assert_equal "ab", buf
    assert_equal 2, cursor
  end

  test "Ctrl-J submits the line (alias for Enter)" do
    "echo j-test".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "j", flags: CTRL)
    settle
    assert_match(/j-test/, grid_text)
  end

  test "Ctrl-M submits the line (alias for Enter)" do
    "echo m-test".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "m", flags: CTRL)
    settle
    assert_match(/m-test/, grid_text)
  end

  test "Ctrl-I completes (alias for Tab)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "uniquetab.txt"), "")
      "ls #{dir}/u".chars.each { |c| @pane.handle_key(chars: c) }
      @pane.handle_key(chars: "i", flags: CTRL)
      assert_match(/uniquetab\.txt/, grid_text)
    end
  end

  test "Ctrl-T transposes the two chars around the cursor" do
    "abdc".chars.each { |c| @pane.handle_key(chars: c) }
    # cursor at end. transpose: last two ("dc") -> "cd"
    @pane.handle_key(chars: "t", flags: CTRL)
    assert_equal "abcd", buf
  end

  test "Ctrl-Y yanks the most recently killed text" do
    "echo hello world".chars.each { |c| @pane.handle_key(chars: c) }
    # cursor at end. Ctrl-W kills "world".
    @pane.handle_key(chars: "w", flags: CTRL)
    assert_equal "echo hello ", buf
    # Ctrl-Y pastes it back.
    @pane.handle_key(chars: "y", flags: CTRL)
    assert_equal "echo hello world", buf
  end

  test "Ctrl-P / Ctrl-N walk history (aliases for ↑/↓)" do
    "echo hi".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "p", flags: CTRL)  # ↑
    assert_equal "echo hi", buf
    @pane.handle_key(chars: "n", flags: CTRL)  # ↓
    assert_equal "", buf
  end

  test "Ctrl-C at prompt clears the input and drops a fresh prompt" do
    "half typed".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "c", flags: CTRL)
    assert_equal "", buf
    assert_equal 0, cursor
  end

  test "incomplete input shows a continuation prompt instead of submitting" do
    "if true; then".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    cont = @pane.instance_variable_get(:@continuation_lines)
    assert_equal ["if true; then"], cont
    assert_equal false, @pane.instance_variable_get(:@embedded_running)
    rows = grid_rows
    # PS2 prompt should appear on the new line. Default rubish PS2 is "> ".
    assert_match(/\A>\s*$/, rows.last)
  end

  test "completing a multi-line block submits the whole thing" do
    ["if true; then", "  echo hello world", "fi"].each do |line|
      line.chars.each { |c| @pane.handle_key(chars: c) }
      @pane.handle_key(chars: "\r")
    end
    settle
    flat = grid_text
    assert_match(/hello world/, flat)
    # @continuation_lines should be reset after submission.
    assert_equal [], @pane.instance_variable_get(:@continuation_lines)
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

  # Reach into the private colorize_input for direct assertion. The
  # rendered output is what matters, but checking the SGR-wrapped string
  # separately is the most precise way to lock in highlighting behavior
  # across token types.
  def colorize(line)
    @pane.send(:colorize_input, line)
  end

  test "syntax highlighting wraps keywords in bold-yellow SGR" do
    out = colorize("if true; then echo hi; fi")
    assert_includes out, "\e[1;33mif\e[0m"
    assert_includes out, "\e[1;33mthen\e[0m"
    assert_includes out, "\e[1;33mfi\e[0m"
  end

  test "syntax highlighting wraps the first word at command position in bold" do
    out = colorize("echo hello")
    assert_includes out, "\e[1mecho\e[0m"
    # 'hello' is an argument, not bold
    refute_includes out, "\e[1mhello\e[0m"
  end

  test "syntax highlighting wraps quoted words in green" do
    out = colorize(%q{echo "hi" 'there'})
    assert_includes out, "\e[32m\"hi\"\e[0m"
    assert_includes out, "\e[32m'there'\e[0m"
  end

  test "syntax highlighting wraps pipe and redirect in their colors" do
    out = colorize("ls | grep foo > /tmp/x")
    assert_includes out, "\e[96m|\e[0m"
    assert_includes out, "\e[95m>\e[0m"
  end

  test "syntax highlighting puts the second pipeline stage's first word into command position" do
    out = colorize("ls | grep foo")
    # both 'ls' and 'grep' are command-position WORDs
    assert_includes out, "\e[1mls\e[0m"
    assert_includes out, "\e[1mgrep\e[0m"
    refute_includes out, "\e[1mfoo\e[0m"
  end

  test "syntax highlighting falls back to plain text on empty input" do
    assert_equal "", colorize("")
  end

  # Direct accessor for the autosuggestion ghost-text state.
  def autosuggestion; @pane.instance_variable_get(:@autosuggestion); end

  test "autosuggestion shows the tail of the most recent matching history entry" do
    "echo hello".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "ec".chars.each { |c| @pane.handle_key(chars: c) }
    assert_equal "ho hello", autosuggestion
  end

  test "autosuggestion is empty when no history entry matches the prefix" do
    "echo hello".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "xyz".chars.each { |c| @pane.handle_key(chars: c) }
    assert_equal "", autosuggestion
  end

  test "autosuggestion is empty when buffer is empty" do
    "echo hello".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    assert_equal "", autosuggestion
  end

  test "Right arrow at end-of-input accepts the full autosuggestion" do
    "echo hello world".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "echo".chars.each { |c| @pane.handle_key(chars: c) }
    assert_equal " hello world", autosuggestion
    @pane.handle_key(chars: "\u{F703}")  # Right
    assert_equal "echo hello world", buf
    assert_equal "", autosuggestion
  end

  test "Ctrl-E at end-of-input accepts the full autosuggestion" do
    "echo hello world".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "echo".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "e", flags: CTRL)
    assert_equal "echo hello world", buf
  end

  test "End at end-of-input accepts the full autosuggestion" do
    "echo hello world".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "echo".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{F72B}")  # End
    assert_equal "echo hello world", buf
  end

  test "Ctrl-F at end-of-input accepts only the next word of the autosuggestion" do
    "echo hello world".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "echo".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "f", flags: CTRL)
    assert_equal "echo hello", buf
    @pane.handle_key(chars: "f", flags: CTRL)
    assert_equal "echo hello world", buf
  end

  test "autosuggestion cleared after submitting" do
    "echo hello".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    assert_equal "", autosuggestion
  end

  test "autosuggestion suppressed during multi-line continuation" do
    "echo hello".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "if true; then".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")  # incomplete → continuation prompt
    "ec".chars.each { |c| @pane.handle_key(chars: c) }
    # Even though "echo hello" is in history, no suggestion shows
    # while inside a continuation.
    assert_equal "", autosuggestion
  end

  # Direct accessors for the search-mode state.
  def input_mode;   @pane.instance_variable_get(:@input_mode);   end
  def search_query; @pane.instance_variable_get(:@search_query); end
  def search_index; @pane.instance_variable_get(:@search_index); end

  test "Ctrl-R enters reverse-i-search mode and renders the search prompt" do
    "echo hello".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "r", flags: CTRL)
    assert_equal :search, input_mode
    assert_match(/\(reverse-i-search\)/, grid_text)
  end

  test "typing inside reverse-i-search narrows to the newest matching entry" do
    "echo first".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "echo second".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "r", flags: CTRL)
    "se".chars.each { |c| @pane.handle_key(chars: c) }
    assert_equal "se", search_query
    assert_match(/echo second/, grid_text)
  end

  test "Ctrl-R inside search jumps to the next older match" do
    "echo first".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    "echo second".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "r", flags: CTRL)
    "echo".chars.each { |c| @pane.handle_key(chars: c) }
    # newest match first ("echo second")
    hist = @pane.embedded_shell.history
    assert_equal hist.index("echo second"), search_index
    @pane.handle_key(chars: "r", flags: CTRL)  # next older
    assert_equal hist.index("echo first"), search_index
  end

  test "Backspace inside search pops a query char and re-searches" do
    "echo banana".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "r", flags: CTRL)
    "ban".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\u{7F}")
    assert_equal "ba", search_query
  end

  test "Esc cancels search and restores the in-progress input" do
    "echo".chars.each { |c| @pane.handle_key(chars: c) }
    "echo hello".chars.each { |c| @pane.handle_key(chars: c) }  # not relevant
    # actually start fresh: type partial input, enter search, cancel
    @pane.handle_key(chars: "c", flags: CTRL)  # clear
    "abc".chars.each { |c| @pane.handle_key(chars: c) }
    saved = buf
    @pane.handle_key(chars: "r", flags: CTRL)
    assert_equal :search, input_mode
    @pane.handle_key(chars: "\e")  # Esc
    assert_equal :prompt, input_mode
    assert_equal saved, buf
  end

  test "Ctrl-G cancels search like Esc" do
    "abc".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "r", flags: CTRL)
    @pane.handle_key(chars: "g", flags: CTRL)
    assert_equal :prompt, input_mode
  end

  test "Enter inside search accepts the matched line and submits it" do
    "echo banana".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "r", flags: CTRL)
    "ban".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    assert_equal :prompt, input_mode
    # the submitted command produced output
    assert_match(/banana/, grid_text)
  end

  test "Other keys (e.g. up arrow) cancel search and re-process in prompt mode" do
    "echo bar".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "r", flags: CTRL)
    @pane.handle_key(chars: "\u{F700}")  # Up arrow
    assert_equal :prompt, input_mode
    # Up arrow walked history → buffer holds the most recent entry
    assert_equal "echo bar", buf
  end

  # --- OSC 133 prompt-boundary markers ---

  test "embedded pane records an OSC 133 mark at the initial prompt" do
    marks = @pane.screen.command_marks
    assert_operator marks.size, :>=, 1
    assert_equal 0, marks.first[:prompt_start]
    assert_equal 0, marks.first[:input_start]
  end

  test "submitting a command opens an output region in the current mark" do
    "echo hi".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    marks = @pane.screen.command_marks
    # First mark gets output bounds + exit code populated
    first = marks.first
    assert_not_nil first[:output_start]
    assert_not_nil first[:output_end]
    assert_equal 0, first[:exit_code]
  end

  test "after a command runs, a fresh prompt mark is recorded" do
    initial_marks = @pane.screen.command_marks.dup
    "echo hi".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    marks = @pane.screen.command_marks
    assert_operator marks.size, :>, initial_marks.size,
      "expected a new prompt-boundary mark after the command finished"
    last = marks.last
    assert_not_nil last[:prompt_start]
    assert_not_nil last[:input_start]
    # The new prompt mark hasn't received C/D yet
    assert_nil last[:output_start]
  end

  # --- jump_to_prompt navigation (consumer of OSC 133 marks) ---

  # Seed the screen with a synthetic scrollback and OSC 133 marks at
  # specific rows so we can drive jump_to_prompt deterministically.
  def seed_scrollback_and_marks(scrollback_size:, mark_rows:)
    @pane.screen.instance_variable_set(:@scrollback, Array.new(scrollback_size) { [] })
    marks = mark_rows.map do |r|
      {prompt_start: r, input_start: r, output_start: nil, output_end: nil, exit_code: nil}
    end
    @pane.screen.instance_variable_set(:@command_marks, marks)
  end

  test "jump_to_prompt :prev positions the previous prompt at top of view" do
    seed_scrollback_and_marks(scrollback_size: 100, mark_rows: [10, 30, 60])
    @pane.scroll_offset = 0  # at live (current_top = 100)
    assert @pane.jump_to_prompt(direction: :prev)
    # Most recent mark < 100 is at 60 → scroll_offset = 100 - 60 = 40
    assert_equal 40, @pane.scroll_offset
    # Press again — go to mark at 30
    assert @pane.jump_to_prompt(direction: :prev)
    assert_equal 70, @pane.scroll_offset
    # Press again — mark at 10
    assert @pane.jump_to_prompt(direction: :prev)
    assert_equal 90, @pane.scroll_offset
    # No more older marks → returns false, no change
    refute @pane.jump_to_prompt(direction: :prev)
    assert_equal 90, @pane.scroll_offset
  end

  test "jump_to_prompt :next walks back toward live" do
    seed_scrollback_and_marks(scrollback_size: 100, mark_rows: [10, 30, 60])
    @pane.scroll_offset = 95  # current_top = 5; oldest mark > 5 is 10
    assert @pane.jump_to_prompt(direction: :next)
    assert_equal 90, @pane.scroll_offset
    assert @pane.jump_to_prompt(direction: :next)
    assert_equal 70, @pane.scroll_offset
    assert @pane.jump_to_prompt(direction: :next)
    assert_equal 40, @pane.scroll_offset
    refute @pane.jump_to_prompt(direction: :next)
  end

  test "jump_to_prompt is a no-op when there are no marks" do
    seed_scrollback_and_marks(scrollback_size: 100, mark_rows: [])
    @pane.scroll_offset = 50
    refute @pane.jump_to_prompt(direction: :prev)
    refute @pane.jump_to_prompt(direction: :next)
    assert_equal 50, @pane.scroll_offset
  end

  test "jump_to_prompt :next snaps to live when the target is in the live grid" do
    seed_scrollback_and_marks(scrollback_size: 100, mark_rows: [10, 105])
    @pane.scroll_offset = 95  # current_top = 5
    # First next: mark at 10 → scroll_offset = 90
    @pane.jump_to_prompt(direction: :next)
    assert_equal 90, @pane.scroll_offset
    # Second next: mark at 105 (>= scrollback_size) → snap to 0
    @pane.jump_to_prompt(direction: :next)
    assert_equal 0, @pane.scroll_offset
  end

  test "Cmd+Shift+Up at the embedded prompt invokes jump_to_prompt" do
    seed_scrollback_and_marks(scrollback_size: 100, mark_rows: [10, 30, 60])
    @pane.scroll_offset = 0
    @pane.handle_key(chars: "\u{F700}", flags: CMD | SHIFT)
    assert_equal 40, @pane.scroll_offset
  end

  test "plain Up arrow still walks history (no scroll offset change)" do
    "echo first".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "\u{F700}")  # plain Up
    assert_equal "echo first", buf
    assert_equal 0, @pane.scroll_offset
  end

  test "last_command_output_text returns the output of the most recent completed command" do
    "echo hello".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    out = @pane.last_command_output_text
    assert_not_nil out
    assert_match(/hello/, out)
  end

  test "last_command_output_text is nil before any command finishes" do
    assert_nil @pane.last_command_output_text
  end

  test "copy_last_command_output dispatches through the screen's clipboard handler" do
    captured = nil
    @pane.screen.clipboard_handler = ->(action, text) { captured = [action, text] }
    "echo clipme".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    assert @pane.copy_last_command_output
    assert_equal :set, captured.first
    assert_match(/clipme/, captured.last)
  end

  test "Cmd+Shift+O at the prompt copies last command output" do
    captured = nil
    @pane.screen.clipboard_handler = ->(_action, text) { captured = text }
    "echo shortcut-test".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "O", flags: CMD | SHIFT)
    assert_match(/shortcut-test/, captured.to_s)
  end

  test "last_command_text returns the most recent submitted line" do
    "echo first-cmd".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    assert_equal "echo first-cmd", @pane.last_command_text
  end

  test "Cmd+Shift+L at the prompt copies last command text" do
    captured = nil
    @pane.screen.clipboard_handler = ->(_action, text) { captured = text }
    "echo cmd-text-test".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    settle
    @pane.handle_key(chars: "L", flags: CMD | SHIFT)
    assert_equal "echo cmd-text-test", captured
  end

  test "Ctrl-C at the prompt records a fresh prompt mark" do
    n_before = @pane.screen.command_marks.size
    "abc".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "c", flags: CTRL)
    n_after = @pane.screen.command_marks.size
    assert_operator n_after, :>, n_before
  end

  test "highlighted input doesn't pollute the cell grid with escape characters" do
    "echo hello".chars.each { |c| @pane.handle_key(chars: c) }
    flat = grid_text
    # SGRs are consumed by the parser and do not appear in cell chars
    refute_includes flat, "\e"
    assert_match(/echo hello/, flat)
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
