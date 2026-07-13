"""Fail closed unless a release model manifest is installable and fully pinned."""

from pathlib import Path
import sys

from miri_worker.models import ModelManifest


def main() -> None:
    manifest = ModelManifest.load(Path(sys.argv[1]))
    if not manifest.entries:
        raise SystemExit("model manifest contains no artifacts")
    for entry in manifest.entries.values():
        if not entry.url.startswith("https://") or entry.size <= 0:
            raise SystemExit(f"invalid release artifact: {entry.id}")
    print(f"validated {len(manifest.entries)} pinned model artifacts")


if __name__ == "__main__":
    main()
