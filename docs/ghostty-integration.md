# Ghostty Integration

## Version Decision

Checked upstream on 2026-09-10. Keep `GHOSTTY_COMMIT` at
`24f7fb983506469843c824f65e0c0f7cdf33661c` (2026-07-26).
This is a development snapshot, not a stable release. The policy is to adopt
the latest stable only when it advances this pin, never downgrade to stable.

Remote evidence:

- `git ls-remote https://github.com/ghostty-org/ghostty.git HEAD 'refs/tags/v*'`
  reported `v1.3.1` as the highest stable version tag.
- Its annotated tag object is `22efb0be2bbea73e5339f5426fa3b20edabcaa11`,
  dated 2026-03-13; its peeled commit is
  `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- [GitHub's comparison](https://github.com/ghostty-org/ghostty/compare/332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28...24f7fb983506469843c824f65e0c0f7cdf33661c)
  returned `status: ahead`, `ahead_by: 1481`, `behind_by: 0`, and the stable
  commit as `merge_base_commit.sha`. Stable is an ancestor of the current pin.
- Remote HEAD was `fde3449b348d8e36c0d52fd39bb33ea66744b958`. HEAD is not the
  requested stable channel and was not selected.
- `gh api repos/ghostty-org/ghostty/releases/latest` returned HTTP 404.
  Therefore the decision uses the remote stable tags and tag-object API,
  not an assumed GitHub Release or the local shallow history.

Recheck ancestry before any future bump:

```sh
gh api repos/ghostty-org/ghostty/compare/OLD_PIN...STABLE_COMMIT \
  --jq '{status,ahead_by,behind_by,merge_base: .merge_base_commit.sha}'
```

Upgrade only when stable is ahead with zero commits behind. If equal, retain
the pin. If stable is behind, retain the newer pin and record the evidence.
If branches diverge, stop for a deliberate compatibility decision. A shallow
checkout's failed `merge-base --is-ancestor` is not proof of divergence.

## Build Contract

`vendor/ghostty` is an ignored, clean, shallow Git checkout, not a submodule.
`scripts/fetch-ghostty.sh` accepts only a full SHA, fetches that commit without
tags or full-history fallback, and checks it out detached. It refuses local
source changes rather than resetting them. Build scripts always reconcile the
checkout with the pin, even when its directory already exists.

The pinned `build.zig.zon` requires Zig **0.16.0**. Rune enforces that exact
version, not merely a minimum. Both workflows derive it from that file. Both
select Xcode identically and compute the same provenance before cache lookup.

```sh
./scripts/fetch-ghostty.sh
bash scripts/ghostty-provenance.sh                  # inspect native build inputs
./scripts/build-libghostty.sh                      # ReleaseFast, native
bash scripts/ghostty-provenance.sh --check          # verify installed outputs
./scripts/bundle.sh

