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

## Terminal features

- **Images** — Kitty graphics protocol (PNG via `f=100`, raw RGB /
  RGBA via `f=24` / `f=32`, zlib-compressed payloads with `o=z`,
  file-path transmission via `t=f` / `t=t`, sub-cell pixel offsets,
  placements with `q=` / `a=p` / `a=d`, `z=` for layering — negative
  `z` blits the image beneath cell text, the default `z=0` and any
  positive value blit on top) and iTerm2 inline images
  (OSC 1337 `File=` with PNG / JPEG / TIFF / GIF). **SVG** is also
  rendered by both protocols — detected by content-sniffing the
  payload, rasterized at the cell footprint requested (`c=`/`r=` for
  Kitty, `width=`/`height=` for iTerm2). Path-only SVGs (paths,
  basic shapes, `<g>`, transforms) go through a native CoreGraphics
  fast path — synchronous, no XPC. SVGs containing `<text>`,
  `<filter>`, gradients, `<use>`, etc. fall through transparently
  to a WKWebView backend (slower first paint, but full CSS / SVG
  surface). JavaScript is disabled and external resources blocked
  on both paths.
- **Desktop notifications** — OSC 9 (`\e]9;message\a`, iTerm2 style)
  and OSC 777 (`\e]777;notify;title;message\a`, VTE style) deliver
  to the macOS Notification Center.
- **Programming-font ligatures** — `=>`, `!=`, `<=`, `->`, etc. shape
  through Core Text when the active font (Fira Code, JetBrains Mono,
  …) ships them.
- **Synchronized output (DEC 2026)** — full-frame updates from tmux,
  Neovim, and IDEs land atomically instead of tearing.
- **Find** — Cmd+F opens the search bar; while it's focused, Cmd+R
  toggles regex mode and Cmd+I toggles case-insensitive matching.
- **Pane capture** — a running program can snapshot its own pane to
  disk as raster PNG or vector PDF via `\e]7772;capture` (see below).

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

## Configuration

Echoes reads `~/.config/echoes/echoes.conf` at startup. The file is
plain Ruby `instance_eval`'d against `Echoes.config`; every setter
below has the same name as its config attribute.

```ruby
font_family    "JetBrains Mono"
font_size      14.0
rows           24
cols           80
shell          "/bin/zsh"
scrollback_limit  10_000
tab_position   :top                # or :bottom
window_title   "Echoes"
foreground     "#e0e0e0"
background     "#1a1a2e"
cursor_color   "#b58900"
selection_color "#586e75"
```

### Profiles (color themes)

Two profiles ship built-in (Solarized Dark, Solarized Light), so the
View → Profile submenu has alternatives without any config. Declare
your own — or re-declare a built-in by the same name to override it.
Switching at runtime through the menu repaints the palette, fg/bg,
selection, and cursor without a restart.

```ruby
profile "Tokyo Night" do
  foreground   "#c0caf5"
  background   "#1a1b26"
  cursor_color "#c0caf5"
  selection_color "#283457"
  color_palette %w[
    #15161e #f7768e #9ece6a #e0af68 #7aa2f7 #bb9af7 #7dcfff #a9b1d6
    #414868 #f7768e #9ece6a #e0af68 #7aa2f7 #bb9af7 #7dcfff #c0caf5
  ]
end

default_profile "Tokyo Night"
```

### Custom keybinds

Override any menu shortcut by action symbol. Pass an empty string to
disable a default shortcut entirely.

```ruby
keybind "Cmd+Shift+T", :new_tab
keybind "Cmd+K",       :toggle_find
keybind "",            :toggle_pointer    # disable the default
```

Available actions (one per menu item): `:new_window`, `:new_tab`,
`:close_tab`, `:close_pane`, `:edit_file`, `:split_right`, `:split_down`,
`:select_next_pane`, `:select_previous_pane`, `:show_next_tab`,
`:show_previous_tab`, `:increase_font_size`, `:decrease_font_size`,
`:reset_font_size`, `:toggle_find`, `:find_next`, `:find_previous`,
`:toggle_pointer`, `:toggle_copy_mode`.

Modifier names are case-insensitive and accept the obvious aliases:
`Cmd`/`Command`/`Super`, `Ctrl`/`Control`, `Opt`/`Option`/`Alt`, `Shift`.

## OSC extensions

### Echoes private namespace (OSC 7772)

All Echoes-specific escape sequences live under OSC code `7772`.
Other terminals ignore unknown OSC codes, so emitters degrade
gracefully.

**Background painting** (pane-scoped):

