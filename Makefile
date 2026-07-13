.PHONY: bootstrap models-dev generate test test-swift test-python benchmark release-candidate

bootstrap:
	@command -v brew >/dev/null || (echo "Homebrew is required"; exit 1)
	@command -v xcodegen >/dev/null || brew install xcodegen
	@command -v uv >/dev/null || brew install uv
	uv sync --project Worker --extra dev

# Install the real development speech runtimes. Model weights are downloaded
# separately after explicit consent.
models-dev:
	uv sync --project Worker --extra dev --extra inference --frozen

generate:
	xcodegen generate

test: test-swift test-python

test-swift:
	swift test

test-python:
	uv run --project Worker --no-sync pytest

# Writes an explicitly incomplete report unless latency event samples are supplied.
benchmark:
	uv run --project Worker python scripts/benchmark.py --output artifacts/benchmarks/local.json

# VERSION, MIRI_PYTHON_STANDALONE_ARCHIVE and its SHA-256 are required.
release-candidate:
	./scripts/build-release.sh "$(VERSION)"
