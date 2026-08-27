# Installation

Miri requires **Apple Silicon** and **macOS 14 or newer**. There is no Intel
build: the Neural Engine that Parakeet transcription depends on does not exist
on Intel Macs. The application is arm64-only.

## Development build

Requirements are Apple Silicon, macOS 14+, Xcode/Swift 6, XcodeGen, and
Homebrew.

```sh
git clone https://github.com/adityakanu/miri.git
cd miri
make bootstrap test
swift run miri-app
```

`swift run miri-app` runs the development app; `miri` is the CLI product.
No Python toolchain, virtual environment, or worker process is involved —
all speech is Swift + CoreML in-process.

## Community DMG

Community releases are published on GitHub. They are **ad-hoc signed but not
Apple Developer-ID notarized**, so macOS Gatekeeper will block the first launch.

1. Download `Miri-<version>.dmg` from the official GitHub Release.
2. Verify the checksum:

   ```sh
   shasum -a 256 -c Miri-<version>.sha256
   ```

3. Open the DMG and drag `Miri.app` to Applications.
4. Try opening it once and let macOS block it.
5. Choose **System Settings → Privacy & Security → Open Anyway**.
6. Launch Miri again.

Do not disable Gatekeeper globally, and only override it for an artifact whose
GitHub Release and checksum you have verified.

The packaged arm64 Release app is approximately **56 MB**, including the `miri`
CLI and `miri-mcp` helper in `Contents/Helpers/`. No inference runtime and no
model weights are embedded.

## First launch and models

Miri is an accessory app: its waveform appears in the menu bar rather than the
Dock. Grant microphone access when prompted. Configuration is stored at
`~/.config/miri/config.toml`.

Before voice input works, open **Settings → Speech → On-device models** and
choose **Download Models**. Miri asks once for consent to download about **1 GB**
from Hugging Face:

- roughly **470 MB** for Parakeet transcription, stored in
  `~/Library/Application Support/FluidAudio/Models`;
- roughly **520 MB** for the PocketTTS voice, stored in
  `~/.cache/fluidaudio/Models`.

Until you consent, Miri refuses every model network fetch. After the download
completes, speech runs entirely offline.

Push-to-talk is the only input mode, and Parakeet is the only transcription
backend, in 0.1.4.

## Notarized release channel

No Developer-ID notarized DMG has been published from this repository yet.
Notarization and official Homebrew Cask submission require a paid Apple
Developer ID and are future work. Do not describe the community artifact as
notarized. A third-party tap may redistribute it, but users will still face the
Gatekeeper prompt.

## Removing Miri

Quit Miri and remove the application. **Reset All Data** inside Miri removes
everything below, including both model roots. To do it manually:

```sh
rm -rf "$HOME/Library/Application Support/Miri"
rm -rf "$HOME/Library/Application Support/FluidAudio/Models"
rm -rf "$HOME/.cache/fluidaudio"
rm -rf "$HOME/Library/Caches/Miri" "$HOME/Library/Logs/Miri"
rm -rf "$HOME/.config/miri"
```

These commands delete downloaded models and settings and cannot be undone.
Removing only `Application Support/Miri` leaves both model downloads behind.
