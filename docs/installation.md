# Installation

## Development build

Requirements are Apple Silicon, macOS 14 or newer, Xcode/Swift 6, XcodeGen,
and `uv`:

```sh
brew install xcodegen uv
git clone https://github.com/adityakanu/miri.git
cd miri
make bootstrap test
swift run Miri
```

The development process uses `Worker/.venv`. A release DMG instead contains a
checksum-pinned standalone Python runtime and does not require Python or `uv` on
the user's machine.

## Unsigned preview DMG

Preview releases are published on GitHub without an Apple Developer ID signature
or notarization. The DMG still mounts normally and supports drag-and-drop to
Applications. After downloading from the official GitHub Release, verify its
checksum, move `Miri.app` to Applications, try opening it once, then choose
**System Settings > Privacy & Security > Open Anyway** when macOS blocks the
first launch.

```sh
shasum -a 256 -c Miri-<version>-preview.sha256
```

Unsigned previews are intended for testers who understand this trade-off. Do
not disable Gatekeeper globally, and only override it for an artifact whose
GitHub Release and checksum you have verified.

## Notarized release DMG

No stable DMG has been published from this repository yet. When one is
published, verify it against the `.sha256` file attached to the same GitHub
Release before opening it:

```sh
shasum -a 256 -c Miri-<version>.sha256
```

Open the DMG and drag `Miri.app` to Applications. Miri is an accessory app; its
waveform appears in the menu bar rather than the Dock. Grant microphone access
only when prompted. Configuration is stored at `~/.config/miri/config.toml`.
On first launch, choose **Install or Repair Models** in Miri's settings and
approve the local Moonshine download before using voice input. Miri verifies
each downloaded speech-recognition artifact against its bundled SHA-256 value.

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
