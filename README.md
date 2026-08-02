# Rune

A macOS terminal built on [libghostty](https://github.com/ghostty-org/ghostty).

Ghostty does the hard part — VT parsing, pty, font shaping, Metal rendering.
Rune is the app shell around it: windows, workspaces, tabs, splits, and the
switcher.

## Three axes: splits, tabs, workspaces

The usual problem with tabs is that the strip is the only way in, so every
terminal you open has to earn a slot in it — and past about eight, the labels
truncate to the point where you're picking by position rather than by name.

Rune gives you three places to put things, and each list holds exactly one kind
of thing:

- **`⌘D` / `⌘⇧D` split the terminal** right or down, Ghostty-style. Panes are
  side by side on screen, with a draggable divider between them. `⌘⌥`+arrows
  move the keyboard between them, and the panes you *aren't* typing in recede
  slightly. Nothing is drawn on top of the active one — no outline, no glow, no
  shadow — because that's the pane you're reading.
- **`⌘T` makes a tab**, in the workspace you're looking at. It gets a chip in
  the strip, one click away. The strip lives *inside* the title bar, next to the
  window controls, so it costs no vertical space at all. A tab is a whole split
  layout, not a single terminal.
- **`⌘N` makes a workspace.** Workspaces don't appear in any strip — they're
  what `⌘K` lists. Open as many as you like; each one's strip stays short.

So: the strip is the current workspace's tabs, and `⌘K` is the workspaces.
Everything lives in the *same* macOS window — switching is instant and nothing
moves on screen but the terminal itself. `⌘⇧N` is the escape hatch to a
genuinely separate window when you want one on another display or Space.

**A workspace with one tab shows no strip at all** — there's nothing to choose
between, so the title bar just names what's running, centred.

`⌘K` is the switcher:

- **Always in creation order**, and it opens on the workspace you're already in.
  Picking one doesn't move it in the list — the order you learn is the order it
  keeps.
- **`↑`/`↓` preview.** Moving the selection swaps that workspace in behind the
  overlay so you can see what you're about to pick. `⏎` keeps it; `⎋` (or a
  click outside) puts you back where you started, having selected nothing.
- **`⌘R` renames the highlighted row**, in place — the name turns into a text
  field where it already sits, rather than a dialog stacked on the switcher.
  `⏎` saves, `⎋` reverts, and an empty name hands it back to the terminal.
  Pressing `⌘R` with the switcher closed opens it first, since that's where the
  name lives.
- Anything that takes over the screen — `⌘T`, `⌘N`, `⌘D`, `⌘⇧N`, clicking a tab
  — puts the switcher away and goes there. Unlike `⎋` it doesn't rewind: you
  asked for the new thing while looking at the previewed workspace, so that's
  where it lands.
- Type to filter by the name on the row, and nothing else (subsequence match,
  so `usl` finds `usr-local`). Matching against directories or background tabs
  made rows light up for reasons you couldn't see on screen.
- `⌃P`/`⌃N` work too.
- A `current` badge marks where you came from, and a count marks whichever
  thing a workspace has more than one of — tabs, or panes when it's a single
  split tab.

The title bar is painted in the terminal's own background color, so the window
reads as one surface rather than a terminal wearing a grey hat.

## Knowing which agent wants you

Every row in `⌘K` says what that workspace is doing, in words:

| | |
| --- | --- |
| *(nothing)* | a shell, or an agent that publishes no state |
| `working` | the agent is mid-turn |
| `your turn` | it has stopped, whether at its prompt or on a question it wants answered |

Two states and silence, deliberately. There was a third, `needs you`, for an
agent holding a permission prompt open or ringing the bell, and it didn't earn
the distinction: "blocked on you" and "finished and waiting" are the same
instruction, so a third colour to decode bought nothing. What it was stuck on
survives as the detail beside the label.

There is deliberately **no "a command is running" state**. Rune had one, inferred
from how recently libghostty asked for a frame, and it was always wrong: the
renderer also asks for a frame every time the cursor blinks, every 600ms,
forever. Every focused terminal claimed to be running something for as long as
it was open. Knowing a plain command is running needs shell integration
(OSC 133), not a guess.

An agent can also say so itself, **pushed rather than inferred**: OSC 9 and OSC 777 are the standard
"show a desktop notification" escape sequences; libghostty decodes them and
hands Rune the title and body, so when an agent asks for you it says so
directly, instantly, and at no cost. The body becomes the text on the ⌘K row —
whatever the agent chose to say, rather than a guess. Anything with a hook
system can be pointed at the same sequence:

