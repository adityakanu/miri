# Release checklist

An owner must link evidence for every item. A generated artifact is not evidence
of notarization unless Apple's accepted result and stapler validation are saved.

## Product gates

- [ ] Swift, Python, contract, adapter conformance, and integration suites pass.
- [ ] Manual matrix passes on physical M4 and M1: microphones, Bluetooth,
      monitors, notch/non-notch, permissions, Reduce Motion, and VoiceOver.
- [ ] Codex, Claude Code, and Hermes live compatibility is recorded.
- [ ] Clean-machine DMG install works without Xcode, Python, `uv`, or network
      after model installation.
- [ ] M4 benchmark report passes all locked gates.
- [ ] M1 benchmark report is published; any failures are called out as
      best-effort support rather than hidden.
- [ ] Privacy/data deletion and offline behavior are manually verified.

## Dependency and legal gates

- [ ] Standalone Python URL/version/SHA-256 is pinned in release configuration.
- [ ] Every model/package/version/weight checksum is pinned.
- [ ] `Worker/models/model-manifest.json` passes `validate_manifest.py`; the
      release build intentionally fails when this file is absent or incomplete.
- [ ] Model and runtime licenses are reviewed and included.
- [ ] SPDX SBOM and artifact SHA-256 are generated and inspected.
- [ ] `LICENSE` and notices are present in the app bundle and source archive.

## Distribution gates

- [ ] Version agrees across tag, app metadata, DMG, and release notes.
- [ ] Community artifact is ad-hoc signed after every helper/runtime is bundled.
- [ ] `codesign --verify --deep --strict` succeeds on the staged app.
- [ ] DMG contains both `Miri.app` and the `/Applications` drag target.
- [ ] Clean-machine Gatekeeper flow works using **Privacy & Security → Open Anyway**.
- [ ] `Miri-<version>.dmg`, ZIP, and `.sha256` are attached to one GitHub Release.
- [ ] A fresh user can launch without Xcode, Python, or `uv`, consent to model
      download, install Codex MCP, and complete STT → agent → TTS.

## Future notarized-channel gates

- [ ] Nested code and app are signed with Developer ID and hardened runtime.
- [ ] Apple notarization returns Accepted; ticket is stapled and validated.
- [ ] Gatekeeper assessment succeeds on a clean machine.
- [ ] `Miri-<version>.dmg`, SPDX SBOM, and `.sha256` are attached to one GitHub
      Release; generated Cask uses that exact DMG checksum.
- [ ] Homebrew install/uninstall and both linked CLI commands are exercised.

## Reproducible commands

```sh
MIRI_PYTHON_STANDALONE_ARCHIVE=/path/python.tar.gz \
MIRI_PYTHON_STANDALONE_SHA256=<sha256> scripts/build-release.sh <version>
APPLE_SIGN_IDENTITY='Developer ID Application: …' scripts/sign-and-notarize.sh
scripts/create-dmg.sh <version>
APPLE_NOTARY_PROFILE=miri-notary scripts/notarize.sh dist/Miri-<version>.dmg
scripts/release-metadata.sh <version>
```

For the no-cost community channel, run `scripts/build-community.sh <version>
<standalone-python>`; it creates the normal `Miri-<version>.dmg` and ZIP with
an ad-hoc signature. The commands above are
the future Developer-ID/notarized channel and fail closed when credentials are
missing.
