# Architecture

Miri separates native product behavior from replaceable inference. `MiriCore`
contains agent-neutral contracts, routing policy, and the speech engines.
`MiriApp` owns UI and audio.

Speech runs in-process on CoreML via FluidAudio, on the Apple Neural Engine:
`ParakeetTranscriber` for STT and `FluidSpeechSynthesizer` for TTS. Microphone
samples reach the model as a direct call, so no audio crosses a process
boundary. `MiriIPC` remains the versioned framing layer for the MCP helper and
control socket, not for audio.

Optional cloud transcription (`CloudSTTProvider`) targets any OpenAI-compatible
`/audio/transcriptions` endpoint and is off by default.

No Codex-specific type is permitted in core routing or UI. Adapters belong in
separate modules and conform to `AgentAdapter`.
