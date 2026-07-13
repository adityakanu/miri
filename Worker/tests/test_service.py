import asyncio
import hashlib
import io
import json

import pytest

from miri_worker.lifecycle import LifecycleProfile
from miri_worker.models import ModelEntry, ModelManager, ModelManifest
from miri_worker.protocol import encode, json_payload, make_frame, read_frame
from miri_worker.providers import ReferenceSTTProvider, ReferenceTTSProvider
from miri_worker.service import WorkerService, serve_async


class SequenceVAD:
    def __init__(self, values):
        self.values = iter(values)

    def is_speech(self, pcm):
        return next(self.values, False)


class DetectOnceWakeWord:
    def __init__(self):
        self.calls = 0

    def detected(self, pcm):
        self.calls += 1
        return self.calls == 1


def message_types(frames):
    return [frame.header["messageType"] for frame in frames]


@pytest.mark.asyncio
async def test_hello_and_health_report_capabilities_and_provider_state():
    service = WorkerService(profile=LifecycleProfile.RESPONSIVE)
    hello = await service.receive(make_frame("hello", "h1", {"peer": "swift"}))
    assert message_types(hello) == ["response"]
    assert "stt.streaming" in json_payload(hello[0])["capabilities"]
    health = await service.receive(make_frame("health", "h2"))
    payload = json_payload(health[0])
    assert payload["status"] == "ok"
    assert payload["stt"]["ready"] and payload["tts"]["ready"]
    await service.close()


@pytest.mark.asyncio
async def test_audio_stream_emits_partial_and_final_with_ids():
    service = WorkerService(stt=ReferenceSTTProvider(partial_every_bytes=8))
    start = await service.receive(make_frame("audio.start", "r1", {"sampleRate": 16_000}, session_id="a"))
    assert message_types(start) == ["response"]
    chunk = await service.receive(
        make_frame("audio.chunk", "r2", b"\0" * 8, session_id="a", kind="pcmFloat32")
    )
    assert message_types(chunk) == ["response", "transcript.partial"]
    assert chunk[1].request_id == "r2" and chunk[1].session_id == "a"
    stop = await service.receive(make_frame("audio.stop", "r3", session_id="a"))
    assert message_types(stop) == ["response", "transcript.final"]
    assert json_payload(stop[1])["text"] == "audio 2 samples"
    await service.close()


@pytest.mark.asyncio
async def test_vad_emits_endpoint_after_speech_and_configured_silence():
    service = WorkerService(vad=SequenceVAD([True, False, False]))
    await service.receive(
        make_frame(
            "audio.start",
            "r1",
            {"vadEndpointing": True, "minimumSilenceMilliseconds": 100},
            session_id="a",
        )
    )
    kinds = []
    for index in range(3):
        frames = await service.receive(
            make_frame(
                "audio.chunk",
                f"r{index + 2}",
                b"\0" * (800 * 4),
                session_id="a",
                kind="pcmFloat32",
            )
        )
        kinds.extend(message_types(frames))
    assert "audio.endpoint" in kinds
    await service.close()


@pytest.mark.asyncio
async def test_wake_word_stream_reports_detection_and_stops():
    service = WorkerService(wake_word=DetectOnceWakeWord())
    start = await service.receive(make_frame("wake.start", "w1", {"sampleRate": 16_000}, session_id="w"))
    assert message_types(start) == ["response"]
    chunk = await service.receive(
        make_frame("wake.chunk", "w2", b"\0" * 5120, session_id="w", kind="pcmFloat32")
    )
    assert message_types(chunk) == ["response", "wake.detected"]
    stopped = await service.receive(make_frame("wake.stop", "w3", session_id="w"))
    assert json_payload(stopped[0])["stopped"] is True
    await service.close()


@pytest.mark.asyncio
async def test_model_install_requires_consent_and_streams_verified_progress(tmp_path):
    data = b"pinned-model"
    manifest = ModelManifest(
        (
            ModelEntry(
                id="speech",
                url="https://models.invalid/speech.bin",
                sha256=hashlib.sha256(data).hexdigest(),
                size=len(data),
                filename="speech.bin",
            ),
        )
    )
    manager = ModelManager(tmp_path, manifest, fetcher=lambda url, offset: iter((data[offset:],)))
    service = WorkerService(model_manager=manager)
    denied = await service.receive(make_frame("model.install", "m1", {"consent": False}))
    assert message_types(denied) == ["error"]
    installed = await service.receive(make_frame("model.install", "m2", {"consent": True}))
    assert json_payload(installed[0])["installed"] == ["speech"]
    progress = await asyncio.wait_for(service.events.get(), 1)
    assert message_types([progress]) == ["model.progress"]
    status = await service.receive(make_frame("model.status", "m3"))
    assert json_payload(status[0])["models"][0]["installed"] is True
    await service.close()


