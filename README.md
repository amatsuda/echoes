# Echoes

A pure-Ruby AppKit-based macOS terminal emulator. Echoes aims to be a
well-integrated host for Ruby tooling — embedding [rubish] (a Ruby
shell) and [rvim] (a Ruby vim) as first-class panes, with native
prompt rendering, structured completions, and a private OSC namespace
that lets in-pane Ruby tools drive UI features (gradient backgrounds,
proportional fonts) other terminals can't.

[rubish]: https://github.com/amatsuda/rubish
[rvim]:   https://github.com/amatsuda/rvim

## Requirements

- macOS (uses AppKit via Fiddle; no Linux/Windows support)
- Ruby >= 3.2

## Installation

```sh
gem install echoes
echoes install
```

`echoes install` drops thin `Echoes.app` and `EchoesEmbed.app`
shortcuts into `~/Applications/` so the app shows up in Spotlight,
Dock, and Cmd-Space. Each shortcut is a one-line wrapper that
`exec`s into the gem-bundled launcher; re-run `echoes install` after
each `gem update echoes` to refresh the path. `echoes uninstall`
removes them.

To run from a clone instead:

```sh
git clone https://github.com/amatsuda/echoes
cd echoes
bin/setup
open Echoes.app          # GUI (PTY-spawned shell per pane)
open EchoesEmbed.app     # GUI with rubish embedded per pane
bundle exec exe/echoes -t  # TTY mode
```

## What's in the box

- **Echoes.app** — terminal mode. Spawns the user's `$SHELL` per
  pane via PTY, like any other terminal emulator.
- **EchoesEmbed.app** — same window/UI, but each pane runs `rubish`
  in-process via a per-pane helper subprocess. Line editing, prompt
  rendering, and tab completion happen natively in Echoes (no ANSI
  roundtrip); only command output flows over the pty.
- **Edit File…** (Cmd+Shift+E) — opens an rvim-backed editor pane.
  Insert mode, `:w`, `:q`, search, visual mode, undo — the full vim
  surface. The dialog opens at the active pane's pwd.

## Keyboard shortcuts

| Shortcut                  | Action                                  |
|---------------------------|-----------------------------------------|
| Cmd+N                     | New window                              |
| Cmd+T                     | New tab                                 |
| Cmd+W                     | Close tab                               |
| Cmd+Shift+W               | Close pane                              |
| Cmd+Shift+E               | Edit file… (rvim pane)                  |
| Cmd+D                     | Split pane right                        |
| Cmd+Shift+D               | Split pane down                         |
| Cmd+] / Cmd+[             | Next / previous pane                    |
| Cmd+Shift+] / Cmd+Shift+[ | Next / previous tab                     |
| Cmd++ / Cmd+- / Cmd+0     | Bigger / smaller / reset font           |
| Cmd+F                     | Find                                    |
| Cmd+G / Cmd+Shift+G       | Find next / previous                    |
| Cmd+Shift+P               | Toggle mouse pointer visibility         |
| Cmd+Shift+C               | Toggle copy mode                        |
| Cmd+Ctrl+F                | Enter / leave full screen               |

## OSC extensions

Echoes recognizes a private OSC namespace under code `7772`. Other
terminals ignore unknown OSC codes, so emitters degrade gracefully.

```
\e]7772;bg-color;#rrggbb\a
\e]7772;bg-gradient;type=linear:angle=N:colors=#rrggbb,#rrggbb\a
\e]7772;bg-fill;color=#rrggbb:rect=row1,col1,row2,col2\a
\e]7772;bg-clear\a
```

`bg-fill` calls accumulate, so a presentation tool can build up a
slide layout (header bar, sidebar, accent stripe) on top of a base
`bg-color` or `bg-gradient`. `bg-clear` wipes both the base layer
and all fills.

OSC 66 is also extended:

- `f=Family Name` selects a font family for the multicell glyph.
  Proportional fonts are measured per-glyph at layout time so the
  cells reserved match the actual rendered width — `Hello` in Noto
  Serif at 2× lays out cleanly without overflow or gaps.
- `h=` (halign) is honored for non-fractional / proportional text:
  the whole string lands in a `s × source_chars` cell block, with
  the renderer's existing center / right-align math applied.

A small Ruby helper (`Echoes::Client`) lets in-pane Ruby tools emit
these without hand-rolling escape sequences:

```ruby
require 'echoes/client'

Echoes::Client.bg_gradient(from: '#1a1a2e', to: '#16213e', angle: 90)
Echoes::Client.bg_fill('#ff6b35', row1: 0, col1: 0, row2: 2, col2: 79)
Echoes::Client.styled_text("Title", scale: 3, family: "Helvetica Neue")
Echoes::Client.bg_clear
```

## Development

```sh
bin/setup
bundle exec rake test       # run all tests
bundle exec exe/echoes      # launch from the working tree
bin/console                 # irb with the gem loaded
```

`rake app` syncs `CFBundleVersion` in both bundles' `Info.plist`
files with `Echoes::VERSION` (run after a version bump).

## Contributing

Bug reports and pull requests welcome at
<https://github.com/amatsuda/echoes>.

## License

MIT.
