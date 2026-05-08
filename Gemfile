# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in echoes.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "test-unit", "~> 3.0"

# In-process shell embedding (phase 1 of the integration). Optional —
# only required when an EmbeddedShell pane is created.
gem "rubish-gem", path: "../rubish"

# In-process vim-equivalent editor backing Echoes::Editor panes.
# Lazily loaded: only required when an editor pane is created.
gem "rvim", path: "../rvim"
