# frozen_string_literal: true

require "test_helper"
require "echoes/installer"
require "tmpdir"
require "fileutils"

class Echoes::InstallerTest < Test::Unit::TestCase
  def setup
    @source = Dir.mktmpdir('echoes-installer-source')
    @target = Dir.mktmpdir('echoes-installer-target')
    # Stub source bundles look like a real .app: Contents/Info.plist
    # plus an executable. Real bundles also have Contents/MacOS but
    # the wrapper doesn't peek inside there.
    %w[Echoes.app EchoesEmbed.app].each do |bundle|
      FileUtils.mkdir_p(File.join(@source, bundle, 'Contents', 'MacOS'))
      File.write(File.join(@source, bundle, 'Contents', 'Info.plist'),
                 "<?xml?><plist><dict><key>CFBundleVersion</key><string>1.2.3</string></dict></plist>")
      File.write(File.join(@source, bundle, 'Contents', 'MacOS', bundle.delete_suffix('.app')),
                 "#!/bin/bash\necho real launcher\n")
    end
  end

  def teardown
    FileUtils.remove_entry(@source) rescue nil
    FileUtils.remove_entry(@target) rescue nil
  end

  test "install drops both wrapper bundles into the target dir" do
    capture_stdio do
      Echoes::Installer.install(source_root: @source, target_dir: @target)
    end
    assert Dir.exist?(File.join(@target, 'Echoes.app'))
    assert Dir.exist?(File.join(@target, 'EchoesEmbed.app'))
  end

  test "wrapper Info.plist is a copy of the source Info.plist" do
    capture_stdio do
      Echoes::Installer.install(source_root: @source, target_dir: @target)
    end
    src = File.read(File.join(@source, 'Echoes.app/Contents/Info.plist'))
    dst = File.read(File.join(@target, 'Echoes.app/Contents/Info.plist'))
    assert_equal src, dst
  end

  test "wrapper exec's into the source bundle's launcher" do
    capture_stdio do
      Echoes::Installer.install(source_root: @source, target_dir: @target)
    end
    wrapper = File.read(File.join(@target, 'Echoes.app/Contents/MacOS/Echoes'))
    expected = File.join(@source, 'Echoes.app/Contents/MacOS/Echoes')
    assert_match(/exec "#{Regexp.escape(expected)}"/, wrapper)
    # Wrapper must be executable; otherwise LaunchServices won't run it.
    assert((File.stat(File.join(@target, 'Echoes.app/Contents/MacOS/Echoes')).mode & 0o111) != 0,
           "wrapper script must be executable")
  end

  test "install creates the target dir if missing" do
    nested = File.join(@target, 'fresh-subdir')
    refute Dir.exist?(nested)
    capture_stdio do
      Echoes::Installer.install(source_root: @source, target_dir: nested)
    end
    assert Dir.exist?(File.join(nested, 'Echoes.app'))
  end

  test "install skips bundles that don't exist in the source" do
    FileUtils.remove_entry(File.join(@source, 'EchoesEmbed.app'))
    _out, err = capture_stdio do
      Echoes::Installer.install(source_root: @source, target_dir: @target)
    end
    assert Dir.exist?(File.join(@target, 'Echoes.app'))
    refute Dir.exist?(File.join(@target, 'EchoesEmbed.app'))
    assert_match(/EchoesEmbed.app/, err)
  end

  test "uninstall removes both bundles when present" do
    capture_stdio do
      Echoes::Installer.install(source_root: @source, target_dir: @target)
    end
    capture_stdio do
      Echoes::Installer.uninstall(target_dir: @target)
    end
    refute Dir.exist?(File.join(@target, 'Echoes.app'))
    refute Dir.exist?(File.join(@target, 'EchoesEmbed.app'))
  end

  test "uninstall is a no-op when nothing is installed" do
    out, _ = capture_stdio do
      removed = Echoes::Installer.uninstall(target_dir: @target)
      assert_equal [], removed
    end
    assert_match(/nothing to remove/, out)
  end

  test "default_source_root resolves to the gem root containing the .app bundles" do
    root = Echoes::Installer.default_source_root
    assert Dir.exist?(File.join(root, 'Echoes.app')),
           "expected gem root #{root.inspect} to contain Echoes.app"
  end

  private

  # Capture stdout/stderr so the install/uninstall chatter doesn't
  # spam the test runner.
  def capture_stdio
    require 'stringio'
    sout, serr = StringIO.new, StringIO.new
    real_out, real_err = $stdout, $stderr
    $stdout, $stderr = sout, serr
    yield
    [sout.string, serr.string]
  ensure
    $stdout, $stderr = real_out, real_err
  end
end
