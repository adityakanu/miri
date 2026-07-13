import struct
from types import SimpleNamespace

import pytest

import miri_worker.real_providers as real
from miri_worker.real_providers import (
    MoonshineSTTProvider,
    OpenWakeWordProvider,
    PocketTTSProvider,
    ProviderUnavailableError,
    SileroVADProvider,
)


class FakeMoonshineTranscriber:
    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.listener = None
        self.started = False

    def add_listener(self, listener):
        self.listener = listener

    def add_audio(self, samples, sample_rate):
        assert list(samples) == pytest.approx([0.25, -0.5])
        assert sample_rate == 16_000
        self.listener.on_line_text_changed(SimpleNamespace(line=SimpleNamespace(text="hello")))

    def start(self):
        self.started = True

    def stop(self):
        if self.listener is not None:
            self.listener.on_line_completed(SimpleNamespace(line=SimpleNamespace(text="hello world")))
        self.started = False

    def remove_all_listeners(self):
        self.listener = None


@pytest.mark.asyncio
async def test_moonshine_adapter_streams_with_official_api(monkeypatch, tmp_path):
    monkeypatch.setattr(
        real.importlib,
        "import_module",
        lambda name: SimpleNamespace(Transcriber=FakeMoonshineTranscriber),
    )
    provider = MoonshineSTTProvider(tmp_path, 4)
    await provider.load()
    assert provider._transcriber.kwargs["model_path"] == str(tmp_path)
    await provider.start_stream(16_000)
    assert await provider.accept_audio(struct.pack("<ff", 0.25, -0.5)) == "hello"
    assert await provider.accept_audio(struct.pack("<ff", 0.25, -0.5)) is None
    assert await provider.finish_stream() == "hello world"
    assert (await provider.health()).ready
    await provider.unload()


@pytest.mark.asyncio
async def test_moonshine_missing_model_has_actionable_health(tmp_path):
    provider = MoonshineSTTProvider(tmp_path / "missing", 4)
    with pytest.raises(ProviderUnavailableError, match="model directory is missing"):
        await provider.load()
    health = await provider.health()
    assert not health.ready and "missing" in health.detail


class FakeArray:
    def astype(self, dtype, copy=False):
        assert dtype == "<f4" and copy is False
        return self

    def tobytes(self):
        return struct.pack("<ff", 0.1, -0.1)


class FakeTensor:
    def detach(self):
        return self

    def to(self, **kwargs):
        assert kwargs["device"] == "cpu"
        return self

    def contiguous(self):
        return self

    def numpy(self):
        return FakeArray()


class FakePocketModel:
    sample_rate = 24_000

    def get_state_for_audio_prompt(self, source):
        return {"voice": source}

    def generate_audio_stream(self, state, text):
        assert text == "hi" and state["voice"].endswith("voice.safetensors")
        yield FakeTensor()
        yield FakeTensor()


@pytest.mark.asyncio
async def test_pocket_tts_uses_local_assets_and_streaming_api(monkeypatch, tmp_path):
    config = tmp_path / "model.yaml"
    voice = tmp_path / "voice.safetensors"
    config.write_text("model: local")
    voice.write_bytes(b"voice")

    def fake_import(name):
        if name == "pocket_tts":
            return SimpleNamespace(
                TTSModel=SimpleNamespace(load_model=lambda **kwargs: FakePocketModel())
            )
        if name == "torch":
            return SimpleNamespace(float32="float32")
        raise ImportError(name)

    monkeypatch.setattr(real.importlib, "import_module", fake_import)
    provider = PocketTTSProvider(config_path=config, default_voice=str(voice))
    await provider.load()
    await provider.prepare_voice()
    chunks = [chunk async for chunk in provider.stream("hi")]
    assert chunks == [struct.pack("<ff", 0.1, -0.1)] * 2
    assert (await provider.health()).ready


@pytest.mark.asyncio
async def test_pocket_tts_refuses_implicit_download_without_consent():
    provider = PocketTTSProvider(language="english", default_voice="alba")
    with pytest.raises(ProviderUnavailableError, match="download consent"):
        await provider.load()
    assert "download consent" in (await provider.health()).detail


def test_silero_lazy_load_and_threshold(monkeypatch):
    class Score:
        def item(self):
            return 0.7

    class Model:
        def __call__(self, tensor, sample_rate):
            assert tensor == pytest.approx([0.1] * 512) and sample_rate == 16_000
            return Score()

    def fake_import(name):
        if name == "silero_vad":
            return SimpleNamespace(load_silero_vad=lambda onnx: Model())
        if name == "torch":
            return SimpleNamespace(float32="float32", tensor=lambda values, dtype: list(values))
        raise ImportError(name)

    monkeypatch.setattr(real.importlib, "import_module", fake_import)
    provider = SileroVADProvider(threshold=0.6)
    assert provider.is_speech(struct.pack("<f", 0.1) * 512)


def test_openwakeword_requires_local_models_before_import(tmp_path):
    provider = OpenWakeWordProvider((tmp_path / "missing.onnx",))
    with pytest.raises(ProviderUnavailableError, match="model is missing"):
        provider.detected(struct.pack("<f", 0.1) * 1280)


def test_optional_import_error_names_extra(monkeypatch):
    def unavailable(name):
        raise ImportError(name)

    monkeypatch.setattr(real.importlib, "import_module", unavailable)
    provider = SileroVADProvider()
    with pytest.raises(ProviderUnavailableError, match="silero-vad.*extra"):
        provider.is_speech(struct.pack("<f", 0.0) * 512)
