# kterm

A macOS terminal built on [libghostty](https://github.com/ghostty-org/ghostty),
with **no tab bar**. You open as many terminals as you like and move between
them with `⌘K` instead of clicking tabs.

Ghostty does the hard part — VT parsing, pty, font shaping, Metal rendering.
kterm is the app shell around it: window, tabs, and the switcher.

## Why no tab bar

A tab bar costs vertical space permanently to solve a problem you have
occasionally, and it stops scaling past about eight tabs — the labels truncate
to the point where you're picking by position rather than by name.

So kterm drops it. Tabs still exist and still run in the background; they're
just reached by name:

- `⌘K` opens the switcher, ordered most-recently-used with the **current tab
  demoted to the bottom**. That makes `⌘K ⏎` a toggle between the two terminals
  you're actually working in.
- Type to filter by title or working directory (subsequence match, so `usl`
  finds `/usr/local`).
- `↑`/`↓` or `⌃P`/`⌃N` to move, `⏎` to switch, `⎋` to dismiss.

## Keybindings

| Key | Action |
| --- | --- |
| `⌘K` | Switch to tab… |
| `⌘T` | New tab (inherits the current tab's working directory) |
| `⌘N` | New window |
| `⌘W` | Close tab |
| `⌘⇧]` / `⌘⇧[` | Next / previous tab |
| `⌘1`–`⌘9` | Jump to tab by index |
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

`KTERM_DEMO=<n>` opens `n` extra tabs in known directories and drops straight
into the switcher, for exercising the tab UI without driving the app through
synthetic keystrokes.

## Credit

The input handling in `GhosttySurfaceView` and `GhosttyInput` is adapted from
Ghostty's own macOS embedding layer (MIT, Mitchell Hashimoto and Ghostty
contributors). Getting key translation, dead keys, and IME composition right is
subtle and their implementation is the reference.
