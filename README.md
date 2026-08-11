<div align="center">

<img src="docs/images/icon.png" width="96" alt="">

# Rune

**The terminal for humans who run agents.**

<img src="docs/images/switcher.png" width="900" alt="Rune's ⌘K switcher over a terminal, listing five workspaces, one working, one waiting on you, one running a command, each with its agent's mark">

</div>

Built on [libghostty](https://github.com/ghostty-org/ghostty) · [rune.sushant.tech](https://rune.sushant.tech) · [latest release](https://github.com/Sushants-Git/Rune/releases/latest)

---

## Install

macOS 13+, Apple Silicon and Intel. Download the dmg from
[Releases](https://github.com/Sushants-Git/Rune/releases/latest) and drag Rune
into `/Applications`. It's ad-hoc signed, so macOS will call it damaged. It
isn't. Clear the flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Rune.app
```

Or open it and use **System Settings → Privacy & Security → Open Anyway**. It
updates itself after that.

## What it does

<img src="docs/images/palette.png" width="561" alt="The ⌘K switcher: three workspaces, two waiting on you, with the ⌘R rename, ⌘P pin and ⌘W close hints along the bottom">

- `⌘K` opens the switcher. Arrows preview each workspace behind the panel, `⏎`
  keeps it, `⎋` puts you back.
- `⌘N` makes a new workspace.
- `⌘W` closes the highlighted one, with every tab and split in it.
- `⌘P` pins it to the top. Pinned rows stay in the order you pinned them.
- `⌘R` renames it, in place.
- `⌘1`–`⌘9` jump straight to one without opening the list.

Inside a workspace, `⌘T` adds a tab (a strip in the title bar, costing no
vertical space) and `⌘D` / `⌘⇧D` splits the pane right or down.

Every row says what its agent is doing: `working` with a clock, `your turn` when
it stops, nothing when there's nothing worth saying. Read from what each agent
publishes, never off the screen.

| Agent | Read from |
| --- | --- |
| Claude Code | `~/.claude/sessions/<pid>.json`, keyed by pid |
| Codex | the spinner it animates in the terminal title |
| opencode | a plugin, `rune install-opencode-hook` |

Rows without an agent get their program's icon (vim, tmux, docker, psql, k9s and
twenty more), or whatever the project itself ships. Anything can push its own
words onto a row:

```sh
printf '\033]9;Build finished\007'
```

Drag the panel by its search strip and it stays where you drop it.

## Keys

Only what Rune adds. Copy, paste and font size work as they do anywhere else.

| Chord | What it does |
| --- | --- |
| `⌘K` | switch workspace |
| `⌘N` | new workspace |
| `⌘W` | close the terminal, or the `⌘K` row |
| `⌘P` | pin a workspace to the top of `⌘K` |
| `⌘1`–`⌘9` | workspace by position |
| `⌘R` | rename a workspace, in place |
| `⌥1`–`⌥9` | tab by position |
| `⌘T` | new tab |
| `⌘D` / `⌘⇧D` | split right / down |
| `⌘F` | find in the scrollback |
| `⌘G` / `⌘⇧G` | next / previous match |
| `⌘⌥←↑↓→` | focus the pane that way |
| `⌘⇧[` / `⌘⇧]` | previous / next tab |
| `⌘⇧↵` | zoom a pane, or put it back |
| `⌘⌥=` | equalize splits |
| `⌘⇧N` / `⌘⇧W` | new / close window |

Rebind any of them in **Settings → Shortcuts**. Your
`~/.config/ghostty/config` carries over untouched.

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

`install-opencode-hook` writes `~/.config/opencode/plugin/rune.js` and adds it
to the `plugin` list in `opencode.json`, editing that file rather than replacing
it. Restart any running opencode session to pick it up.

## Build

Needs macOS 13+, Zig 0.16.0 (`brew install zig`) and Xcode.

```sh
git clone https://github.com/Sushants-Git/Rune.git && cd Rune
./scripts/fetch-ghostty.sh      # the pinned ghostty checkout
./scripts/build-libghostty.sh   # GhosttyKit.xcframework (slow, once)
./scripts/bundle.sh             # build/Rune.app
```

If it stops on `cannot execute tool 'metal'`, run
`xcodebuild -downloadComponent MetalToolchain` and try again. Releases are cut
by pushing a tag: `git tag v0.13.9 && git push origin v0.13.9`.

[**Design notes**](docs/design-notes.md) cover why it's built this way, and the
parts that cost real debugging time.

## Credit

Key translation, dead keys and IME composition in `GhosttySurfaceView` and
`GhosttyInput` are adapted from Ghostty's own macOS embedding layer (MIT,
Mitchell Hashimoto and Ghostty contributors), which is the reference for getting
that right.
