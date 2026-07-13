"""Lazy adapters for Miri's optional production inference runtimes.

Nothing in this module imports an inference package at module import time.  This
keeps the reference worker and its contract tests usable without PyTorch,
ONNXRuntime, model weights, or network access.
"""

from __future__ import annotations

import asyncio
import importlib
import struct
import sys
from array import array
from pathlib import Path
from typing import Any, AsyncIterator

from .providers import ProviderHealth


class ProviderUnavailableError(RuntimeError):
    """An optional runtime or required local asset is unavailable."""


def _optional_import(module: str, extra: str) -> Any:
    try:
        return importlib.import_module(module)
    except (ImportError, OSError) as error:
        raise ProviderUnavailableError(
            f"optional provider runtime '{module}' is unavailable; "
            f"install the '{extra}' extra"
        ) from error


def _float32_values(pcm: bytes) -> array[float]:
    if len(pcm) % 4:
        raise ValueError("PCM float32 payload must be sample-aligned")
    samples = array("f")
    samples.frombytes(pcm)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


class _MoonshineListener:
    def __init__(self, owner: "MoonshineSTTProvider") -> None:
        self.owner = owner

    def on_line_started(self, event: Any) -> None:
        self.owner._partial = str(event.line.text).strip()

    def on_line_updated(self, event: Any) -> None:
        self.owner._partial = str(event.line.text).strip()

    def on_line_text_changed(self, event: Any) -> None:
        self.owner._partial = str(event.line.text).strip()

    def on_line_completed(self, event: Any) -> None:
        text = str(event.line.text).strip()
        if text:
            self.owner._completed.append(text)
        self.owner._partial = ""

    def __call__(self, event: Any) -> None:
        """Support moonshine-voice 0.0.68's callable listener dispatcher."""
        handlers = {
            "LineStarted": self.on_line_started,
            "LineUpdated": self.on_line_updated,
            "LineTextChanged": self.on_line_text_changed,
            "LineCompleted": self.on_line_completed,
        }
        handler = handlers.get(type(event).__name__)
        if handler is not None:
            handler(event)


class MoonshineSTTProvider:
    """Moonshine Small Streaming adapter using the official ``Transcriber`` API."""

    def __init__(self, model_path: Path, model_arch: int, *, update_interval: float = 0.2) -> None:
        self.model_path = Path(model_path).expanduser()
        self.model_arch = model_arch
        self.update_interval = update_interval
        self._transcriber: Any | None = None
        self._listener: Any | None = None
        self._active = False
        self._sample_rate = 0
        self._partial = ""
        self._last_partial = ""
        self._completed: list[str] = []
        self._load_error = ""

    async def load(self) -> None:
        if self._transcriber is not None:
            return
        if not self.model_path.is_dir():
            self._load_error = f"Moonshine model directory is missing: {self.model_path}"
            raise ProviderUnavailableError(self._load_error)
        try:
            runtime = _optional_import("moonshine_voice", "moonshine")
            arch_type = getattr(runtime, "ModelArch", None)
            model_arch = arch_type(self.model_arch) if arch_type is not None else self.model_arch
            self._transcriber = runtime.Transcriber(
                model_path=str(self.model_path),
                model_arch=model_arch,
                update_interval=self.update_interval,
            )
            self._listener = _MoonshineListener(self)
            self._transcriber.add_listener(self._listener)
            self._load_error = ""
        except Exception as error:
            self._transcriber = None
            if isinstance(error, ProviderUnavailableError):
                self._load_error = str(error)
                raise
            self._load_error = f"Moonshine failed to load: {error}"
            raise RuntimeError(self._load_error) from error

    async def start_stream(self, sample_rate: int) -> None:
        if self._transcriber is None:
            raise RuntimeError("Moonshine provider is not loaded")
        if sample_rate <= 0:
            raise ValueError("sample rate must be positive")
        self._partial = ""
        self._last_partial = ""
        self._completed.clear()
        self._sample_rate = sample_rate
        self._transcriber.start()
        self._active = True

    async def accept_audio(self, pcm: bytes) -> str | None:
        if not self._active or self._transcriber is None:
            raise RuntimeError("Moonshine stream is not active")
        self._transcriber.add_audio(_float32_values(pcm), self._sample_rate)
        if self._partial and self._partial != self._last_partial:
            self._last_partial = self._partial
            return self._partial
        return None

    async def finish_stream(self) -> str:
        if not self._active or self._transcriber is None:
            raise RuntimeError("Moonshine stream is not active")
        self._transcriber.stop()
        self._active = False
        parts = [*self._completed]
        if self._partial and (not parts or parts[-1] != self._partial):
            parts.append(self._partial)
        return " ".join(parts).strip()

    async def cancel(self) -> None:
        if self._active and self._transcriber is not None:
            self._transcriber.stop()
        self._active = False
        self._partial = ""
        self._completed.clear()

    async def unload(self) -> None:
        await self.cancel()
        if self._transcriber is not None:
            remove = getattr(self._transcriber, "remove_all_listeners", None)
            if remove is not None:
                remove()
        self._listener = None
        self._transcriber = None

    async def health(self) -> ProviderHealth:
        loaded = self._transcriber is not None
        if loaded:
            detail = f"moonshine-arch-{self.model_arch}:{self.model_path}"
        elif self._load_error:
            detail = self._load_error
        elif not self.model_path.is_dir():
            detail = f"Moonshine model directory is missing: {self.model_path}"
        else:
            detail = "Moonshine is configured but not loaded"
        return ProviderHealth(loaded, loaded, detail)


