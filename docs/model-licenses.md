# Model and runtime license inventory

Miri's community DMG bundles inference code but no speech-model weights. Model
downloads happen only after user consent. The inference runtime is pinned by the
FluidAudio version in `Package.swift`; model repositories and revisions are
pinned by FluidAudio's own registry.

| Component | Intended use | Version/weights | License review | Distribution status |
| --- | --- | --- | --- | --- |
| FluidAudio | CoreML inference runtime (ASR, TTS) | pinned in `Package.swift` | Apache-2.0 | Code linked into the app |
| NVIDIA Parakeet TDT 0.6b v3 | STT | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | CC-BY-4.0 | Weights downloaded after consent |
| Pocket TTS (English) | TTS | FluidInference CoreML conversion; upstream revisions pinned | MIT code; CC BY 4.0 model; selected voice terms vary | Weights/voice downloaded after consent |
| NemoTextProcessing | inverse text normalization | `text-processing-rs` v0.3.0 xcframework | Apache-2.0 | Binary artifact resolved by SwiftPM |

The default Pocket voice is `alba`; Miri downloads it rather than
redistributing it. Users choosing another catalog or local voice are
responsible for that voice's terms and consent.

Miri no longer ships a Python runtime, Moonshine, Silero VAD, or openWakeWord:
those lived in the removed worker process.

Upstream references: [FluidAudio](https://github.com/FluidInference/FluidAudio),
[Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
[Pocket TTS](https://github.com/kyutai-labs/pocket-tts),
[Pocket TTS model card](https://huggingface.co/kyutai/pocket-tts), and
[Pocket voice catalog](https://huggingface.co/kyutai/tts-voices).
