"""Cloud STT provider checks. No network: the HTTP call is stubbed."""

from __future__ import annotations

import io
import struct
import urllib.error
import wave

import pytest

from miri_worker.cloud_stt import CloudSTTError, CloudSTTProvider, _multipart, _wav_bytes
from miri_worker.registry import ProviderConfig, create_providers


def _pcm(values: list[float]) -> bytes:
    return struct.pack(f"<{len(values)}f", *values)


def test_wav_bytes_round_trips_as_16bit_mono():
    data = _wav_bytes(_pcm([0.0, 0.5, -0.5, 1.0]), 16_000)
    with wave.open(io.BytesIO(data), "rb") as handle:
        assert handle.getnchannels() == 1
        assert handle.getsampwidth() == 2
        assert handle.getframerate() == 16_000
        frames = handle.readframes(handle.getnframes())
    assert struct.unpack("<4h", frames) == (0, 16383, -16383, 32767)


def test_wav_bytes_clips_out_of_range_samples():
    data = _wav_bytes(_pcm([2.0, -2.0]), 16_000)
    with wave.open(io.BytesIO(data), "rb") as handle:
        frames = handle.readframes(handle.getnframes())
    assert struct.unpack("<2h", frames) == (32767, -32767)


def test_wav_bytes_rejects_misaligned_pcm():
    with pytest.raises(ValueError):
        _wav_bytes(b"\x00\x00\x00", 16_000)


def test_multipart_includes_fields_and_file():
    body, content_type = _multipart({"model": "whisper-large-v3-turbo"}, b"AUDIO")
    boundary = content_type.split("boundary=")[1]
    assert f"--{boundary}".encode() in body
    assert b'name="model"' in body
    assert b"whisper-large-v3-turbo" in body
    assert b'filename="utterance.wav"' in body
    assert b"AUDIO" in body
    assert body.endswith(f"\r\n--{boundary}--\r\n".encode())


@pytest.mark.asyncio
async def test_finish_stream_posts_buffered_audio(monkeypatch):
    monkeypatch.setenv("GROQ_API_KEY", "test-key")
    provider = CloudSTTProvider()
    posted: dict[str, bytes] = {}

    def fake_post(audio: bytes) -> str:
        posted["audio"] = audio
        return "hello world"

    monkeypatch.setattr(provider, "_post", fake_post)
    await provider.load()
    await provider.start_stream(16_000)
    assert await provider.accept_audio(_pcm([0.1, 0.2])) is None
    assert await provider.finish_stream() == "hello world"
    with wave.open(io.BytesIO(posted["audio"]), "rb") as handle:
        assert handle.getnframes() == 2


@pytest.mark.asyncio
async def test_empty_utterance_makes_no_request(monkeypatch):
    monkeypatch.setenv("GROQ_API_KEY", "test-key")
    provider = CloudSTTProvider()

    def explode(audio: bytes) -> str:
        raise AssertionError("must not post empty audio")

    monkeypatch.setattr(provider, "_post", explode)
    await provider.start_stream(16_000)
    assert await provider.finish_stream() == ""


@pytest.mark.asyncio
async def test_missing_api_key_fails_at_load(monkeypatch):
    monkeypatch.delenv("GROQ_API_KEY", raising=False)
    provider = CloudSTTProvider()
    with pytest.raises(CloudSTTError):
        await provider.load()
    health = await provider.health()
    assert not health.ready


@pytest.mark.asyncio
async def test_http_error_becomes_cloud_stt_error(monkeypatch):
    monkeypatch.setenv("GROQ_API_KEY", "test-key")
    provider = CloudSTTProvider()

    def fake_urlopen(request, timeout=None):
        raise urllib.error.HTTPError(request.full_url, 429, "Too Many Requests", {}, io.BytesIO(b"rate limited"))

    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)
    await provider.start_stream(16_000)
    await provider.accept_audio(_pcm([0.1]))
    with pytest.raises(CloudSTTError, match="429"):
        await provider.finish_stream()


def test_registry_builds_cloud_provider_from_environment():
    config = ProviderConfig.from_environment(
        {
            "MIRI_STT_PROVIDER": "cloud",
            "MIRI_PROVIDER_CLOUD_STT_MODEL": "whisper-large-v3",
            "MIRI_PROVIDER_CLOUD_STT_API_KEY_ENV": "MY_KEY",
        }
    )
    bundle = create_providers(config)
    assert isinstance(bundle.stt, CloudSTTProvider)
    assert bundle.stt.model == "whisper-large-v3"
    assert bundle.stt.api_key_env == "MY_KEY"
