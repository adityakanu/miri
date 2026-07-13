from pathlib import Path

import pytest

from miri_worker.providers import ReferenceSTTProvider, ReferenceTTSProvider
from miri_worker.real_providers import (
    MoonshineSTTProvider,
    OpenWakeWordProvider,
    PocketTTSProvider,
    SileroVADProvider,
)
from miri_worker.registry import (
    ProviderConfig,
    ProviderConfigurationError,
    create_providers,
)


def test_default_registry_stays_lightweight():
    bundle = create_providers(ProviderConfig())
    assert isinstance(bundle.stt, ReferenceSTTProvider)
    assert isinstance(bundle.tts, ReferenceTTSProvider)


def test_registry_selects_all_real_adapters_without_loading_them(tmp_path):
    bundle = create_providers(
        ProviderConfig(
            stt="moonshine",
            tts="pocket-tts",
            vad="silero",
            wake_word="openwakeword",
            options={
                "moonshine_model_path": str(tmp_path),
                "moonshine_model_arch": "4",
                "pocket_tts_config_path": str(tmp_path / "model.yaml"),
                "pocket_tts_voice": str(tmp_path / "voice.safetensors"),
                "openwakeword_model_paths": str(tmp_path / "miri.onnx"),
            },
        )
    )
    assert isinstance(bundle.stt, MoonshineSTTProvider)
    assert isinstance(bundle.tts, PocketTTSProvider)
    assert isinstance(bundle.vad, SileroVADProvider)
    assert isinstance(bundle.wake_word, OpenWakeWordProvider)


def test_environment_mapping_and_validation():
    config = ProviderConfig.from_environment(
        {
            "MIRI_STT_PROVIDER": "moonshine",
            "MIRI_PROVIDER_MOONSHINE_MODEL_PATH": "/models/moonshine",
            "MIRI_PROVIDER_MOONSHINE_MODEL_ARCH": "small",
        }
    )
    assert config.options["moonshine_model_path"] == "/models/moonshine"
    with pytest.raises(ProviderConfigurationError, match="must be an integer"):
        create_providers(config)


def test_unknown_provider_is_rejected():
    with pytest.raises(ProviderConfigurationError, match="unknown STT"):
        create_providers(ProviderConfig(stt="mystery"))
