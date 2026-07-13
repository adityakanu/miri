"""Async speech worker service over Miri's framed stdio transport."""

from __future__ import annotations

import asyncio
import os
import sys
from contextlib import suppress
from pathlib import Path
from typing import BinaryIO

from .lifecycle import LifecycleProfile, ProviderLifecycle
from .models import ModelError, ModelManager, ModelManifest
from .protocol import Frame, ProtocolError, json_payload, make_frame, read_frame, write_frame
from .providers import (
    DisabledWakeWordProvider,
    EnergyVADProvider,
    ReferenceSTTProvider,
    ReferenceTTSProvider,
    STTProvider,
    TTSProvider,
    VADProvider,
    WakeWordProvider,
)
from .registry import ProviderConfig, create_providers


class WorkerService:
    """Stateful protocol dispatcher with asynchronous speech event delivery."""

    def __init__(
        self,
        stt: STTProvider | None = None,
        tts: TTSProvider | None = None,
        vad: VADProvider | None = None,
        wake_word: WakeWordProvider | None = None,
        model_manager: ModelManager | None = None,
        *,
        profile: LifecycleProfile = LifecycleProfile.RESPONSIVE,
    ) -> None:
        configured = create_providers(ProviderConfig.from_environment()) if stt is None and tts is None else None
        self.stt = stt or (configured.stt if configured else ReferenceSTTProvider())
        self.tts = tts or (configured.tts if configured else ReferenceTTSProvider())
        self.vad = vad or (configured.vad if configured else EnergyVADProvider())
        self.wake_word = wake_word or (
            configured.wake_word if configured else DisabledWakeWordProvider()
        )
        self.lifecycle = ProviderLifecycle(profile)
        self.model_manager = model_manager or self._model_manager_from_environment()
        self.events: asyncio.Queue[Frame] = asyncio.Queue()
        self.audio_session: str | None = None
        self.wake_session: str | None = None
        self.vad_endpointing = False
        self.vad_speech_seen = False
        self.vad_silence_ms = 0.0
        self.vad_minimum_silence_ms = 500.0
        self.speech_tasks: dict[str, asyncio.Task[None]] = {}
        self._started = False

    @staticmethod
    def _model_manager_from_environment() -> ModelManager | None:
        manifest = os.environ.get("MIRI_MODEL_MANIFEST")
        if not manifest:
            return None
        root = os.environ.get(
            "MIRI_MODELS_DIRECTORY",
            str(Path.home() / "Library/Application Support/Miri/Models"),
        )
        return ModelManager(Path(root), ModelManifest.load(Path(manifest)))

    async def start(self) -> None:
        if self._started:
            return
        if self.lifecycle.policy.keep_stt_warm:
            await self.stt.load()
        if self.lifecycle.policy.keep_tts_warm:
            await self.tts.load()
        self._started = True

    async def close(self) -> None:
        if self.audio_session is not None:
            await self.stt.cancel()
            self.audio_session = None
        self.wake_session = None
        tasks = tuple(self.speech_tasks.values())
        await self.tts.stop()
        for task in tasks:
            task.cancel()
        for task in tasks:
            with suppress(asyncio.CancelledError):
                await task
        self.speech_tasks.clear()
        await self.stt.unload()
        await self.tts.unload()
        self._started = False

    async def _ensure_stt(self) -> None:
        if not (await self.stt.health()).loaded:
            await self.stt.load()

    async def _ensure_tts(self) -> None:
        if not (await self.tts.health()).loaded:
            await self.tts.load()

    async def reap_idle(self, now: float | None = None) -> tuple[str, ...]:
        """Apply the selected profile's idle-unload policy."""

        return await self.lifecycle.unload_idle(self.stt.unload, self.tts.unload, now)

    @staticmethod
    def _response(frame: Frame, **payload: object) -> Frame:
        return make_frame(
            "response",
            frame.request_id,
            {"operation": frame.header["messageType"], "status": "ok", **payload},
            session_id=frame.session_id,
        )

    @staticmethod
    def _error(frame: Frame, code: str, detail: str) -> Frame:
        return make_frame(
            "error",
            frame.request_id,
            {"code": code, "detail": detail},
            session_id=frame.session_id,
        )

    @staticmethod
    def _require_session(frame: Frame) -> str:
        if frame.session_id is None:
            raise ProtocolError(f"{frame.header['messageType']} requires sessionID")
        return frame.session_id

    async def receive(self, frame: Frame) -> list[Frame]:
        """Dispatch one frame and return immediate responses.

        Streaming speech frames are delivered through ``events`` so another input
        (notably cancel) can be processed while synthesis is in progress.
        """
        if not self._started:
            await self.start()
        try:
            kind = str(frame.header["messageType"])
            handler = getattr(self, f"_on_{kind.replace('.', '_')}", None)
            if handler is None:
                raise ProtocolError(f"unsupported message type: {kind}")
            responses = await handler(frame)
            self.lifecycle.touch()
            return responses
        except (ProtocolError, ValueError) as error:
            return [self._error(frame, "invalid_request", str(error))]
        except RuntimeError as error:
            return [self._error(frame, "provider_error", str(error))]

    async def _on_hello(self, frame: Frame) -> list[Frame]:
        payload = json_payload(frame)
        return [
            self._response(
                frame,
                protocolVersion=1,
                workerVersion="0.1.0",
                peer=payload.get("peer"),
                capabilities=[
                    "stt.streaming",
                    "tts.streaming",
                    "vad.endpointing",
                    "wakeword.streaming",
                    "cancellation",
                    "health",
                    "models.managed",
                ],
            )
        ]

    async def _on_model_status(self, frame: Frame) -> list[Frame]:
        json_payload(frame)
        if self.model_manager is None:
            return [self._response(frame, configured=False, models=[])]
        models = []
        for model_id in self.model_manager.manifest.entries:
            try:
                path = self.model_manager.resolve(model_id)
                models.append({"id": model_id, "installed": True, "path": str(path)})
            except ModelError as error:
                models.append({"id": model_id, "installed": False, "detail": str(error)})
        return [self._response(frame, configured=True, models=models)]

    async def _on_model_install(self, frame: Frame) -> list[Frame]:
        payload = json_payload(frame)
        if self.model_manager is None:
            raise ProtocolError("managed model manifest is not configured")
        if payload.get("consent") is not True:
            raise ProtocolError("model installation requires explicit consent")
        requested = payload.get("models")
        if requested is None:
            model_ids = list(self.model_manager.manifest.entries)
        elif isinstance(requested, list) and all(isinstance(item, str) for item in requested):
            model_ids = requested
        else:
            raise ProtocolError("models must be an array of model IDs")
        loop = asyncio.get_running_loop()
        installed: list[str] = []
        for model_id in model_ids:
            def progress(current: int, total: int, *, selected: str = model_id) -> None:
                loop.call_soon_threadsafe(
                    self.events.put_nowait,
                    make_frame(
                        "model.progress",
                        frame.request_id,
                        {"model": selected, "downloadedBytes": current, "totalBytes": total},
                    ),
                )

            try:
                await asyncio.to_thread(self.model_manager.install, model_id, progress)
            except ModelError as error:
                raise ProtocolError(str(error)) from error
            installed.append(model_id)
        return [self._response(frame, installed=installed)]

    async def _on_model_remove(self, frame: Frame) -> list[Frame]:
        payload = json_payload(frame)
        if self.model_manager is None:
            raise ProtocolError("managed model manifest is not configured")
        requested = payload.get("models")
        model_ids = list(self.model_manager.manifest.entries) if requested is None else requested
        if not isinstance(model_ids, list) or not all(isinstance(item, str) for item in model_ids):
            raise ProtocolError("models must be an array of model IDs")
        for model_id in model_ids:
            try:
                self.model_manager.remove(model_id)
            except ModelError as error:
                raise ProtocolError(str(error)) from error
        return [self._response(frame, removed=model_ids)]

    async def _on_health(self, frame: Frame) -> list[Frame]:
        json_payload(frame)
        stt = await self.stt.health()
        tts = await self.tts.health()
        return [
            self._response(
                frame,
                profile=self.lifecycle.profile.value,
                stt={"loaded": stt.loaded, "ready": stt.ready, "detail": stt.detail},
                tts={"loaded": tts.loaded, "ready": tts.ready, "detail": tts.detail},
                activeAudioSession=self.audio_session,
                activeWakeSession=self.wake_session,
                activeSpeechSessions=sorted(self.speech_tasks),
            )
        ]

    async def _on_audio_start(self, frame: Frame) -> list[Frame]:
        session = self._require_session(frame)
        payload = json_payload(frame)
        if self.audio_session is not None:
            raise ProtocolError("an audio session is already active")
        sample_rate = payload.get("sampleRate", 16_000)
        if not isinstance(sample_rate, int) or isinstance(sample_rate, bool) or sample_rate <= 0:
            raise ProtocolError("sampleRate must be a positive integer")
        await self._ensure_stt()
        await self.stt.start_stream(sample_rate)
        self.audio_session = session
        self.vad_endpointing = bool(payload.get("vadEndpointing", False))
        self.vad_speech_seen = False
        self.vad_silence_ms = 0.0
        minimum_silence = payload.get("minimumSilenceMilliseconds", 500)
        if not isinstance(minimum_silence, (int, float)) or isinstance(minimum_silence, bool) or minimum_silence <= 0:
            raise ProtocolError("minimumSilenceMilliseconds must be positive")
        self.vad_minimum_silence_ms = float(minimum_silence)
        return [self._response(frame, sampleRate=sample_rate, channels=1, format="float32le")]

    async def _on_audio_chunk(self, frame: Frame) -> list[Frame]:
        session = self._require_session(frame)
        if frame.header["kind"] != "pcmFloat32":
            raise ProtocolError("audio.chunk requires pcmFloat32 payload")
        if session != self.audio_session:
            raise ProtocolError("audio session is not active")
        partial = await self.stt.accept_audio(frame.payload)
        responses = [self._response(frame, acceptedBytes=len(frame.payload))]
        if partial is not None:
            responses.append(
                make_frame("transcript.partial", frame.request_id, {"text": partial}, session_id=session)
            )
        if self.vad_endpointing:
            speech = self.vad.is_speech(frame.payload)
            duration_ms = len(frame.payload) / 4 / 16_000 * 1_000
            if speech:
                self.vad_speech_seen = True
                self.vad_silence_ms = 0.0
            elif self.vad_speech_seen:
                self.vad_silence_ms += duration_ms
                if self.vad_silence_ms >= self.vad_minimum_silence_ms:
                    responses.append(
                        make_frame("audio.endpoint", frame.request_id, {"reason": "silence"}, session_id=session)
                    )
                    self.vad_endpointing = False
        return responses

    async def _on_audio_stop(self, frame: Frame) -> list[Frame]:
        session = self._require_session(frame)
        json_payload(frame)
        if session != self.audio_session:
            raise ProtocolError("audio session is not active")
        transcript = await self.stt.finish_stream()
        self.audio_session = None
        self.vad_endpointing = False
        return [
            self._response(frame),
            make_frame(
                "transcript.final",
                frame.request_id,
                {"text": transcript, "language": "en", "isFinal": True},
                session_id=session,
            ),
        ]

    async def _on_wake_start(self, frame: Frame) -> list[Frame]:
        session = self._require_session(frame)
        payload = json_payload(frame)
        if self.wake_session is not None:
            raise ProtocolError("a wake-word session is already active")
        sample_rate = payload.get("sampleRate", 16_000)
        if sample_rate != 16_000:
            raise ProtocolError("wake-word audio must be 16000 Hz")
        self.wake_session = session
        return [self._response(frame, sampleRate=sample_rate, channels=1, format="float32le")]

    async def _on_wake_chunk(self, frame: Frame) -> list[Frame]:
        session = self._require_session(frame)
        if frame.header["kind"] != "pcmFloat32":
            raise ProtocolError("wake.chunk requires pcmFloat32 payload")
        if session != self.wake_session:
            raise ProtocolError("wake-word session is not active")
        responses = [self._response(frame, acceptedBytes=len(frame.payload))]
        if self.wake_word.detected(frame.payload):
            responses.append(
                make_frame("wake.detected", frame.request_id, {"detected": True}, session_id=session)
            )
        return responses

    async def _on_wake_stop(self, frame: Frame) -> list[Frame]:
        session = self._require_session(frame)
        json_payload(frame)
        stopped = session == self.wake_session
        if stopped:
            self.wake_session = None
        return [self._response(frame, stopped=stopped)]

    async def _on_speech_start(self, frame: Frame) -> list[Frame]:
        session = self._require_session(frame)
        payload = json_payload(frame)
        text = payload.get("text")
        voice = payload.get("voice")
        if not isinstance(text, str) or not text.strip():
            raise ProtocolError("speech.start requires non-empty text")
        if voice is not None and not isinstance(voice, str):
            raise ProtocolError("voice must be a string")
        if self.speech_tasks:
            raise ProtocolError("a speech session is already active")
        await self._ensure_tts()
        await self.tts.prepare_voice(voice)
        task = asyncio.create_task(self._synthesize(frame.request_id, session, text, voice))
        self.speech_tasks[session] = task
        return [self._response(frame, sampleRate=24_000, channels=1, format="float32le")]

    async def _synthesize(self, request_id: str, session: str, text: str, voice: str | None) -> None:
        sequence = 0
        cancelled = False
        try:
            async for pcm in self.tts.stream(text, voice):
                await self.events.put(
                    make_frame(
                        "speech.chunk",
                        request_id,
                        pcm,
                        session_id=session,
                        kind="pcmFloat32",
                    )
                )
                sequence += 1
        except asyncio.CancelledError:
            cancelled = True
            raise
        except Exception as error:  # provider failures must cross the protocol boundary
            await self.events.put(self._error(make_frame("speech.start", request_id, session_id=session), "provider_error", str(error)))
        finally:
            current = asyncio.current_task()
            if self.speech_tasks.get(session) is current:
                self.speech_tasks.pop(session, None)
            await self.events.put(
                make_frame(
                    "speech.stop",
                    request_id,
                    {"cancelled": cancelled or bool(getattr(self.tts, "cancelled", False)), "chunks": sequence},
                    session_id=session,
                )
            )

    async def _stop_speech(self, session: str) -> bool:
        task = self.speech_tasks.get(session)
        if task is None:
            return False
        await self.tts.stop()
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task
        return True

    async def _on_speech_stop(self, frame: Frame) -> list[Frame]:
        session = self._require_session(frame)
        json_payload(frame)
        stopped = await self._stop_speech(session)
        return [self._response(frame, stopped=stopped)]

    async def _on_cancel(self, frame: Frame) -> list[Frame]:
        session = self._require_session(frame)
        json_payload(frame)
        cancelled = False
        if session == self.audio_session:
            await self.stt.cancel()
            self.audio_session = None
            cancelled = True
        if session == self.wake_session:
            self.wake_session = None
            cancelled = True
        cancelled = await self._stop_speech(session) or cancelled
        return [self._response(frame, cancelled=cancelled)]


async def serve_async(source: BinaryIO, sink: BinaryIO, service: WorkerService | None = None) -> None:
    worker = service or WorkerService()
    await worker.start()
    output_lock = asyncio.Lock()

    async def output(frame: Frame) -> None:
        async with output_lock:
            await asyncio.to_thread(write_frame, sink, frame)

    async def write_events() -> None:
        while True:
            frame = await worker.events.get()
            await output(frame)

    writer = asyncio.create_task(write_events())
    try:
        while (request := await asyncio.to_thread(read_frame, source)) is not None:
            for response in await worker.receive(request):
                await output(response)
    finally:
        await worker.close()
        # Give close-generated terminal events a chance to flush.
        while not worker.events.empty():
            await output(worker.events.get_nowait())
        writer.cancel()
        with suppress(asyncio.CancelledError):
            await writer


def serve(source: BinaryIO, sink: BinaryIO) -> None:
    profile = LifecycleProfile(os.environ.get("MIRI_PROFILE", LifecycleProfile.RESPONSIVE.value))
    asyncio.run(serve_async(source, sink, WorkerService(profile=profile)))


def main() -> None:
    serve(sys.stdin.buffer, sys.stdout.buffer)


if __name__ == "__main__":
    main()