```
\e]7772;bg-color;#rrggbb\a
\e]7772;bg-gradient;type=linear:angle=N:colors=#rrggbb,#rrggbb[,...]\a
\e]7772;bg-fill;color=#rrggbb:rect=row1,col1,row2,col2\a
\e]7772;bg-clear\a
```

`bg-fill` calls accumulate, so a presentation tool can build up a
slide layout (header bar, sidebar, accent stripe) on top of a base
`bg-color` or `bg-gradient`. `bg-clear` wipes both the base layer
and all fills.

**Multicell glyphs** (OSC-66-shaped, with Echoes-only knobs):

```
\e]7772;multicell;<key=value:...>;<text>\a
```

Accepts the standard kitty `s/w/n/d/v/h` keys plus:

- `f=Family Name` — render the glyph(s) in a specific font.
  Proportional fonts (Helvetica, Noto Serif, …) are measured
  per-glyph at layout time so the cells reserved match the actual
  rendered width — `Hello` in Noto Serif at 2× lays out cleanly
  without overflow or gaps.
- `flip=h|v|hv` — mirror the rendered glyph(s) horizontally,
  vertically, or both. Handy for direction-having emojis (e.g.
  flipping 🐇 to face the other way).

`h=` (halign) is honored for non-fractional / proportional text:
the whole string lands in an `s × source_chars` cell block with
the renderer's center / right-align math applied.

These knobs are routed through OSC 7772 rather than OSC 66 so a
future kitty-spec extension claiming the same param names can't
collide with ours.

**Pane snapshots, multi-display, child windows**:

```
\e]7772;capture;<absolute-path.png|.pdf>\a
\e]7772;display-info\a
\e]7772;open-window;display=N:program=<base64-argv>:fullscreen=yes|no\a
```

- `capture` writes a snapshot of the active pane to disk. `.png`
  rasterizes via `NSBitmapImageRep`; anything else (default `.pdf`)
  saves vector — usually smaller and crisper because text and
  background gradients stay resolution-independent.
- `display-info` is a sync query: the host replies on the same pty
  with `\e]7772;display-info;<json>\a`, where `<json>` is an array
  of `{index, w, h, primary, current}` per `NSScreen`. A presentation
  tool uses `current` to pick "anywhere but here" for a second-screen
  slide window.
- `open-window` spawns a child program in a new Echoes window on the
  chosen display. `program` is the argv JSON-encoded then
  base64-wrapped (e.g. `Base64.strict_encode64(JSON.dump(argv))`).
  `fullscreen=yes` uses a borderless, above-menu-bar window covering
  the full screen frame; otherwise the visible frame with default
  chrome.

A small Ruby helper (`Echoes::Client`) lets in-pane Ruby tools emit
these without hand-rolling escape sequences:

```ruby
require 'echoes/client'

Echoes::Client.bg_gradient(from: '#1a1a2e', to: '#16213e', angle: 90)
Echoes::Client.bg_fill('#ff6b35', row1: 0, col1: 0, row2: 2, col2: 79)
Echoes::Client.styled_text("Title", scale: 3, family: "Helvetica Neue")
Echoes::Client.capture("/tmp/slide.pdf")
Echoes::Client.bg_clear
```

`Echoes::Client.styled_text` auto-routes: OSC 66 when only standard
knobs are used (portable), OSC 7772 `;multicell` when an Echoes-only
knob like `family:` is set.

### Compatibility with other terminals

| Code                 | Use                                                       |
|----------------------|-----------------------------------------------------------|
| OSC 4 / 10 / 11 / 12 | Get/set 256-color palette + default fg / bg / cursor      |
| OSC 7                | Working directory (`file://host/path`)                    |
| OSC 9                | iTerm2-style notification — `\e]9;message\a`              |
| OSC 52               | Clipboard read/write                                      |
| OSC 66               | Kitty multicell (standard `s/w/n/d/v/h` only)             |
| OSC 133              | Semantic prompts (FinalTerm / iTerm2 style)               |
| OSC 777              | VTE-style notification — `\e]777;notify;title;message\a`  |
| OSC 1337             | iTerm2 inline images — `\e]1337;File=<args>:<base64>\a`   |
| APC `_G…`            | Kitty graphics protocol (PNG, raw RGB/RGBA, zlib, file)   |
| (sniffed)            | SVG payloads — auto-detected in both image protocols      |
| DECSET 2026          | Synchronized output                                       |

OSC 9 / OSC 777 notifications go through `terminal-notifier` when it's
on `$PATH`, otherwise fall back to `osascript`'s `display notification`
primitive. Echoes-only knobs that would otherwise extend OSC 66 (font
family, mirror flips) live on OSC 7772 `;multicell` instead, so portable
emitters can keep OSC 66 strictly kitty-spec compatible.

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
