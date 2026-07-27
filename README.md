# kterm

A macOS terminal built on [libghostty](https://github.com/ghostty-org/ghostty).

Ghostty does the hard part — VT parsing, pty, font shaping, Metal rendering.
kterm is the app shell around it: window, tabs, and the switcher.

## Two kinds of terminal

The usual problem with tabs is that the strip is the only way in, so every
terminal you open has to earn a slot in it — and past about eight, the labels
truncate to the point where you're picking by position rather than by name.

kterm splits the two jobs:

- **`⌘T` makes a tab.** It gets a chip in the strip, one click away. The strip
  lives *inside* the title bar, next to the window controls, so it costs no
  vertical space at all.
- **`⌘N` makes a terminal that isn't in the strip.** It's reachable only
  through `⌘K`. Open as many as you like — the strip stays short.

Both kinds show up in `⌘K`, which is the switcher:

- Ordered most-recently-used with the **current terminal demoted to the
  bottom**, so `⌘K ⏎` toggles between the two you're actually working in.
- Type to filter by title or working directory (subsequence match, so `usl`
  finds `/usr/local`).
- `↑`/`↓` or `⌃P`/`⌃N` to move, `⏎` to switch, `⎋` to dismiss.
- A `⌘K` badge marks the terminals that have no chip in the strip.

When the terminal you're in is one of the `⌘N` ones, no chip is highlighted, so
the right side of the strip shows `⌘K · <name>` to tell you where you are.

## Keybindings

| Key | Action |
| --- | --- |
| `⌘K` | Switch to terminal… |
| `⌘T` | New tab, with a chip in the strip |
| `⌘N` | New terminal, reachable only from `⌘K` |
| `⌘⇧N` | New window |
| `⌘W` | Close the current terminal |
| `⌘⇧]` / `⌘⇧[` | Next / previous tab in the strip |
| `⌘1`–`⌘9` | Jump to a tab in the strip by position |
| `⌘C` / `⌘V` | Copy / paste |
| `⌘+` / `⌘-` / `⌘0` | Font size |

Everything else — scrollback, selection, mouse reporting, colors — is
libghostty, and it reads your existing `~/.config/ghostty/config`.

## Building

Requires macOS 13+, Zig 0.16.0 (`brew install zig`), and Xcode.

```sh
./scripts/fetch-ghostty.sh      # clone the pinned ghostty checkout
./scripts/build-libghostty.sh   # build GhosttyKit.xcframework (slow, once)
./scripts/bundle.sh             # build kterm and assemble build/kterm.app
open build/kterm.app
```

`bundle.sh` runs the libghostty build for you if the xcframework is missing.
For a release build: `MODE=ReleaseFast ./scripts/build-libghostty.sh` and
`CONFIG=release ./scripts/bundle.sh`.

### Metal toolchain

Since Xcode 26 the Metal compiler is a separately downloaded component, and
ghostty needs it for its shaders. If the build stops with `cannot execute tool
'metal'`:

```sh
xcodebuild -downloadComponent MetalToolchain
```

On some installs `xcrun metal` still can't find the toolchain after that;
`build-libghostty.sh` detects this and pins `TOOLCHAINS` itself.

## Layout

```
Sources/kterm/
  Ghostty/
    GhosttyApp.swift          libghostty app handle + runtime callbacks
    GhosttySurfaceView.swift  NSView hosting one surface; input forwarding
    GhosttyInput.swift        AppKit <-> libghostty key/modifier translation
  TerminalController.swift    one window, N surfaces, one visible
  TabBar.swift                the ⌘T strip, drawn inside the title bar
  TabPalette.swift            the ⌘K switcher
  AppDelegate.swift           menus, windows, libghostty action handling
```

`vendor/ghostty` is a plain checkout pinned by `GHOSTTY_COMMIT`, not a
submodule, and is gitignored.

### Notes on the embedding API

Two things that cost real debugging time, recorded so they don't again:

- `ghostty_surface_set_occlusion` takes **`visible`**, not `occluded`. Passing
  it backwards silently stops the renderer — you get a correctly sized window
  that draws nothing.
- The surface view must be **flipped**. libghostty installs its own
  layer-hosting `CALayer` and draws its `IOSurface` with top-left gravity.

### Development

`KTERM_DEMO=<n>` opens `n` extra terminals in known directories, alternating
between the two kinds, and drops straight into the switcher — for exercising
the tab UI without driving the app through synthetic keystrokes.

## Credit

The input handling in `GhosttySurfaceView` and `GhosttyInput` is adapted from
Ghostty's own macOS embedding layer (MIT, Mitchell Hashimoto and Ghostty
contributors). Getting key translation, dead keys, and IME composition right is
subtle and their implementation is the reference.
