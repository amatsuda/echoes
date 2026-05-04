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
    @shell.submit_line("echo hello")
    assert_equal "hello\n", @shell.read_available_output
  end

  test "read_available_output drains the buffer" do
    @shell.submit_line("echo a")
    @shell.read_available_output
    @shell.submit_line("echo b")
    assert_equal "b\n", @shell.read_available_output
  end

  test "cd changes the embedded shell's cwd" do
    @shell.submit_line("cd /tmp")
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
    @shell.submit_line("true")
    assert_equal 0, @shell.last_status
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

  test "embedded pane renders an initial prompt on construction" do
    assert_operator grid_rows.size, :>=, 1
    assert_match(/\$\s*$/, grid_rows.first)
  end

  test "typing echoes characters to the screen and Enter submits the line" do
    "echo hi".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    rows = grid_rows
    assert(rows.any? { |r| r.include?("echo hi") }, "expected typed line in #{rows.inspect}")
    assert_includes rows, "hi"
    # New prompt should appear after the output
    assert_match(/\$\s*$/, rows.last)
  end

  test "backspace pops the input buffer and erases the last cell" do
    "echo abc".chars.each { |c| @pane.handle_key(chars: c) }
    3.times { @pane.handle_key(chars: "\u{7F}") }  # erase "abc"
    "x".chars.each { |c| @pane.handle_key(chars: c) }
    @pane.handle_key(chars: "\r")
    rows = grid_rows
    assert rows.any? { |r| r.include?("echo x") }, "expected 'echo x' line in #{rows.inspect}"
    assert_includes rows, "x"
  end
end
