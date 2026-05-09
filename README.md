# AFLNet + Jazzer Fuzzing Harness for Velocity

Fuzzes Velocity Minecraft proxy protocol handling with two complementary engines:

- **AFLNet**: live network fuzzing against Velocity plus a Minecraft backend.
- **Jazzer**: in-process JVM fuzzing of Velocity protocol/packet code.

## Quickstart (recommended)

Download the prebuilt Docker image and load it:

```bash
sha256sum -c mcfuzz-aflnet-experiment-ready-*.tar.gz.sha256
gunzip -c mcfuzz-aflnet-experiment-ready-*.tar.gz | docker load
```

The image tag is `mcfuzz-aflnet-experiment:ready`. It contains a frozen snapshot of the repository with all dependencies already built. Nothing else is required.

### Run AFLNet smoke test

```bash
docker run --rm \
  -v "$PWD/campaign-runs:/work/campaign-runs" \
  mcfuzz-aflnet-experiment:ready \
  make smoke-aflnet
```

Campaign artifacts are written to `./campaign-runs/` on your host.

### Run Jazzer smoke tests

```bash
# Stateful Jazzer
docker run --rm \
  -e TIME_LIMIT=30 \
  -v "$PWD/jazzer-outputs:/work/velocity-jazzer-integration/build/jazzer" \
  mcfuzz-aflnet-experiment:ready \
  make smoke-jazzer-stateful

# Stateless Jazzer
docker run --rm \
  -e TIME_LIMIT=30 \
  -v "$PWD/jazzer-outputs:/work/velocity-jazzer-integration/build/jazzer" \
  mcfuzz-aflnet-experiment:ready \
  make smoke-jazzer-stateless
```

### Run the full regression suite

```bash
docker run --rm mcfuzz-aflnet-experiment:ready make test
```

### Open an interactive shell

```bash
docker run --rm -it \
  -v "$PWD/outputs:/work/outputs" \
  mcfuzz-aflnet-experiment:ready \
  bash
```

Inside the shell you can inspect code, run individual scripts, or launch longer campaigns:

```bash
# Inspect the repo
ls /work

# Run a 10-minute AFLNet campaign
docker run --rm \
  -v "$PWD/outputs:/work/outputs" \
  mcfuzz-aflnet-experiment:ready \
  bash -lc '
    CAMPAIGN_SECONDS=600 \
    CAMPAIGN_SEED_GLOB="*.bin" \
    scripts/run-aflnet-campaign-smoke.sh
  '

# Run longer Jazzer campaigns
docker run --rm \
  -v "$PWD/outputs:/work/outputs" \
  mcfuzz-aflnet-experiment:ready \
  bash -lc '
    cd /work/velocity-jazzer-integration
    TIME_LIMIT=600 RESET_OUTPUTS=1 scripts/run-jazzer-direct.sh
  '
```

### Volume mount explained

The `-v` flag maps a host directory into the container:

```bash
-v "$PWD/outputs:/work/outputs"
```

- Left side (`$PWD/outputs`): directory on your host machine
- Right side (`/work/outputs`): directory inside the container
- Files written to `/work/outputs` in the container appear in `./outputs` on your host

If you omit the volume, all generated artifacts are lost when the container exits.

## Build the image locally (optional)

If you prefer to build from source instead of using the prebuilt image:

```bash
scripts/docker-build-aflnet-experiment.sh
docker run --rm -it -v "$PWD:/work" mcfuzz-aflnet-experiment:latest bash
```

The `latest` tag is the base toolchain image. It does **not** contain pre-built artifacts — you must run `make deps` inside the container.

## Native workflow 

Use this only if the host already has the required tools.

Required host tools: Linux/WSL, Bash, GNU coreutils, `make`, `gcc`, Java 21, Python 3, Node.js 24/npm, `unzip`, `curl`.

```bash
make deps    # npm install + AFLNet/native/Gradle builds
make test    # full regression suite
make smoke-aflnet
make smoke-jazzer-stateful
make smoke-jazzer-stateless
```

The committed `velocity/velocity.toml` is the expected offline fuzzing config.

## Campaign examples

### AFLNet 10-minute campaigns

```bash
# State-aware (default)
CAMPAIGN_SECONDS=600 AFLNET_FEEDBACK_MODE=state-aware scripts/run-aflnet-campaign-smoke.sh

# Code-only feedback
CAMPAIGN_SECONDS=600 AFLNET_FEEDBACK_MODE=code-only scripts/run-aflnet-campaign-smoke.sh

# State-only feedback
CAMPAIGN_SECONDS=600 AFLNET_FEEDBACK_MODE=state-only scripts/run-aflnet-campaign-smoke.sh
```

Use all bundled seeds:

```bash
CAMPAIGN_SEED_GLOB='*.bin' CAMPAIGN_SECONDS=600 scripts/run-aflnet-campaign-smoke.sh
```

### Jazzer campaigns

```bash
cd velocity-jazzer-integration
TIME_LIMIT=600 RESET_OUTPUTS=1 scripts/run-jazzer-direct.sh
TIME_LIMIT=600 RESET_OUTPUTS=1 scripts/run-jazzer-direct-stateless.sh
```

### JaCoCo coverage windowing

```bash
CAMPAIGN_SECONDS=600 \
AFLNET_FEEDBACK_MODE=state-aware \
ENABLE_JACOCO=1 \
JACOCO_WINDOW_MODE=campaign-epoch \
scripts/run-aflnet-campaign-smoke.sh
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
