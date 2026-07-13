# Installation

## Development build

Requirements are Apple Silicon, macOS 14 or newer, Xcode/Swift 6, XcodeGen,
and `uv`:

```sh
brew install xcodegen uv
git clone https://github.com/miri-ai/miri.git
cd miri
make bootstrap test
swift run Miri
```

The development process uses `Worker/.venv`. A release DMG instead contains a
checksum-pinned standalone Python runtime and does not require Python or `uv` on
the user's machine.

## Release DMG

No stable DMG has been published from this repository yet. When one is
published, verify it against the `.sha256` file attached to the same GitHub
Release before opening it:

```sh
shasum -a 256 -c Miri-<version>.sha256
```

Open the DMG and drag `Miri.app` to Applications. Miri is an accessory app; its
waveform appears in the menu bar rather than the Dock. Grant microphone access
only when prompted. Configuration is stored at `~/.config/miri/config.toml`.

The Homebrew Cask must refer to the exact same notarized DMG and SHA-256. The
generated release Cask is an attached artifact until it is accepted into a tap.

## Removing Miri

Quit Miri, remove the application, then remove local data only if desired:

```sh
rm -rf "$HOME/Library/Application Support/Miri"
rm -rf "$HOME/Library/Caches/Miri" "$HOME/Library/Logs/Miri"
rm -rf "$HOME/.config/miri"
```

These commands delete downloaded models and settings and cannot be undone.
