# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

desc "Build Echoes.app macOS application bundle"
task :app do
  require_relative "lib/echoes/version"

  app_dir = "Echoes.app/Contents"
  mkdir_p "#{app_dir}/MacOS"

  File.write "#{app_dir}/Info.plist", <<~PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleName</key>
      <string>Echoes</string>
      <key>CFBundleIdentifier</key>
      <string>com.github.amatsuda.echoes</string>
      <key>CFBundleVersion</key>
      <string>#{Echoes::VERSION}</string>
      <key>CFBundleExecutable</key>
      <string>Echoes</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
    </dict>
    </plist>
  PLIST

  gem_dir = File.expand_path(__dir__)
  ruby_bin = File.join(RbConfig::CONFIG["bindir"], RbConfig::CONFIG["ruby_install_name"])

  File.write "#{app_dir}/MacOS/Echoes", <<~SHELL
    #!/bin/bash
    exec "#{ruby_bin}" -I"#{gem_dir}/lib" "#{gem_dir}/exe/echoes"
  SHELL
  chmod 0755, "#{app_dir}/MacOS/Echoes"

  puts "Built Echoes.app"
end
