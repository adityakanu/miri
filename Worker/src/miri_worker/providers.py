"""Replaceable speech provider contracts and deterministic reference providers."""

from __future__ import annotations

import asyncio
import struct
from dataclasses import dataclass
from typing import AsyncIterator, Protocol


@dataclass(frozen=True, slots=True)
class ProviderHealth:
    loaded: bool
    ready: bool
    detail: str = ""


class STTProvider(Protocol):
    async def load(self) -> None: ...
    async def start_stream(self, sample_rate: int) -> None: ...
    async def accept_audio(self, pcm: bytes) -> str | None: ...
    async def finish_stream(self) -> str: ...
    async def cancel(self) -> None: ...
    async def unload(self) -> None: ...
    async def health(self) -> ProviderHealth: ...


class TTSProvider(Protocol):
    async def load(self) -> None: ...
    async def prepare_voice(self, voice: str | None = None) -> None: ...
    def stream(self, text: str, voice: str | None = None) -> AsyncIterator[bytes]: ...
    async def stop(self) -> None: ...
    async def unload(self) -> None: ...
    async def health(self) -> ProviderHealth: ...


class VADProvider(Protocol):
    def is_speech(self, pcm: bytes) -> bool: ...


class WakeWordProvider(Protocol):
    def detected(self, pcm: bytes) -> bool: ...


class ReferenceSTTProvider:
    """A deterministic provider for contract tests and native integration.

    It validates PCM alignment and reports sample counts rather than pretending to
    perform inference. Real Moonshine support can conform to the same interface.
    """

    def __init__(self, partial_every_bytes: int = 6_400) -> None:
        self.loaded = False
        self.active = False
        self.cancelled = False
        self.sample_rate = 0
        self.audio = bytearray()
        self.partial_every_bytes = partial_every_bytes
        self._last_partial = 0

    async def load(self) -> None:
        self.loaded = True

    async def start_stream(self, sample_rate: int) -> None:
        if not self.loaded:
            raise RuntimeError("STT provider is not loaded")
        if sample_rate <= 0:
            raise ValueError("sample rate must be positive")
        self.active = True
        self.cancelled = False
        self.sample_rate = sample_rate
        self.audio.clear()
        self._last_partial = 0

    async def accept_audio(self, pcm: bytes) -> str | None:
        if not self.active:
            raise RuntimeError("STT stream is not active")
        if len(pcm) % 4:
            raise ValueError("PCM float32 payload must be sample-aligned")
        self.audio.extend(pcm)
        if len(self.audio) - self._last_partial >= self.partial_every_bytes:
            self._last_partial = len(self.audio)
            return f"audio {len(self.audio) // 4} samples"
        return None

    async def finish_stream(self) -> str:
        if not self.active:
            raise RuntimeError("STT stream is not active")
        self.active = False
        if self.cancelled:
            return ""
        return f"audio {len(self.audio) // 4} samples"

    async def cancel(self) -> None:
        self.cancelled = True
        self.active = False
        self.audio.clear()

    async def unload(self) -> None:
        await self.cancel()
        self.loaded = False

    async def health(self) -> ProviderHealth:
        return ProviderHealth(self.loaded, self.loaded, "reference-stt")


class ReferenceTTSProvider:
    """Produces deterministic 24 kHz mono float32 chunks for tests."""

    sample_rate = 24_000

    def __init__(self, chunk_samples: int = 240) -> None:
        self.loaded = False
        self.cancelled = False
        self.voice: str | None = None
        self.chunk_samples = chunk_samples

    async def load(self) -> None:
        self.loaded = True

    async def prepare_voice(self, voice: str | None = None) -> None:
        if not self.loaded:
            raise RuntimeError("TTS provider is not loaded")
        self.voice = voice

    async def stream(self, text: str, voice: str | None = None) -> AsyncIterator[bytes]:
        if not self.loaded:
            raise RuntimeError("TTS provider is not loaded")
        self.cancelled = False
        # One small chunk per character makes streaming and cancellation observable.
        amplitude = 0.1 if voice is None else 0.12
        chunk = struct.pack("<f", amplitude) * self.chunk_samples
        for _ in text:
            if self.cancelled:
                break
            await asyncio.sleep(0)
            yield chunk

    async def stop(self) -> None:
        self.cancelled = True

    async def unload(self) -> None:
        await self.stop()
        self.loaded = False

    async def health(self) -> ProviderHealth:
        return ProviderHealth(self.loaded, self.loaded, "reference-tts")


class EnergyVADProvider:
    def __init__(self, threshold: float = 0.01) -> None:
        self.threshold = threshold

    def is_speech(self, pcm: bytes) -> bool:
        if len(pcm) % 4:
            return False
        samples = struct.iter_unpack("<f", pcm)
        return any(abs(sample[0]) >= self.threshold for sample in samples)


class DisabledWakeWordProvider:
    def detected(self, pcm: bytes) -> bool:
        return False