class PocketTTSProvider:
    """Pocket TTS adapter producing 24 kHz mono little-endian float32 chunks."""

    sample_rate = 24_000

    def __init__(
        self,
        *,
        config_path: Path | None = None,
        language: str | None = None,
        default_voice: str | None = None,
        allow_downloads: bool = False,
    ) -> None:
        if config_path is not None and language is not None:
            raise ValueError("Pocket TTS config_path and language are mutually exclusive")
        self.config_path = Path(config_path).expanduser() if config_path else None
        self.language = language
        self.default_voice = default_voice
        self.allow_downloads = allow_downloads
        self._model: Any | None = None
        self._voices: dict[str, Any] = {}
        self._active_voice: str | None = None
        self.cancelled = False
        self._load_error = ""

    async def load(self) -> None:
        if self._model is not None:
            return
        if self.config_path is not None and not self.config_path.is_file():
            self._load_error = f"Pocket TTS config is missing: {self.config_path}"
            raise ProviderUnavailableError(self._load_error)
        if self.config_path is None and not self.allow_downloads:
            self._load_error = (
                "Pocket TTS needs a local config_path; built-in language models may only be "
                "used after model-download consent"
            )
            raise ProviderUnavailableError(self._load_error)
        try:
            runtime = _optional_import("pocket_tts", "pocket-tts")
            kwargs: dict[str, Any] = {}
            if self.config_path is not None:
                kwargs["config"] = str(self.config_path)
            elif self.language is not None:
                kwargs["language"] = self.language
            self._model = runtime.TTSModel.load_model(**kwargs)
            self.sample_rate = int(self._model.sample_rate)
            if self.sample_rate != 24_000:
                raise RuntimeError(f"Pocket TTS returned unsupported sample rate {self.sample_rate}")
            self._load_error = ""
        except Exception as error:
            self._model = None
            if isinstance(error, ProviderUnavailableError):
                self._load_error = str(error)
                raise
            self._load_error = f"Pocket TTS failed to load: {error}"
            raise RuntimeError(self._load_error) from error

    def _voice_source(self, voice: str | None) -> str:
        selected = voice or self.default_voice
        if not selected:
            raise ProviderUnavailableError("Pocket TTS requires a configured voice prompt")
        path = Path(selected).expanduser()
        is_remote = selected.startswith(("hf://", "http://", "https://"))
        is_named = not is_remote and path.parent == Path(".") and not path.suffix
        if (is_remote or is_named) and not self.allow_downloads:
            raise ProviderUnavailableError(
                "Pocket TTS remote or catalog voices require model-download consent"
            )
        if not is_remote and not is_named and not path.is_file():
            raise ProviderUnavailableError(f"Pocket TTS voice prompt is missing: {path}")
        return selected if is_remote or is_named else str(path)

    async def prepare_voice(self, voice: str | None = None) -> None:
        if self._model is None:
            raise RuntimeError("Pocket TTS provider is not loaded")
        source = self._voice_source(voice)
        if source not in self._voices:
            self._voices[source] = self._model.get_state_for_audio_prompt(source)
        self._active_voice = source

    async def stream(self, text: str, voice: str | None = None) -> AsyncIterator[bytes]:
        if self._model is None:
            raise RuntimeError("Pocket TTS provider is not loaded")
        source = self._voice_source(voice) if voice is not None else self._active_voice
        if source is None or source not in self._voices:
            await self.prepare_voice(voice)
            source = self._active_voice
        self.cancelled = False
        assert source is not None
        for chunk in self._model.generate_audio_stream(self._voices[source], text):
            if self.cancelled:
                break
            tensor = chunk.detach().to(device="cpu", dtype=_optional_import("torch", "pocket-tts").float32)
            yield tensor.contiguous().numpy().astype("<f4", copy=False).tobytes()
            await asyncio.sleep(0)

    async def stop(self) -> None:
        self.cancelled = True

    async def unload(self) -> None:
        await self.stop()
        self._voices.clear()
        self._active_voice = None
        self._model = None

    async def health(self) -> ProviderHealth:
        loaded = self._model is not None
        if loaded:
            detail = f"pocket-tts:{self.sample_rate}Hz"
        elif self._load_error:
            detail = self._load_error
        elif self.config_path is not None and not self.config_path.is_file():
            detail = f"Pocket TTS config is missing: {self.config_path}"
        else:
            detail = "Pocket TTS is configured but not loaded"
        return ProviderHealth(loaded, loaded, detail)


