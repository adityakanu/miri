import pytest

from miri_worker.lifecycle import LifecycleProfile, POLICIES, ProviderLifecycle


def test_profile_defaults():
    assert POLICIES[LifecycleProfile.RESPONSIVE].keep_stt_warm
    assert POLICIES[LifecycleProfile.RESPONSIVE].keep_tts_warm
    assert POLICIES[LifecycleProfile.BALANCED].keep_stt_warm
    assert not POLICIES[LifecycleProfile.BALANCED].keep_tts_warm
    assert not POLICIES[LifecycleProfile.ECO].keep_stt_warm


@pytest.mark.asyncio
async def test_eco_unloads_idle_providers():
    lifecycle = ProviderLifecycle(LifecycleProfile.ECO)
    lifecycle.last_used = 10
    unloaded = []

    async def stt():
        unloaded.append("stt-call")

    async def tts():
        unloaded.append("tts-call")

    result = await lifecycle.unload_idle(stt, tts, now=41)
    assert result == ("stt", "tts")
    assert unloaded == ["stt-call", "tts-call"]


def test_responsive_never_idle_unloads():
    lifecycle = ProviderLifecycle(LifecycleProfile.RESPONSIVE)
    lifecycle.last_used = 0
    assert not lifecycle.should_unload("stt", now=1_000_000)
    assert not lifecycle.should_unload("tts", now=1_000_000)
