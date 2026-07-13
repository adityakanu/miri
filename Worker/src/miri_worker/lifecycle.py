"""Warm-provider lifecycle policies for responsive, balanced, and eco profiles."""

from __future__ import annotations

import time
from dataclasses import dataclass
from enum import Enum
from typing import Awaitable, Callable


class LifecycleProfile(str, Enum):
    RESPONSIVE = "responsive"
    BALANCED = "balanced"
    ECO = "eco"


@dataclass(frozen=True, slots=True)
class LifecyclePolicy:
    keep_stt_warm: bool
    keep_tts_warm: bool
    idle_unload_seconds: float | None


POLICIES = {
    LifecycleProfile.RESPONSIVE: LifecyclePolicy(True, True, None),
    LifecycleProfile.BALANCED: LifecyclePolicy(True, False, 300.0),
    LifecycleProfile.ECO: LifecyclePolicy(False, False, 30.0),
}


class ProviderLifecycle:
    def __init__(self, profile: LifecycleProfile = LifecycleProfile.RESPONSIVE) -> None:
        self.profile = profile
        self.policy = POLICIES[profile]
        self.last_used = time.monotonic()

    def touch(self) -> None:
        self.last_used = time.monotonic()

    def should_unload(self, provider: str, now: float | None = None) -> bool:
        if provider == "stt" and self.policy.keep_stt_warm:
            return False
        if provider == "tts" and self.policy.keep_tts_warm:
            return False
        timeout = self.policy.idle_unload_seconds
        current = time.monotonic() if now is None else now
        return timeout is not None and current - self.last_used >= timeout

    async def unload_idle(
        self,
        unload_stt: Callable[[], Awaitable[None]],
        unload_tts: Callable[[], Awaitable[None]],
        now: float | None = None,
    ) -> tuple[str, ...]:
        unloaded: list[str] = []
        if self.should_unload("stt", now):
            await unload_stt()
            unloaded.append("stt")
        if self.should_unload("tts", now):
            await unload_tts()
            unloaded.append("tts")
        return tuple(unloaded)