class SileroVADProvider:
    """Streaming Silero VAD adapter for 16 kHz float32 PCM frames."""

    def __init__(self, threshold: float = 0.5, sample_rate: int = 16_000) -> None:
        if not 0 <= threshold <= 1:
            raise ValueError("Silero threshold must be between zero and one")
        self.threshold = threshold
        self.sample_rate = sample_rate
        self._model: Any | None = None
        self._buffer = bytearray()

    def _load(self) -> None:
        runtime = _optional_import("silero_vad", "silero-vad")
        self._model = runtime.load_silero_vad(onnx=True)

    def is_speech(self, pcm: bytes) -> bool:
        _float32_values(pcm)  # validate before buffering
        self._buffer.extend(pcm)
        frame_samples = 512 if self.sample_rate == 16_000 else 256
        frame_bytes = frame_samples * 4
        if len(self._buffer) < frame_bytes:
            return False
        if self._model is None:
            self._load()
        torch = _optional_import("torch", "silero-vad")
        speech = False
        while len(self._buffer) >= frame_bytes:
            frame = bytes(self._buffer[:frame_bytes])
            del self._buffer[:frame_bytes]
            tensor = torch.tensor(_float32_values(frame), dtype=torch.float32)
            score = self._model(tensor, self.sample_rate)
            value = float(score.item() if hasattr(score, "item") else score)
            speech = speech or value >= self.threshold
        return speech


class OpenWakeWordProvider:
    """Experimental openWakeWord adapter; it never downloads models implicitly."""

    def __init__(self, model_paths: tuple[Path, ...], *, threshold: float = 0.5) -> None:
        if not 0 <= threshold <= 1:
            raise ValueError("wake-word threshold must be between zero and one")
        self.model_paths = tuple(Path(path).expanduser() for path in model_paths)
        self.threshold = threshold
        self._model: Any | None = None
        self._buffer = bytearray()

    def _load(self) -> None:
        if not self.model_paths:
            raise ProviderUnavailableError("openWakeWord requires at least one local model path")
        missing = [str(path) for path in self.model_paths if not path.is_file()]
        if missing:
            raise ProviderUnavailableError(f"openWakeWord model is missing: {missing[0]}")
        runtime = _optional_import("openwakeword.model", "openwakeword")
        self._model = runtime.Model(wakeword_models=[str(path) for path in self.model_paths])

    def detected(self, pcm: bytes) -> bool:
        _float32_values(pcm)  # validate before buffering
        self._buffer.extend(pcm)
        frame_bytes = 1_280 * 4  # openWakeWord's recommended 80 ms at 16 kHz
        if len(self._buffer) < frame_bytes:
            return False
        if self._model is None:
            self._load()
        numpy = _optional_import("numpy", "openwakeword")
        found = False
        while len(self._buffer) >= frame_bytes:
            frame = bytes(self._buffer[:frame_bytes])
            del self._buffer[:frame_bytes]
            audio = numpy.asarray(_float32_values(frame), dtype=numpy.float32)
            audio = numpy.clip(audio, -1.0, 1.0)
            prediction = self._model.predict((audio * 32767.0).astype(numpy.int16))
            found = found or any(float(score) >= self.threshold for score in prediction.values())
        return found
