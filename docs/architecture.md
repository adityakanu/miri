# Architecture

Miri separates native product behavior from replaceable inference. `MiriCore`
contains agent-neutral contracts and routing policy. `MiriIPC` is the versioned
binary framing layer. `MiriApp` owns UI and audio. The Python worker implements
only STT, TTS, VAD, and optional wake-word provider protocols.

No Codex-specific type is permitted in core routing or UI. Adapters belong in
separate modules and conform to `AgentAdapter`.