```sh
printf '\033]9;Build finished\007'
```

Claude Code emits OSC 9 when its notification channel is set to `iterm2` or
`iterm2_with_bell` (`/config` → Notification channel). The `kitty` channel uses
OSC 99, which this pinned libghostty doesn't decode; `terminal_bell` still
works but carries no text.

`working` and `your turn` come from what the agent publishes about itself:

- **Claude Code** keeps `~/.claude/sessions/<pid>.json` current for every live
  session, with a `status` of `busy`, `idle` or `waiting` and a `waitingFor`
  reason. It's keyed by **process id**, which is exactly what a terminal knows
  about the program running in it — so there is no matching heuristic to get
  wrong. Rune walks up the process tree from the pty's foreground group, since
  running something from inside an agent puts a child in the foreground.
- **Codex** has no equivalent, so it reads `~/.codex/sessions/<date>/rollout-*.jsonl`
  for its explicit `task_started` / `task_complete` events, matched to a
  terminal by the `cwd` in the log header.
- **opencode** publishes nothing readable, so its terminals get an icon and no
  indicator.

Matching on pid matters more than it sounds. Rune previously picked "the newest
transcript in this directory", which is simply wrong once a directory has
several sessions in it — this repo routinely has four, so panes showed each
other's state.

Rune does **not** ask libghostty for the rendered screen. `ghostty_surface_read_text`
takes the same lock the IO thread holds while parsing output, so doing it under
a busy agent stalled the main thread and made scrolling stutter.

None of it runs on the main thread. `AgentMonitor` polls on a background queue
(~300µs per terminal); the main thread's whole share is one `tcgetpgrp` each.
`AgentSession.swift` is the one file to touch when an agent changes format.

The tab strip carries the same state as a dot, since a chip has no room for
words; hovering one spells it out.

## Keybindings

| Key | Action |
| --- | --- |
| `⌘D` / `⌘⇧D` | Split right / down |
| `⌘⌥←↑↓→` | Focus the pane in that direction |
| `⌘⇧↵` | Zoom the focused pane to fill the tab, or put it back |
| — | While zoomed, the title bar shows a restore button (see below) |
| `⌘⌥=` | Equalize the splits |
| `⌘K` | Switch to workspace… |
| `⌘R` | Rename the workspace, in place in `⌘K` |
| `⌘P` | Pin the highlighted workspace to the top of `⌘K` (see below) |
| `⌘C` | Close the highlighted workspace, in `⌘K` (see below) |
| `⌘T` | New tab in this workspace |
| `⌘N` | New workspace |
| `⌘⇧N` | New window |
| `⌘W` | Close the focused terminal |
| `⌘⇧W` | Close the window |
| `⌘⇧]` / `⌘⇧[` | Next / previous tab |
| `⌘1`–`⌘9` | Jump to a workspace by position in `⌘K` |
| `⌥1`–`⌥9` | Jump to a tab by position |
| `⌘C` / `⌘V` | Copy / paste |
| `⌘+` / `⌘-` / `⌘0` | Font size |

A zoomed pane covers its siblings, which leaves it looking exactly like a tab
that only ever had one terminal in it — the same trap Ghostty solves with its
reset-zoom button. Rune puts an accent-coloured restore glyph at the trailing
end of the title bar for as long as a pane is zoomed, and clicking it undoes
the zoom, so the state is both visible and one click from reversible. Moving to
another pane already unzooms on its own, since focusing something you can't see
would be worse.

`⌘P` pins the highlighted workspace to the top of the list, and pinned rows
stay in **the order you pinned them** — pinning A then B leaves A above B, not
wherever they happen to sit in creation order. That's the point: pinning twice
is how you build the order you want. Unpinning drops a workspace back among the
unpinned ones, still in creation order. Pinned rows carry a pin glyph, so an
order you chose never has to be reverse-engineered from the list.

The list `⌘K` shows is also what `⌘1`–`⌘9` address, so the number you press is
always the position you can see, pinned or not. Pins live for as long as the
window does; they aren't written to disk.

`⌘C` means copy everywhere except one place: with `⌘K` open it closes the
highlighted workspace and every tab and split in it. The panel stays up, since
the reason to close from a list is usually that there are several to clear, and
a dialog that dismissed itself after each one would make that four `⌘K`s.
Closing the last workspace closes the window, exactly as `⌘W` on the last
terminal does.

