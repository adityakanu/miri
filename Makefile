.PHONY: bootstrap generate test test-swift benchmark verify-evidence release-candidate

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

# Fail-closed: refuses stale or incomplete benchmark evidence for HEAD.
verify-evidence:
	./scripts/verify-release-evidence.sh "$$(git rev-parse HEAD)" artifacts/benchmarks/m4-responsive.json

release-candidate:
	./scripts/build-release.sh "$(VERSION)"
