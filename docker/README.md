# AFLNet experiment container

The Dockerfile provides a reproducible OS/toolchain image (Ubuntu 24.04, JDK 21, Node 24, build tools). It does **not** bake the repository or campaign outputs into the image — mount the repo at `/work`.

## Build image

```bash
scripts/docker-build-aflnet-experiment.sh
```

Default image: `mcfuzz-aflnet-experiment:latest`

## Verify tools

```bash
scripts/test-docker-aflnet-experiment-image.sh
```

## Prepare dependencies and run full test suite

```bash
scripts/test-docker-full-test-path.sh
```

This builds the image (if needed), mounts the repo, runs `make deps` (npm install + native/Gradle builds), then runs `make test` (full regression suite). Expect:

```text
OVERALL PASS
PASS: Docker full test path
```

## Open a shell in the container

```bash
scripts/docker-run-aflnet-experiment.sh bash
```

## Manual workflow inside container

```bash
scripts/docker-run-aflnet-experiment.sh bash -lc '
  make deps
  make test
  make smoke-aflnet
  make smoke-jazzer-stateful
  make smoke-jazzer-stateless
'
```

## Notes

- The container runs as the invoking UID/GID to avoid root-owned output files.
- Generated artifacts (under `campaign-runs/`, `coverage-runs/`, etc.) are written to the mounted repo and persist after the container exits.
- The wrapper mounts the host Gradle cache when present for offline repeatability.
- For cluster/Apptainer use, build the Docker image first and convert/pull according to local cluster policy.
