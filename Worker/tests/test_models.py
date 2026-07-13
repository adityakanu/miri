import hashlib
import json
from pathlib import Path

import pytest

from miri_worker.models import ModelEntry, ModelError, ModelManager, ModelManifest


def manifest_for(data: bytes) -> ModelManifest:
    return ModelManifest(
        (
            ModelEntry(
                id="test-model",
                url="https://models.invalid/test.bin",
                sha256=hashlib.sha256(data).hexdigest(),
                size=len(data),
                filename="test.bin",
            ),
        )
    )


def test_loads_pinned_manifest(tmp_path):
    data = b"model"
    path = tmp_path / "manifest.json"
    path.write_text(
        json.dumps(
            {
                "version": 1,
                "models": [
                    {
                        "id": "test-model",
                        "url": "https://models.invalid/test.bin",
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "size": len(data),
                        "filename": "test.bin",
                    }
                ],
            }
        )
    )
    assert ModelManifest.load(path).get("test-model").size == 5


def test_installs_resumes_verifies_and_reports_progress(tmp_path):
    data = b"complete-model-data"
    root = tmp_path / "models"
    root.mkdir()
    (root / "test.bin.partial").write_bytes(data[:8])
    offsets = []

    def fetch(url, offset):
        offsets.append(offset)
        yield data[offset:12]
        yield data[12:]

    progress = []
    manager = ModelManager(root, manifest_for(data), fetcher=fetch)
    installed = manager.install("test-model", lambda current, total: progress.append((current, total)))
    assert offsets == [8]
    assert installed.read_bytes() == data
    assert manager.resolve("test-model") == installed
    assert progress[-1] == (len(data), len(data))
    assert not (root / "test.bin.partial").exists()


def test_rejects_corrupt_download_and_preserves_partial_for_resume(tmp_path):
    expected = b"right-data"

    def fetch(url, offset):
        yield b"wrong-data"[offset:]

    manager = ModelManager(tmp_path, manifest_for(expected), fetcher=fetch)
    with pytest.raises(ModelError, match="checksum"):
        manager.install("test-model")
    assert (tmp_path / "test.bin.partial").exists()


def test_local_override_is_verified_and_never_removed(tmp_path):
    data = b"local-model"
    local = tmp_path / "custom.bin"
    local.write_bytes(data)
    manager = ModelManager(tmp_path / "managed", manifest_for(data), overrides={"test-model": local})
    assert manager.install("test-model") == local
    manager.remove("test-model")
    assert local.exists()


def test_missing_and_corrupt_models_have_actionable_errors(tmp_path):
    manager = ModelManager(tmp_path, manifest_for(b"model"))
    with pytest.raises(ModelError, match="missing"):
        manager.resolve("test-model")
    (tmp_path / "test.bin").write_bytes(b"bad!!")
    with pytest.raises(ModelError, match="checksum"):
        manager.resolve("test-model")


def test_manifest_allows_safe_nested_artifact_paths(tmp_path):
    data = b"nested"
    entry = ModelEntry.from_dict(
        {
            "id": "nested",
            "url": "https://models.invalid/nested.bin",
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
            "filename": "moonshine/model.bin",
        }
    )
    manager = ModelManager(tmp_path, ModelManifest((entry,)), fetcher=lambda url, offset: iter((data[offset:],)))
    assert manager.install("nested") == tmp_path / "moonshine/model.bin"


@pytest.mark.parametrize("filename", ["../escape.bin", "/tmp/escape.bin", "folder/../escape.bin"])
def test_manifest_rejects_unsafe_artifact_paths(filename):
    with pytest.raises(ModelError, match="invalid manifest entry"):
        ModelEntry.from_dict(
            {
                "id": "unsafe",
                "url": "https://models.invalid/file",
                "sha256": "0" * 64,
                "size": 1,
                "filename": filename,
            }
        )