The override is scoped to the switcher being open and not mid-rename, so copying
out of a terminal — which a terminal may never lose — is untouched. It has to be
caught in a local event monitor rather than a menu item or `performKeyEquivalent`:
a menu key equivalent is matched before the responder chain runs, so Copy would
otherwise always win.

Everything else — scrollback, selection, mouse reporting, colors — is
libghostty, and it reads your existing `~/.config/ghostty/config`.

## Building

Requires macOS 13+, Zig 0.16.0 (`brew install zig`), and Xcode.

```sh
./scripts/fetch-ghostty.sh      # clone the pinned ghostty checkout
./scripts/build-libghostty.sh   # build GhosttyKit.xcframework (slow, once)
./scripts/bundle.sh             # build Rune and assemble build/Rune.app
open build/Rune.app
```

A plain `bundle.sh` builds for the machine you're on. Released builds are
universal, which needs a universal libghostty underneath it — a Swift build for
x86_64 can't link an arm64-only xcframework, and the failure is a wall of
missing symbols rather than anything that says "wrong architecture":

```sh
TARGET=universal ./scripts/build-libghostty.sh
ARCH=universal ./scripts/bundle.sh
```

`bundle.sh` runs the libghostty build for you if the xcframework is missing.

Both scripts build optimized by default, which matters more than it usually
does: libghostty is the renderer, the VT parser and the font shaper, so a Zig
`Debug` build of it does not feel like a debug build, it feels like a slow
terminal. If you actually want to debug into ghostty or Rune:
`MODE=Debug ./scripts/build-libghostty.sh` and `CONFIG=debug ./scripts/bundle.sh`.

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
Sources/Rune/
  Ghostty/
    GhosttyApp.swift          libghostty app handle + runtime callbacks
    GhosttySurfaceView.swift  NSView hosting one surface; input forwarding
    GhosttyInput.swift        AppKit <-> libghostty key/modifier translation
  TerminalController.swift    one window: N workspaces, one tab visible
  Split.swift                 a tab's split tree: panes, dividers, focus
  TabBar.swift                the ⌘T strip, drawn inside the title bar
  Activity.swift              the states a terminal can be in, and how they read
  AgentSession.swift          reads agent state from their own session logs
  AgentIcon.swift             agent detection + their marks, as inline SVG
  ProjectIcon.swift           finds the favicon / launcher icon a repo ships
  SwitcherOverlay.swift       the ⌘K backdrop the palette floats on
  SwitcherPalette.swift       the switcher's filter field, list, ⌘R renaming
  Updater.swift               in-app updates, fed from the GitHub Releases API
  UpdatePill.swift            the update's only chrome: a pill in the title bar
  AppDelegate.swift           menus, windows, libghostty action handling
