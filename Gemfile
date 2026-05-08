# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in echoes.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "test-unit", "~> 3.0"

# In-process shell embedding (phase 1 of the integration). Optional —
# only required when an EmbeddedShell pane is created.
# Path-pinned for local dev; falls back to GitHub master on CI
# (which clones echoes only).
if File.directory?(File.expand_path("../rubish", __dir__))
  gem "rubish-gem", path: "../rubish"
else
  gem "rubish-gem", git: "https://github.com/amatsuda/rubish", branch: "master"
end

# In-process vim-equivalent editor backing Echoes::Editor panes.
# Lazily loaded: only required when an editor pane is created.
# Path-pinned for local dev so edits in the sibling rvim checkout
# pick up immediately; falls back to GitHub master on CI (which
# clones echoes only).
if File.directory?(File.expand_path("../rvim", __dir__))
  gem "rvim", path: "../rvim"
else
  gem "rvim", git: "https://github.com/amatsuda/rvim", branch: "master"
end
