# Release checklist

An owner must link evidence for every item. A generated artifact is not evidence
of notarization unless Apple's accepted result and stapler validation are saved.

## Product gates

- [x] `swift test` passes: 98 tests executed, 95 passing, 3 skipped, 0 failures.
      The 3 skips are environment-dependent — they assert the
      *not-installed* model path and are skipped on machines that already have
      Parakeet or the PocketTTS voice downloaded.
- [ ] Manual matrix passes on physical M4 and M1: microphones, Bluetooth,
      monitors, notch/non-notch, permissions, Reduce Motion, and VoiceOver.
- [ ] Codex live compatibility is recorded. Claude Code and Hermes are labelled
      experimental for 0.1.4 unless equivalent live evidence is captured.
- [ ] Clean-machine DMG install works without Xcode, and works offline after the
      one-time model download.
- [ ] M4 benchmark report passes all locked gates. The current report is stale
      and partial; see `docs/benchmarks.md`. It must be recollected against the
      CoreML-only build before release.
- [ ] M1 benchmark report is published; any failures are called out as
      best-effort support rather than hidden.
- [ ] Privacy/data deletion and offline behavior are manually verified,
      including that **Delete Models** and **Reset All Data** clear *both*
      `~/Library/Application Support/FluidAudio/Models` and
      `~/.cache/fluidaudio`.
- [ ] The one-time ~1 GB consent prompt appears before any download, and
      refusing it leaves Miri in a working, non-downloading state.

## Scope gates for 0.1.4

- [x] Version is centralized: `MiriVersion.current` is `0.1.4` and is the only
      literal source of the product version in Swift.
- [x] Parakeet is the only user-selectable transcription backend
      (`STTBackend.supportedCases == [.parakeet]`).
- [x] Push-to-talk is the only user-selectable input mode
      (`MiriInputMode.supportedCases == [.pushToTalk]`).
- [x] Model lifecycle profiles are not user-selectable; no Settings picker
      exists.
- [x] No Python runtime, worker subprocess, or audio IPC remains in the product.
- [x] Hermes does not advertise streaming; only Codex declares `streaming` and
      `interactiveRequests`.
- [ ] Release notes describe only what is exposed in this build. Do not document
      cloud transcription, wake word, or lifecycle profiles as available
      features.

## Dependency and legal gates

- [x] FluidAudio is pinned in `Package.resolved` at `0.15.6`.
- [ ] Model repositories and revisions are recorded in `docs/model-licenses.md`.
- [ ] Model and runtime licenses are reviewed and included (FluidAudio
      Apache-2.0; Parakeet TDT v3 and PocketTTS CC-BY-4.0).
- [ ] SPDX SBOM and artifact SHA-256 are generated and inspected.
- [x] `LICENSE`, `MODEL-LICENSES.md`, and `THIRD-PARTY-NOTICES.md` are copied
      into `Contents/Resources/` by `scripts/build-community.sh`.

## Distribution gates

- [ ] Version agrees across `MiriVersion.current`, the git tag, the packaging
      script argument, `CFBundleShortVersionString`, the DMG name, and the
      release notes.
- [ ] The stale `dist/` artifacts from the pre-CoreML build are deleted and
      rebuilt. The artifacts currently on disk are ~1.0 GB (DMG) and ~687 MB
      (ZIP) and predate the Python removal; they are **not** shippable.
      The rebuilt app is approximately 56 MB.
- [ ] Community artifact is ad-hoc signed after every helper is bundled
      (`miri` and `miri-mcp` in `Contents/Helpers/`).
- [ ] `codesign --verify --deep --strict` succeeds on the staged app.
- [ ] The signature remains valid after first run; nothing writes into the
      bundle.
- [ ] DMG contains both `Miri.app` and the `/Applications` drag target.
- [ ] Clean-machine Gatekeeper flow works using
      **Privacy & Security → Open Anyway**.
- [ ] `Miri-<version>.dmg`, ZIP, and `.sha256` are attached to one GitHub
      Release.
- [ ] A fresh user can launch without Xcode, consent to the ~1 GB model
      download, install Codex MCP, and complete STT → agent → TTS.
- [ ] The bundle is arm64-only and refuses to install on Intel with a clear
      message rather than failing at first use.

## Known limitations to disclose in the release

- Free community artifacts are ad-hoc signed, **not** Developer-ID notarized;
  users need the Gatekeeper **Open Anyway** flow.
- Apple Silicon only, macOS 14+.
- English voice only; no custom vocabulary, multilingual catalog, spoken
  correction, mobile/remote relay, or worktree/diff dashboard.
- Codex is the live-validated adapter. Claude Code and Hermes are experimental.
- PocketTTS runs at FluidAudio's default GPU-backed placement, not on the Neural
  Engine. Only the Parakeet encoder is ANE-resident.
- Benchmark evidence is stale and incomplete and must be recollected.

## Future notarized-channel gates

- [ ] Nested code and app are signed with Developer ID and hardened runtime.
- [ ] Apple notarization returns Accepted; ticket is stapled and validated.
- [ ] Gatekeeper assessment succeeds on a clean machine.
- [ ] `Miri-<version>.dmg`, SPDX SBOM, and `.sha256` are attached to one GitHub
      Release; generated Cask uses that exact DMG checksum.
- [ ] Homebrew install/uninstall and both linked CLI commands are exercised.

## Reproducible commands

For the no-cost community channel:

```sh
scripts/build-community.sh <version>
(cd dist && shasum -a 256 -c Miri-<version>.sha256)
codesign --verify --deep --strict .preview/Miri.app
hdiutil verify dist/Miri-<version>.dmg
```

The Developer-ID/notarized channel below is future work and fails closed when
credentials are missing:

```sh
scripts/build-release.sh <version>
APPLE_SIGN_IDENTITY='Developer ID Application: …' scripts/sign-and-notarize.sh
scripts/create-dmg.sh <version>
APPLE_NOTARY_PROFILE=miri-notary scripts/notarize.sh dist/Miri-<version>.dmg
scripts/release-metadata.sh <version>
```