```

`vendor/ghostty` is a plain checkout pinned by `GHOSTTY_COMMIT`, not a
submodule, and is gitignored.

### Notes on the embedding API

Four things that cost real debugging time, recorded so they don't again:

- `ghostty_surface_set_occlusion` takes **`visible`**, not `occluded`. Passing
  it backwards silently stops the renderer — you get a correctly sized window
  that draws nothing.
- The surface view must be **flipped**. libghostty installs its own
  layer-hosting `CALayer` and draws its `IOSurface` with top-left gravity.
- Because libghostty owns that layer, anything Rune wants to draw *on* a
  terminal — the split focus outline, for one — needs a wrapper view of its
  own. That's what `SplitPane` is for.
- `NSImage(data:)` decodes SVG, undocumented but real (you get an
  `_NSSVGImageRep`). That's why `AgentIcon` keeps the marks as markup instead
  of hand-translating them into bezier paths. Its parser does **not** handle
  packed elliptical-arc flags, though: `a.637.637 0 000 1.272` renders as a
  mangled shape with its cut-outs filled in. Space the flags out —
  `a.637 .637 0 0 0 0 1.272` — and it's correct. Most SVGs off the web are
  minified into the packed form, so this bites immediately.

### Development

`RUNE_DEMO=<n>` floats the window (so it stays capturable while you inspect
it) and opens `n` extra workspaces in known directories, some with a second tab,
before dropping into the switcher — for exercising the UI without driving the
app through synthetic keystrokes. `RUNE_DEMO=0` just floats a plain window.

## Platforms

macOS 13 or newer, on Apple silicon and Intel — released builds are universal,
so one download covers both.

There is no Linux or Windows build, and there can't be a cheap one. libghostty
is portable and Ghostty itself ships a GTK app on Linux, but that portability
stops at the terminal: everything Rune adds — workspaces, the split tree, the
⌘K switcher, the tab strip in the title bar — is AppKit, across most of the
files in `Sources/Rune`. A Linux port isn't a build-system change or a
conditional import, it's writing that UI a second time against GTK, with a
second set of behaviours to keep in step forever after. Worth doing only as a
deliberate decision to become a cross-platform project, not as a packaging step.

## Releasing and updating

Pushing a `v*` tag builds a universal `Rune.app` on CI and attaches the zip to a
GitHub Release:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

`.github/workflows/release.yml` caches `GhosttyKit.xcframework` against
`GHOSTTY_COMMIT`, so only releases that move ghostty pay for the Zig build. The
tag is what sets `CFBundleShortVersionString`; nothing in the repo records a
version otherwise.

Rune then updates itself from that same Release. It checks at most once a day,
says nothing unless it finds something, and puts a pill at the trailing end of
the title bar when it does — one click to download, one to restart into it.
`Check for Updates…` in the app menu does the same thing on demand and, unlike
the automatic check, reports finding nothing.

Ghostty does this with Sparkle and a hosted appcast. Rune doesn't, because the
GitHub Releases API already *is* the appcast, and Sparkle's real value — a signed
appcast validated against a Developer ID — is exactly the part Rune can't use
until it has a signing certificate. Until then the update is trusted because it
came over HTTPS from a release only the repo's owner can write, and before
anything is swapped in, `Updater.verify` checks the download is Rune, is the
version the release claimed, and passes `codesign --verify`. That last check
proves integrity, not authorship; `Updater.swift` says so where it matters, and
that's the line to tighten when a Developer ID exists.

Updates are disabled entirely when Rune isn't running from a `.app` — a
`swift build` binary has nothing to replace.

### Homebrew

`scripts/make-cask.sh` generates the cask for a released version, with the
sha256 taken from the bytes GitHub actually serves rather than from a local
build — two builds of the same commit aren't byte-identical, and a checksum that
matches only the machine that made it is worse than none:

```sh
VERSION=0.6.0 ./scripts/make-cask.sh > Casks/rune.rb
```

The cask lives in a **tap repository**, a separate GitHub repo named
`homebrew-rune`, because that's where `brew tap` looks:

```sh
brew tap-new Sushants-Git/rune       # creates homebrew-rune locally
# drop Casks/rune.rb in, push it to github.com/Sushants-Git/homebrew-rune
brew tap sushants-git/rune
brew install --cask rune
```

Two things have to be true before that works, and neither is a packaging
problem:

- **The repository must be public.** Homebrew downloads the release asset over
  plain HTTPS with no credentials, so a private repo is a 404 to it — which is
  exactly what `brew audit` reports today. This blocks a personal tap just as
  much as the official one.
- **Gatekeeper.** Rune is ad-hoc signed, so macOS refuses it on first launch
  until the user clears quarantine by hand. Homebrew's own rules say a cask
  "must not require System Integrity Protection or Gatekeeper to be disabled or
  bypassed", so `homebrew/cask` proper is off the table until Rune is signed
  with a Developer ID and notarized. A personal tap still works — users just
  hit the same first-launch dialog as with the zip.

The generated cask declares `auto_updates true`, since Rune updates itself; that
stops Homebrew treating a self-updated copy as a version mismatch. It passes
`brew style` clean.

### Testing an update

`RUNE_TEST_UPDATE` drives the whole thing against a local feed, which beats
cutting a release to find out whether the swap works:

```sh
# serve a fake feed + a zip built with a higher VERSION
VERSION=0.9.0 ./scripts/bundle.sh
RUNE_UPDATE_FEED=http://127.0.0.1:8731/latest.json \
  RUNE_TEST_UPDATE=1 /path/to/installed/Rune.app/Contents/MacOS/Rune
```

`=check` stops before installing, `=pill` writes each state's chrome to
`/tmp/rune-pill-*.png` for looking at without a screen-recording entitlement.

## Credit

The input handling in `GhosttySurfaceView` and `GhosttyInput` is adapted from
Ghostty's own macOS embedding layer (MIT, Mitchell Hashimoto and Ghostty
contributors). Getting key translation, dead keys, and IME composition right is
subtle and their implementation is the reference.
