"""Pinned model manifests and resumable, checksum-verified installation."""

from __future__ import annotations

import hashlib
import json
import os
import urllib.request
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Iterator


class ModelError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class ModelEntry:
    id: str
    url: str
    sha256: str
    size: int
    filename: str

    @classmethod
    def from_dict(cls, value: dict[str, object]) -> "ModelEntry":
        entry = cls(
            id=str(value["id"]),
            url=str(value["url"]),
            sha256=str(value["sha256"]).lower(),
            size=int(value["size"]),
            filename=str(value["filename"]),
        )
        if len(entry.sha256) != 64 or any(c not in "0123456789abcdef" for c in entry.sha256):
            raise ModelError(f"invalid checksum for {entry.id}")
        relative = PurePosixPath(entry.filename)
        if entry.size < 0 or relative.is_absolute() or not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
            raise ModelError(f"invalid manifest entry for {entry.id}")
        return entry


class ModelManifest:
    def __init__(self, entries: tuple[ModelEntry, ...], version: int = 1) -> None:
        self.version = version
        self.entries = {entry.id: entry for entry in entries}
        if len(self.entries) != len(entries):
            raise ModelError("duplicate model id")

    @classmethod
    def load(cls, path: Path) -> "ModelManifest":
        value = json.loads(path.read_text(encoding="utf-8"))
        if value.get("version") != 1:
            raise ModelError("unsupported model manifest version")
        return cls(tuple(ModelEntry.from_dict(item) for item in value["models"]), version=1)

    def get(self, model_id: str) -> ModelEntry:
        try:
            return self.entries[model_id]
        except KeyError as error:
            raise ModelError(f"unknown model: {model_id}") from error


Progress = Callable[[int, int], None]
Fetcher = Callable[[str, int], Iterator[bytes]]


def _http_fetch(url: str, offset: int) -> Iterator[bytes]:
    request = urllib.request.Request(url, headers={"Range": f"bytes={offset}-"} if offset else {})
    with urllib.request.urlopen(request) as response:  # noqa: S310 - pinned checksum is mandatory
        # If a server ignores Range, restart rather than append duplicate content.
        if offset and getattr(response, "status", None) != 206:
            raise ModelError("server does not support resuming this download")
        while chunk := response.read(1024 * 1024):
            yield chunk


class ModelManager:
    def __init__(
        self,
        root: Path,
        manifest: ModelManifest,
        *,
        overrides: dict[str, Path] | None = None,
        fetcher: Fetcher = _http_fetch,
    ) -> None:
        self.root = root
        self.manifest = manifest
        self.overrides = overrides or {}
        self.fetcher = fetcher

    @staticmethod
    def checksum(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
        return digest.hexdigest()

    def resolve(self, model_id: str) -> Path:
        entry = self.manifest.get(model_id)
        path = self.overrides.get(model_id, self.root / entry.filename).expanduser()
        if not path.is_file():
            raise ModelError(f"model missing: {model_id}")
        if path.stat().st_size != entry.size or self.checksum(path) != entry.sha256:
            raise ModelError(f"model checksum mismatch: {model_id}")
        return path

    def install(self, model_id: str, progress: Progress | None = None) -> Path:
        entry = self.manifest.get(model_id)
        if model_id in self.overrides:
            return self.resolve(model_id)
        self.root.mkdir(parents=True, exist_ok=True)
        destination = self.root / entry.filename
        partial = destination.with_suffix(destination.suffix + ".partial")
        destination.parent.mkdir(parents=True, exist_ok=True)
        offset = partial.stat().st_size if partial.exists() else 0
        if offset > entry.size:
            partial.unlink()
            offset = 0
        try:
            with partial.open("ab") as sink:
                for chunk in self.fetcher(entry.url, offset):
                    sink.write(chunk)
                    offset += len(chunk)
                    if offset > entry.size:
                        raise ModelError(f"download exceeds manifest size: {model_id}")
                    if progress:
                        progress(offset, entry.size)
                sink.flush()
                os.fsync(sink.fileno())
        except ModelError as error:
            if "does not support resuming" not in str(error) or not partial.exists():
                raise
            partial.unlink()
            return self.install(model_id, progress)
        if offset != entry.size or self.checksum(partial) != entry.sha256:
            raise ModelError(f"download checksum mismatch: {model_id}")
        partial.replace(destination)
        return destination

    def remove(self, model_id: str) -> None:
        entry = self.manifest.get(model_id)
        if model_id not in self.overrides:
            destination = self.root / entry.filename
            for path in (destination, destination.with_suffix(destination.suffix + ".partial")):
                if path.exists():
                    path.unlink()
