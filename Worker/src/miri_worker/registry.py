"""Configuration and registry for replaceable speech providers."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

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
from .real_providers import (
    MoonshineSTTProvider,
    OpenWakeWordProvider,
    PocketTTSProvider,
    SileroVADProvider,
)


class ProviderConfigurationError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class ProviderConfig:
    stt: str = "reference"
    tts: str = "reference"
    vad: str = "energy"
    wake_word: str = "disabled"
    options: Mapping[str, str] = field(default_factory=dict)

    @classmethod
    def from_environment(cls, environment: Mapping[str, str] | None = None) -> "ProviderConfig":
        values = os.environ if environment is None else environment
        prefix = "MIRI_PROVIDER_"
        return cls(
            stt=values.get("MIRI_STT_PROVIDER", "reference"),
            tts=values.get("MIRI_TTS_PROVIDER", "reference"),
            vad=values.get("MIRI_VAD_PROVIDER", "energy"),
            wake_word=values.get("MIRI_WAKE_WORD_PROVIDER", "disabled"),
            options={key[len(prefix) :].lower(): value for key, value in values.items() if key.startswith(prefix)},
        )


@dataclass(frozen=True, slots=True)
class ProviderBundle:
    stt: STTProvider
    tts: TTSProvider
    vad: VADProvider
    wake_word: WakeWordProvider


def _float(options: Mapping[str, str], key: str, default: float) -> float:
    try:
        return float(options.get(key, default))
    except ValueError as error:
        raise ProviderConfigurationError(f"{key} must be a number") from error


def _bool(options: Mapping[str, str], key: str, default: bool = False) -> bool:
    value = options.get(key)
    if value is None:
        return default
    if value.lower() in {"1", "true", "yes"}:
        return True
    if value.lower() in {"0", "false", "no"}:
        return False
    raise ProviderConfigurationError(f"{key} must be true or false")


def create_providers(config: ProviderConfig) -> ProviderBundle:
    options = config.options
    if config.stt == "reference":
        stt: STTProvider = ReferenceSTTProvider()
    elif config.stt == "moonshine":
        path = options.get("moonshine_model_path")
        arch = options.get("moonshine_model_arch")
        if not path or arch is None:
            raise ProviderConfigurationError(
                "moonshine requires MIRI_PROVIDER_MOONSHINE_MODEL_PATH and "
                "MIRI_PROVIDER_MOONSHINE_MODEL_ARCH"
            )
        try:
            model_arch = int(arch)
        except ValueError as error:
            raise ProviderConfigurationError("moonshine_model_arch must be an integer") from error
        stt = MoonshineSTTProvider(
            Path(path), model_arch, update_interval=_float(options, "moonshine_update_interval", 0.2)
        )
    else:
        raise ProviderConfigurationError(f"unknown STT provider: {config.stt}")

    if config.tts == "reference":
        tts: TTSProvider = ReferenceTTSProvider()
    elif config.tts == "pocket-tts":
        config_path = options.get("pocket_tts_config_path")
        tts = PocketTTSProvider(
            config_path=Path(config_path) if config_path else None,
            language=options.get("pocket_tts_language"),
            default_voice=options.get("pocket_tts_voice"),
            allow_downloads=_bool(options, "allow_model_downloads"),
        )
    else:
        raise ProviderConfigurationError(f"unknown TTS provider: {config.tts}")

    if config.vad == "energy":
        vad: VADProvider = EnergyVADProvider(_float(options, "energy_vad_threshold", 0.01))
    elif config.vad == "silero":
        vad = SileroVADProvider(_float(options, "silero_threshold", 0.5))
    else:
        raise ProviderConfigurationError(f"unknown VAD provider: {config.vad}")

    if config.wake_word == "disabled":
        wake_word: WakeWordProvider = DisabledWakeWordProvider()
    elif config.wake_word == "openwakeword":
        raw_paths = options.get("openwakeword_model_paths", "")
        paths = tuple(Path(value) for value in raw_paths.split(os.pathsep) if value)
        wake_word = OpenWakeWordProvider(
            paths, threshold=_float(options, "openwakeword_threshold", 0.5)
        )
    else:
        raise ProviderConfigurationError(f"unknown wake-word provider: {config.wake_word}")
    return ProviderBundle(stt, tts, vad, wake_word)
