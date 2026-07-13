import struct

import pytest

from miri_worker.providers import EnergyVADProvider, ReferenceSTTProvider, ReferenceTTSProvider


@pytest.mark.asyncio
async def test_reference_stt_lifecycle_partial_final_and_cancel():
    provider = ReferenceSTTProvider(partial_every_bytes=8)
    assert not (await provider.health()).ready
    await provider.load()
    await provider.start_stream(16_000)
    assert await provider.accept_audio(b"\0" * 4) is None
    assert await provider.accept_audio(b"\0" * 4) == "audio 2 samples"
    assert await provider.finish_stream() == "audio 2 samples"
    await provider.start_stream(16_000)
    await provider.cancel()
    assert not provider.active
    await provider.unload()
    assert not (await provider.health()).loaded


@pytest.mark.asyncio
async def test_reference_stt_rejects_unaligned_pcm():
    provider = ReferenceSTTProvider()
    await provider.load()
    await provider.start_stream(16_000)
    with pytest.raises(ValueError, match="aligned"):
        await provider.accept_audio(b"bad")


@pytest.mark.asyncio
async def test_reference_tts_streams_24khz_float_chunks_and_stops():
    provider = ReferenceTTSProvider(chunk_samples=3)
    await provider.load()
    await provider.prepare_voice("test")
    chunks = [chunk async for chunk in provider.stream("hi", "test")]
    assert len(chunks) == 2
    assert all(len(chunk) == 12 for chunk in chunks)
    assert struct.unpack("<f", chunks[0][:4])[0] == pytest.approx(0.12)
    await provider.stop()
    assert provider.cancelled


def test_energy_vad():
    vad = EnergyVADProvider(threshold=0.1)
    assert not vad.is_speech(struct.pack("<ff", 0.0, 0.09))
    assert vad.is_speech(struct.pack("<ff", 0.0, -0.2))