TARGET=universal ./scripts/build-libghostty.sh
ARCH=universal ./scripts/bundle.sh
```

Use the same `MODE` when building and bundling a non-default libghostty build.
Swift's `CONFIG=debug` does not implicitly request a slow Zig Debug renderer.
Native and universal provenance are deliberately distinct; switching targets
requires rebuilding rather than silently reusing a different build recipe.

The build records inputs in `vendor/ghostty/zig-out/rune-build-info`:

- Full source SHA, Zig version, optimization mode, target and host architecture.
- Xcode version/build, macOS SDK version/build, and Metal compiler identity.
- SHA-256 hashes of the pin and fetch/build/provenance scripts.

Metal's random cryptex mount path is excluded from compiler identity. The
separately installed Xcode Metal toolchain is resolved for both lookup and
build. Missing tools fail early, including on a cache hit.

Before rebuilding, the script removes the old success records, framework and
resource tree, so obsolete slices and resources cannot survive a successful
build. After Zig succeeds, it records checksums for framework files and all
resources. Validation checks input identity, the header against the pinned
source, actual library architectures, resource directories and file checksums.
These are local consistency checks, not cryptographic build attestations.

CI uses an exact `ghostty-v2` cache key derived from the input record, with no
fallback restore keys. It caches framework, resources and provenance together,
and validates hits as well as new builds. Changed source, scripts, Zig, Xcode,
SDK, Metal, mode or architecture invalidates the cache. Warm-cache watches both
workflows and the provenance script. Keep the two setup/key sequences aligned.

Bundling builds a missing framework but **rejects an existing stale or
unstamped one**, with a rebuild instruction. It never invents provenance for
old binaries. Missing themes or terminfo are errors, not warnings. The input
record ships in `Rune.app/Contents/Resources/ghostty-build-info.txt`.

Direct `swift build` bypasses these packaging checks. It is useful for quick
Swift compilation but cannot certify the provenance of an existing binary.

## C Boundary

Use the pinned `include/ghostty.h` embedding API through `GhosttyKit`. This is
not the separate libghostty-vt API, and upstream does not promise the embedding
ABI is stable between commits. Keep Rune's adapter surface small rather than
wrapping every upstream function in a parallel framework:

- `GhosttyApp` owns app/config handles, config reads, the surface registry and
  runtime callback translation. Delegate signatures stay unchanged here.
- `GhosttySurfaceView` owns surface lifetime, rendering, text input and surface
  operations. Copy borrowed C strings before escaping a callback. Keep pointer
  lifetimes inside calls or their explicitly documented completion protocol.
- `GhosttyInput` translates AppKit keys and modifiers into C input structs.
- Config getter calls belong in this adapter, not scattered through UI code.
  The getter takes an untyped pointer; the key and exact C destination type
  must be reviewed together. Avoid a generic Swift `get<T>(key:)` abstraction.

At this pin, `src/config/Config.zig` and `src/config/c_get.zig` define
`background-opacity` as `f64` (Swift `Double`) and `font-size` as `f32`
(Swift `Float`). Opacity now reads the effective config, including themes and
recursive files, instead of reparsing one file. Color reads admit only the
verified `background` and `foreground` keys, preventing a non-color key from
writing into a three-byte color buffer. Synthetic `palette:N` queries are
unsupported and return nil; callers retain their existing fallback colors.
`font-family` is a repeatable string without a C getter conversion at this pin,
so its current optional getter returns nil rather than exposing Zig internals.

Wakeups may arrive off-main and enqueue a tick. Synchronous action and clipboard
completion callbacks rely on the pinned embedding runtime's main-thread call
sites; do not dispatch borrowed action unions asynchronously. Re-audit these
contracts when upgrading. No status-indicator sections or UI controller files
were changed as part of this upkeep.

## Verification

The initial version check did not rebuild libghostty because no upgrade was
selected. A subsequent explicitly authorized native rebuild and bundle run
verified the new provenance path end-to-end on 2026-09-10.

- Remote tag, annotated tag object and ancestry were checked using network Git
  and `gh`, despite the local checkout being shallow.
- Fetching the unchanged pin succeeded and retained the clean shallow checkout.
- Shell syntax checks and YAML parsing passed for the modified scripts/workflows.
- `swift build` initially passed using the existing native framework, compiling
  and linking the Ghostty adapter changes. A later run during concurrent UI
  work failed at `Sources/Rune/SessionPalette.swift:121` because `SessionPalette`
  lacked `NSSearchFieldDelegate` conformance. That UI-owned file was not edited.
- Its bundled header matched the pinned `include/ghostty.h` byte-for-byte.
- A standalone C probe linked to the existing library loaded a config with
  opacity `0.625` and font size `17`, then verified the `double` and `float`
  getters. It passed without rebuilding libghostty.
- Invalid mode/target values were rejected. Provenance validation and bundling
  rejected the existing unstamped framework before a Swift build or packaging.

The authorized build verification passed:

- Parent build directories were verified before running either build script.
- `./scripts/build-libghostty.sh` succeeded with `ReleaseFast`, native arm64,
  and the unchanged pin. It regenerated outputs and validated their provenance.
- Toolchain: Zig `0.16.0`, Xcode `26.6` (`17F113`), macOS SDK `26.5`
  (`25F70`), Apple Metal `32023.883`.
- `./scripts/bundle.sh` compiled the completed Swift sources in release mode
  and produced `build/Rune.app` with an arm64 binary and 592 Ghostty themes.
  The earlier concurrent UI compile error no longer blocked the build.
- A separate `bash scripts/ghostty-provenance.sh --check` passed. Packaged
  provenance, Ghostty resources, terminfo, the opencode plugin, NOTICE and
  licenses matched their input files byte-for-byte.
- `codesign --verify --deep --strict --verbose=2 build/Rune.app` passed for
  the ad-hoc signature. The app's Info.plist passed `plutil -lint`, and
  `otool -L` showed only system library/framework dependencies.
- The vendor checkout remained clean and shallow. No script fixes were needed.
  The app was neither launched nor installed, and no commits were made.

A universal Zig build, CI cache round trip, and interactive terminal smoke
tests remain unverified. Test rendering, keyboard/IME, clipboard, config reload,
search, splits, close callbacks and shutdown after any actual pin change.
