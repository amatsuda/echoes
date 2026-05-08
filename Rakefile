# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

desc "Sync .app Info.plist CFBundleVersion with Echoes::VERSION"
task :app do
  # The .app bundles (Echoes.app, EchoesEmbed.app) are committed
  # to the repo, including their MacOS/ launcher scripts which
  # locate `lib/` and `exe/echoes` from the script's own path —
  # no per-machine rewrite needed. The one thing that drifts on a
  # version bump is each bundle's Info.plist CFBundleVersion. This
  # task patches that line in place; everything else (launchers,
  # bundle id, package type) is left alone so any hand-edits the
  # bundles have picked up survive.
  require_relative "lib/echoes/version"
  version = Echoes::VERSION

  plists = %w[Echoes.app/Contents/Info.plist EchoesEmbed.app/Contents/Info.plist]
  plists.each do |path|
    unless File.exist?(path)
      warn "skipping #{path}: not found"
      next
    end
    text = File.read(path)
    new_text = text.sub(
      %r{(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)},
      "\\1#{version}\\2"
    )
    if text == new_text
      puts "#{path}: already at #{version}"
    else
      File.write(path, new_text)
      puts "#{path}: CFBundleVersion → #{version}"
    end
  end
end
