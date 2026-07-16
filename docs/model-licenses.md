# Model and runtime license inventory

Miri's community DMG bundles provider code but no speech-model weights. Model
downloads happen only after user consent. Python package artifacts and hashes
are locked in `Worker/uv.lock`; Moonshine download files are independently
pinned in `Worker/models/model-manifest.json`.

| Component | Intended use | Version/weights | License review | Distribution status |
| --- | --- | --- | --- | --- |
| Moonshine Small Streaming (English) | STT | `moonshine-voice` 0.0.68; exact URLs, sizes, SHA-256 values | MIT code and English models | Weights downloaded after consent |
| Pocket TTS (English) | TTS | `pocket-tts` 2.1.0; upstream configs pin model revisions | MIT code; CC BY 4.0 model; selected voice terms vary | Weights/voice downloaded after consent |
| Silero VAD | endpointing | `silero-vad` 6.2.1 | MIT | Runtime package bundled; no separate Miri download |
| openWakeWord | experimental wake word | `openwakeword` 0.6.0 | Apache-2.0 code; upstream pretrained models are CC BY-NC-SA 4.0 | Code bundled; no wake-word weights bundled or downloaded |
| Standalone CPython runtime | worker runtime | Python 3.13 community-build input | PSF and bundled third-party notices | Runtime bundled |

The default Pocket voice is `alba`; Miri downloads it from Kyutai's voice
catalog rather than redistributing it. Users choosing another catalog or local
voice are responsible for that voice's terms and consent. Experimental wake
word requires an explicit local model path because Miri does not redistribute
the upstream non-commercial pretrained models.

Upstream references: [Moonshine](https://github.com/moonshine-ai/moonshine),
[Pocket TTS](https://github.com/kyutai-labs/pocket-tts),
[Pocket TTS model card](https://huggingface.co/kyutai/pocket-tts),
[Pocket voice catalog](https://huggingface.co/kyutai/tts-voices),
[Silero VAD](https://github.com/snakers4/silero-vad), and
[openWakeWord](https://github.com/dscripka/openWakeWord).
