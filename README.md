# Rune

**The terminal for humans who run agents.**

Four agents running, four terminals that look identical. Rune keeps them apart
and tells you which one is waiting on you.

Built on [libghostty](https://github.com/ghostty-org/ghostty), which does the
hard part — VT parsing, pty, font shaping, Metal rendering. Rune is the shell
around it: workspaces, tabs, splits, and a switcher that says what each terminal
is doing.

macOS 13+ · Apple Silicon and Intel · [latest release](https://github.com/Sushants-Git/Rune/releases/latest)

---

## Install

Download the disk image from
[Releases](https://github.com/Sushants-Git/Rune/releases/latest) and drag Rune
into `/Applications`.

Rune is signed ad-hoc rather than with a paid Developer ID, so macOS quarantines
the download and calls it damaged. It isn't. Clear the flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Rune.app
```

Or open it, dismiss the warning, and use **System Settings → Privacy & Security
→ Open Anyway**.

After that Rune updates itself — on launch, hourly, and from `Check for
Updates…`.

## What it does

**Three places to put a terminal**, so no list grows past reading it.

| | | |
| --- | --- | --- |
| `⌘D` `⌘⇧D` | **Splits** | panes side by side in one tab |
| `⌘T` | **Tabs** | a strip *inside* the title bar, costing no vertical space |
| `⌘N` | **Workspaces** | whole sets of tabs, reachable only from `⌘K` |

**`⌘K` is the switcher.** Arrows preview the workspace behind the panel, `⏎`
keeps it, `⎋` puts you back. `⌘R` renames a row in place, `⌘P` pins it to the
top, `⌘W` closes it.

**Drag the panel anywhere it isn't covering what you're reading.** Grab it by
the search strip along its top, the way you would a title bar. Nothing snaps —
it goes exactly where you drop it, and a guide brightens when you've lined up
with one. Where you leave it is where it opens next time.

**Every row says what its agent is doing** — `working`, `your turn`, or nothing
at all. Read from what each agent publishes about itself, never from scraping
the screen:

| | |
| --- | --- |
| Claude Code | `~/.claude/sessions/<pid>.json`, keyed by process id |
| Codex | the progress spinner it animates in the terminal title |
| opencode | a plugin — run `rune install-opencode-hook` |

An agent Rune can't read gets its icon and no indicator. A guess shown as fact
is worse than silence.

**Rows without an agent still get a face.** vim, tmux, docker, psql, k9s and
twenty more are recognised by their process, and anything unrecognised falls
back to the icon the project itself ships — a favicon, a launcher icon.

Anything with a hook can push its own words onto a row:

```sh
printf '\033]9;Build finished\007'
```

## Keys

| | |
| --- | --- |
| `⌘K` | switch workspace |
| `⌘T` / `⌘N` / `⌘⇧N` | new tab / workspace / window |
| `⌘D` / `⌘⇧D` | split right / down |
| `⌘⌥←↑↓→` | focus the pane that way |
| `⌘⇧↵` | zoom a pane, or put it back |
| `⌘⌥=` | equalize splits |
| `⌘W` / `⌘⇧W` | close terminal / window |
| `⌘⇧[` `⌘⇧]` | previous / next tab |
| `⌘1`–`⌘9` | workspace by position |
| `⌥1`–`⌥9` | tab by position |
| `⌘R` `⌘P` `⌘W` | in `⌘K`: rename, pin, close |

Scrollback, selection, mouse reporting and colours are libghostty, and it reads
the `~/.config/ghostty/config` you already have.

## The `rune` command

```sh
./scripts/install-cli.sh     # symlinks `rune` onto your PATH
```

```
rune                       open Rune, or bring it to the front
rune <directory>           open a workspace there
rune update                update in place
rune install-opencode-hook teach opencode to report what it's doing
rune --version
```

## Build

Needs macOS 13+, Zig 0.16.0 (`brew install zig`) and Xcode.

```sh
git clone https://github.com/Sushants-Git/Rune.git && cd Rune
./scripts/fetch-ghostty.sh      # the pinned ghostty checkout
./scripts/build-libghostty.sh   # GhosttyKit.xcframework (slow, once)
./scripts/bundle.sh             # build/Rune.app
```

If it stops on `cannot execute tool 'metal'`, run
`xcodebuild -downloadComponent MetalToolchain` and go again.

Releases are cut by pushing a tag:

```sh
git tag v0.13.8 && git push origin v0.13.8
```

## More

[**Design notes**](docs/design-notes.md) — why it's built this way, and the
things that cost real debugging time: reading agent state without touching the
render lock, why there's no "a command is running" indicator, the dmg and icon
pipelines, and what the updater has been wrong about.

## Credit

The input handling in `GhosttySurfaceView` and `GhosttyInput` is adapted from
Ghostty's own macOS embedding layer (MIT, Mitchell Hashimoto and Ghostty
contributors). Getting key translation, dead keys and IME composition right is
subtle, and their implementation is the reference.
