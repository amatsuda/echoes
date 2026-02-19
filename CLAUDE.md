# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Nutty is a Ruby gem (currently a freshly scaffolded template at v0.1.0). Author: Akira Matsuda. Requires Ruby >= 3.2.0. Licensed under MIT.

## Commands

- **Install dependencies:** `bin/setup`
- **Run all tests:** `bundle exec rake test` (or just `bundle exec rake`, test is the default task)
- **Run a single test file:** `bundle exec ruby -Ilib:test test/nutty_test.rb`
- **Run a single test method:** `bundle exec ruby -Ilib:test test/nutty_test.rb -n test_method_name`
- **Interactive console:** `bin/console`
- **Install gem locally:** `bundle exec rake install`

## Architecture

Standard Ruby gem layout:

- `lib/nutty.rb` — Main module entry point (defines `Nutty` module)
- `lib/nutty/version.rb` — Version constant
- `sig/nutty.rbs` — RBS type signatures
- `test/` — Tests using **test-unit** framework (not minitest, not rspec)

## Testing

Uses the **test-unit** gem (~> 3.0). Test classes inherit from `Test::Unit::TestCase`. Test helper is at `test/test_helper.rb`.

## CI

GitHub Actions runs `bundle exec rake` on push to master and on pull requests (Ruby 4.1.0, ubuntu-latest).
