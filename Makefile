.PHONY: deps test smoke-aflnet smoke-jazzer-stateful smoke-jazzer-stateless

deps:
	./scripts/setup-prismarine-deps.sh
	./scripts/build-required-artifacts.sh

test:
	./scripts/run-regression-suite.sh

smoke-aflnet:
	./scripts/test-aflnet-campaign-smoke.sh

smoke-jazzer-stateful:
	MODE=stateful TIME_LIMIT=$${TIME_LIMIT:-30} ./scripts/spike-jazzer-jacoco-feasibility.sh

smoke-jazzer-stateless:
	MODE=stateless TIME_LIMIT=$${TIME_LIMIT:-30} ./scripts/spike-jazzer-jacoco-feasibility.sh
