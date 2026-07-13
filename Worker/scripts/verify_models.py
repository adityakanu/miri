"""Load configured real providers and run a short in-memory synthesis check."""
import asyncio

from miri_worker.registry import ProviderConfig, create_providers


async def main() -> None:
    providers = create_providers(ProviderConfig.from_environment())
    await providers.stt.load()
    print(await providers.stt.health())
    await providers.tts.load()
    await providers.tts.prepare_voice()
    print(await providers.tts.health())
    chunks = [chunk async for chunk in providers.tts.stream("Model test passed.")]
    print(f"tts_chunks={len(chunks)} bytes={sum(map(len, chunks))}")
    await providers.stt.start_stream(24_000)
    for chunk in chunks:
        await providers.stt.accept_audio(chunk)
    print(f"round_trip_transcript={await providers.stt.finish_stream()!r}")
    await providers.stt.unload()
    await providers.tts.unload()


if __name__ == "__main__":
    asyncio.run(main())
