# AFLNet experiment container

Two image variants are provided:

- **`mcfuzz-aflnet-experiment:ready`** — prebuilt image with all dependencies resolved and artifacts compiled. This is the recommended evaluator path.
- **`mcfuzz-aflnet-experiment:latest`** — base toolchain image (Ubuntu 24.04, JDK 21, Node 24, build tools). Requires `make deps` on first run.

## Prebuilt ready image (recommended)

Download and load:

```bash
sha256sum -c mcfuzz-aflnet-experiment-ready-*.tar.gz.sha256
gunzip -c mcfuzz-aflnet-experiment-ready-*.tar.gz | docker load
```

### Run AFLNet smoke

```bash
docker run --rm \
  -v "$PWD/campaign-runs:/work/campaign-runs" \
  mcfuzz-aflnet-experiment:ready \
  make smoke-aflnet
```

### Run Jazzer smokes

```bash
docker run --rm \
  -e TIME_LIMIT=30 \
  -v "$PWD/jazzer-outputs:/work/velocity-jazzer-integration/build/jazzer-jacoco-feasibility" \
  mcfuzz-aflnet-experiment:ready \
  make smoke-jazzer-stateful

docker run --rm \
  -e TIME_LIMIT=30 \
  -v "$PWD/jazzer-outputs:/work/velocity-jazzer-integration/build/jazzer-jacoco-feasibility" \
  mcfuzz-aflnet-experiment:ready \
  make smoke-jazzer-stateless
```

### Run full regression suite

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

Inside the shell you can inspect source code, run scripts, or launch campaigns manually:

```bash
ls /work
make smoke-aflnet
CAMPAIGN_SECONDS=600 scripts/run-aflnet-campaign-smoke.sh
cd velocity-jazzer-integration && TIME_LIMIT=600 RESET_OUTPUTS=1 scripts/run-jazzer-direct.sh
```

### Volume mounts explained

The `-v` flag maps a host directory into the container so artifacts persist after the container exits:

```bash
-v "$PWD/campaign-runs:/work/campaign-runs"
```

- Left side: directory on your host machine (created if missing)
- Right side: directory inside the container
- Files written to the container path appear on your host

Common mount points:

| Container path | Purpose |
|---|---|
| `/work/campaign-runs` | AFLNet fuzzing campaigns |
| `/work/velocity-jazzer-integration/build/jazzer` | Jazzer outputs |
| `/work/outputs` | Generic output directory |

If you omit `-v`, all artifacts are lost when the container exits.

### Notes

- The ready image runs as the container default user (not your host UID). Use `docker run --user $(id -u):$(id -g)` if you need matching ownership on mounted outputs.
- The image contains a frozen snapshot of the repository. To inspect or modify code, use an interactive shell.

## Base toolchain image (build from source)

Build locally:

```bash
scripts/docker-build-aflnet-experiment.sh
```

Run with mounted repo:

```bash
docker run --rm -it \
  -v "$PWD:/work" \
  mcfuzz-aflnet-experiment:latest \
  bash -lc 'make deps && make test'
```

The base image does **not** bake the repository or campaign outputs. Mount your clone at `/work` and run `make deps`.

### Verify tools

```bash
scripts/test-docker-aflnet-experiment-image.sh
```

### Notes

- The base image runs as the invoking UID/GID when mounted to avoid root-owned output files.
- Generated artifacts (under `campaign-runs/`, `coverage-runs/`, etc.) are written to the mounted repo and persist after the container exits.
- The wrapper mounts the host Gradle cache when present for offline repeatability. To opt in: `MCFUZZ_DOCKER_GRADLE_HOME="$HOME/.gradle"`.
- For cluster/Apptainer use, build the Docker image first and convert/pull according to local cluster policy.
