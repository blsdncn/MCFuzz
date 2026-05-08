# AFLNet + Jazzer Fuzzing Harness for Velocity

Fuzzes Velocity Minecraft proxy protocol handling with two complementary engines:

- **AFLNet**: live network fuzzing against Velocity plus a Minecraft backend.
- **Jazzer**: in-process JVM fuzzing of Velocity protocol/packet code.

## Recommended Docker workflow

Use Docker when you want the full toolchain without preparing the host manually.

```bash
# Build/check the toolchain image.
scripts/test-docker-aflnet-experiment-image.sh

# Run dependency setup plus the full regression suite in the container.
scripts/test-docker-full-test-path.sh
```

Open an interactive container shell:

```bash
scripts/docker-run-aflnet-experiment.sh bash
```

Manual container workflow:

```bash
scripts/docker-run-aflnet-experiment.sh bash -lc '
  make deps
  make test
  make smoke-aflnet
  make smoke-jazzer-stateful
  make smoke-jazzer-stateless
'
```

## Native workflow

Use this if the host already has the required tools.

Required host tools: Linux/WSL, Bash, GNU coreutils, `make`, `gcc`, Java 21, Python 3, Node.js 24/npm, `unzip`, `curl`.

```bash
make deps    # npm install + AFLNet/native/Gradle builds
make test    # full regression suite
```

Individual smokes:

```bash
make smoke-aflnet
make smoke-jazzer-stateful
make smoke-jazzer-stateless
```

## 10-minute AFLNet campaign examples

Default state-aware run:

```bash
CAMPAIGN_SECONDS=600 AFLNET_FEEDBACK_MODE=state-aware scripts/run-aflnet-campaign-smoke.sh
```

Other feedback modes:

```bash
CAMPAIGN_SECONDS=600 AFLNET_FEEDBACK_MODE=code-only scripts/run-aflnet-campaign-smoke.sh
CAMPAIGN_SECONDS=600 AFLNET_FEEDBACK_MODE=state-only scripts/run-aflnet-campaign-smoke.sh
```

Campaign-epoch JaCoCo coverage (excludes startup/preflight/teardown from reported campaign coverage):

```bash
CAMPAIGN_SECONDS=600 \
AFLNET_FEEDBACK_MODE=state-aware \
ENABLE_JACOCO=1 \
JACOCO_WINDOW_MODE=campaign-epoch \
scripts/run-aflnet-campaign-smoke.sh
```

Use all bundled AFLNet seeds, including high-impact queue-derived seeds:

```bash
CAMPAIGN_SEED_GLOB='*.bin' CAMPAIGN_SECONDS=600 scripts/run-aflnet-campaign-smoke.sh
```

## Jazzer campaign examples

```bash
cd velocity-jazzer-integration
TIME_LIMIT=600 RESET_OUTPUTS=1 scripts/run-jazzer-direct.sh
TIME_LIMIT=600 RESET_OUTPUTS=1 scripts/run-jazzer-direct-stateless.sh
```

Jazzer+JaCoCo feasibility wrappers:

```bash
MODE=stateful TIME_LIMIT=180 RESET_OUTPUTS=1 scripts/spike-jazzer-jacoco-feasibility.sh
MODE=stateless TIME_LIMIT=180 RESET_OUTPUTS=1 scripts/spike-jazzer-jacoco-feasibility.sh
```

## Seeds

`seeds/` contains the original generated seeds plus eight small high-impact AFLNet queue entries selected from prior `+cov` runs. See `seeds/MANIFEST.csv`.

## Layout

| Path | Purpose |
|---|---|
| `aflnet/` | AFLNet with Minecraft protocol support |
| `afl-mc-agent/` | Java edge-feedback instrumentation agent |
| `velocity/` | Velocity proxy target for AFLNet/JaCoCo |
| `velocity-jazzer-integration/` | Velocity tree with Jazzer fuzz targets |
| `prismarinejs/` | Vendored flying-squid backend and protocol library source |
| `scripts/` | Setup, smoke, regression, Docker, and evaluation scripts |
| `seeds/` | AFLNet seed corpus |
| `docker/` | Toolchain container definition |
