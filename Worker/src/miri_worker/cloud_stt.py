"""Cloud STT over the OpenAI-compatible /audio/transcriptions contract.

Groq, OpenAI, and any compatible gateway share this shape, so one provider
covers all of them by changing base_url and model. Uses urllib and wave from
the standard library: no SDK, no new dependency in the shipped app.

Push-to-talk sends one request per utterance, so this batches the whole
utterance and posts it on finish_stream rather than streaming partials.
"""

from __future__ import annotations

import asyncio
import io
import json
import os
import struct
import urllib.error
import urllib.request
import uuid
import wave

from .providers import ProviderHealth


class CloudSTTError(RuntimeError):
    """The cloud transcription request could not be completed."""


def _wav_bytes(pcm: bytes, sample_rate: int) -> bytes:
    """Convert float32 PCM to 16-bit WAV, which every Whisper endpoint accepts."""
    if len(pcm) % 4:
        raise ValueError("PCM float32 payload must be sample-aligned")
    count = len(pcm) // 4
    floats = struct.unpack(f"<{count}f", pcm)
    clipped = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, value)) * 32767)) for value in floats)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(clipped)
    return buffer.getvalue()


def _multipart(fields: dict[str, str], audio: bytes) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    parts: list[bytes] = []
    for name, value in fields.items():
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
        )
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"utterance.wav\"\r\nContent-Type: audio/wav\r\n\r\n".encode()
    )
    parts.append(audio)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


class CloudSTTProvider:
    """Batch transcription against an OpenAI-compatible endpoint."""

    def __init__(
        self,
        *,
        base_url: str = "https://api.groq.com/openai/v1",
        model: str = "whisper-large-v3-turbo",
        api_key_env: str = "GROQ_API_KEY",
        language: str | None = "en",
        prompt: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api_key_env = api_key_env
        self.language = language
        self.prompt = prompt
        self.timeout = timeout
        self._active = False
        self._sample_rate = 16_000
        self._audio = bytearray()

    @property
    def _api_key(self) -> str:
        key = os.environ.get(self.api_key_env, "")
        if not key:
            raise CloudSTTError(f"{self.api_key_env} is not set; cloud transcription is unavailable")
        return key

    async def load(self) -> None:
        self._api_key  # fail fast at load rather than mid-utterance

    async def start_stream(self, sample_rate: int) -> None:
        if sample_rate <= 0:
            raise ValueError("sample rate must be positive")
        self._sample_rate = sample_rate
        self._audio.clear()
        self._active = True

    async def accept_audio(self, pcm: bytes) -> str | None:
        if not self._active:
            raise RuntimeError("cloud STT stream is not active")
        if len(pcm) % 4:
            raise ValueError("PCM float32 payload must be sample-aligned")
        self._audio.extend(pcm)
        return None  # batch endpoint: no partials

    def _post(self, audio: bytes) -> str:
        fields = {"model": self.model, "response_format": "json", "temperature": "0"}
        if self.language:
            fields["language"] = self.language
        if self.prompt:
            fields["prompt"] = self.prompt
        body, content_type = _multipart(fields, audio)
        request = urllib.request.Request(
            f"{self.base_url}/audio/transcriptions",
            data=body,
            headers={"Authorization": f"Bearer {self._api_key}", "Content-Type": content_type},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read())
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:200]
            raise CloudSTTError(f"cloud transcription failed ({error.code}): {detail}") from error
        except (urllib.error.URLError, TimeoutError) as error:
            raise CloudSTTError(f"cloud transcription is unreachable: {error}") from error
        return str(payload.get("text", "")).strip()

    async def finish_stream(self) -> str:
        if not self._active:
            raise RuntimeError("cloud STT stream is not active")
        self._active = False
        audio = bytes(self._audio)
        self._audio.clear()
        if not audio:
            return ""
        wav = _wav_bytes(audio, self._sample_rate)
        return await asyncio.to_thread(self._post, wav)

    async def cancel(self) -> None:
        self._active = False
        self._audio.clear()

    async def unload(self) -> None:
        await self.cancel()

    async def health(self) -> ProviderHealth:
        configured = bool(os.environ.get(self.api_key_env))
        detail = (
            f"cloud-stt:{self.model}"
            if configured
            else f"{self.api_key_env} is not set; cloud transcription is unavailable"
        )
        return ProviderHealth(configured, configured, detail)
