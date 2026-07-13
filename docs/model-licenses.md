# Model and runtime license inventory

This file is a release gate, not a claim that model weights are currently
bundled or approved. The current worker contains deterministic reference
providers only. Before enabling or distributing each production provider, pin
its package version, weights revision, download URL, SHA-256, license text, and
attribution requirements in the release evidence.

| Component | Intended use | Version/weights | License review | Distribution status |
| --- | --- | --- | --- | --- |
| Moonshine Small Streaming | STT | Not pinned | Required | Not bundled |
| Pocket TTS | TTS | Not pinned | Required | Not bundled |
| Silero VAD | endpointing | Not pinned | Required | Not bundled |
| openWakeWord | experimental wake word | Not pinned | Required | Not bundled |
| Standalone CPython runtime | worker runtime | CI input, checksum required | Required per release | Packaging scaffold only |

Release reviewers must attach the upstream license text and verify that model
weight terms permit redistribution. An SPDX SBOM describes packaged software,
but it does not replace model-weight license review.