@pytest.mark.asyncio
async def test_audio_validation_and_cancel():
    service = WorkerService()
    error = await service.receive(make_frame("audio.start", "r", {"sampleRate": 0}, session_id="a"))
    assert message_types(error) == ["error"]
    await service.receive(make_frame("audio.start", "r2", session_id="a"))
    wrong = await service.receive(make_frame("audio.chunk", "r3", b"", session_id="b", kind="pcmFloat32"))
    assert json_payload(wrong[0])["code"] == "invalid_request"
    cancelled = await service.receive(make_frame("cancel", "r4", session_id="a"))
    assert json_payload(cancelled[0])["cancelled"] is True
    await service.close()


@pytest.mark.asyncio
async def test_speech_streams_pcm_and_terminal_event():
    service = WorkerService(tts=ReferenceTTSProvider(chunk_samples=2))
    responses = await service.receive(
        make_frame("speech.start", "t1", {"text": "hey", "voice": "alba"}, session_id="s")
    )
    assert json_payload(responses[0])["sampleRate"] == 24_000
    events = [await asyncio.wait_for(service.events.get(), 1) for _ in range(4)]
    assert message_types(events) == ["speech.chunk", "speech.chunk", "speech.chunk", "speech.stop"]
    assert all(frame.session_id == "s" and frame.request_id == "t1" for frame in events)
    assert json_payload(events[-1]) == {"cancelled": False, "chunks": 3}
    await service.close()


@pytest.mark.asyncio
async def test_speech_cancel_stops_active_generation():
    service = WorkerService(tts=ReferenceTTSProvider(chunk_samples=2))
    await service.receive(make_frame("speech.start", "t1", {"text": "x" * 1_000}, session_id="s"))
    await service.events.get()  # prove streaming started
    response = await service.receive(make_frame("cancel", "c1", session_id="s"))
    assert json_payload(response[0])["cancelled"] is True
    terminal = None
    while terminal is None:
        event = await asyncio.wait_for(service.events.get(), 1)
        if event.header["messageType"] == "speech.stop":
            terminal = event
    assert json_payload(terminal)["cancelled"] is True
    assert "s" not in service.speech_tasks
    await service.close()


@pytest.mark.asyncio
async def test_unknown_and_malformed_requests_return_structured_errors():
    service = WorkerService()
    unknown = await service.receive(make_frame("unknown", "r"))
    assert json_payload(unknown[0])["code"] == "invalid_request"
    missing_session = await service.receive(make_frame("speech.start", "r2", {"text": "hi"}))
    assert "sessionID" in json_payload(missing_session[0])["detail"]
    invalid_json = make_frame("health", "r3", b"{")
    error = await service.receive(invalid_json)
    assert json_payload(error[0])["code"] == "invalid_request"
    await service.close()


@pytest.mark.asyncio
async def test_eco_loads_on_demand_and_reaps_after_idle():
    service = WorkerService(profile=LifecycleProfile.ECO)
    await service.start()
    assert not (await service.stt.health()).loaded
    await service.receive(make_frame("audio.start", "r1", session_id="a"))
    await service.receive(make_frame("audio.stop", "r2", session_id="a"))
    assert (await service.stt.health()).loaded
    service.lifecycle.last_used = 0
    assert await service.reap_idle(now=31) == ("stt", "tts")
    assert not (await service.stt.health()).loaded
    await service.close()


@pytest.mark.asyncio
async def test_framed_stdio_service_round_trip():
    source = io.BytesIO(encode(make_frame("health", "health-1")))
    sink = io.BytesIO()
    await serve_async(source, sink)
    sink.seek(0)
    response = read_frame(sink)
    assert response is not None
    assert response.request_id == "health-1"
    assert json_payload(response)["operation"] == "health"
