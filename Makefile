.PHONY: bootstrap generate test test-swift benchmark release-candidate

bootstrap:
	@command -v brew >/dev/null || (echo "Homebrew is required"; exit 1)
	@command -v xcodegen >/dev/null || brew install xcodegen
	swift build

generate:
	xcodegen generate

test: test-swift

test-swift:
	swift test

# Writes an explicitly incomplete report unless latency event samples are supplied.
benchmark:
	python3 scripts/benchmark.py --output artifacts/benchmarks/local.json

release-candidate:
	./scripts/build-release.sh "$(VERSION)"
