# Script Test-Path Contract

## Container dependency preparation

- `scripts/prime-container-deps.sh` prepares a mounted light-image workspace with local-first, internet-fallback behavior.
  - Builds AFLNet and the native javaagent library from local sources.
  - Tries Gradle builds with `--offline` first for `afl-mc-agent` and Velocity.
  - If offline Gradle cannot satisfy dependencies, retries the same Gradle build online.
  - Uses existing `node_modules` for PrismarineJS packages when present.
  - If `node_modules` is missing/empty, runs `npm ci` when a lockfile exists, otherwise `npm install`.
  - Fails with `prime_status=FAIL` if local and internet-backed paths both fail.
- `scripts/test-prime-container-deps.sh` is the fixture test for local-first fallback and fail-if-neither behavior.
- `scripts/test-docker-full-test-path.sh` runs the prime step before the full test path so a cold mounted repo can self-prepare when internet is available.

## Phase 4 campaign smoke

- `scripts/test-aflnet-campaign-smoke.sh` is the public behavior test for the first short live AFLNet campaign smoke.
- `scripts/run-aflnet-campaign-smoke.sh` starts flying-squid, Velocity with the javaagent, and AFLNet `-P MC` for a bounded run.
- The campaign smoke creates a unique run directory under `campaign-runs/` unless `CAMPAIGN_RUN_DIR` is provided, and writes `run-summary.txt` plus logs and AFLNet artifacts.
- `CAMPAIGN_SECONDS` defaults to `120`; the test script may override it for a shorter liveness check.
- The default AFLNet binary is the repo-built `aflnet/afl-fuzz`.
- In `state-aware` and `code-only` modes, the runner creates a SysV SHM segment, passes `__AFL_SHM_ID` to Velocity, and runs AFLNet with `AFLNET_REUSE_SHM_ID=1` so both processes use the same bitmap.
- In `state-only` mode, the runner does not share AFL SHM with Velocity; the javaagent falls back to `NoOpCoverageEngine`, preserving instrumentation compatibility without Java edge-feedback as AFLNet guidance.
- `run-summary.txt` reports `agent_engine=ShmCoverageEngine` and `edge_feedback_evidence=shm-attached` when Java edge-feedback plumbing is active.
- `run-summary.txt` classifies AFLNet exits; `unexpected-sigsegv` / exit `139` is an infrastructure failure.
- `AFLNET_USE_LOCAL_SMOKE_BINARY=1` is an explicit opt-in compatibility path, not the default.
- Successful runs print `WATCH_STATS_CMD=<repo>/scripts/watch-aflnet-stats.sh <run-dir>` for compact AFLNet progress watching without enabling AFL's curses UI.
- `scripts/watch-aflnet-stats.sh <run-dir>` prints compact live stats from `aflnet-out/fuzzer_stats` and `plot_data`; `--once` prints one snapshot for scripts/tests.

### Target-side outcome classification

`run-summary.txt` distinguishes target-side outcomes from fuzzer infrastructure failures. The reusable classifier is `scripts/classify-campaign-logs.sh`, and `scripts/test-campaign-log-classification.sh` validates it with fixture logs so the live campaign smoke stays a broad tracer bullet.

These classification fields are campaign diagnostics / oracle outputs only; they are not AFLNet mutation feedback signals.

- `velocity_process_status`: `alive`, `exited`, `missing`, or `unknown`.
- `velocity_process_death`: `yes` only when the Velocity process exited before summary collection; otherwise `no`.
- `velocity_fatal_exception_count`: strict fatal/unhandled JVM signals such as `Exception in thread`, `Uncaught`, `LinkageError`, `ClassFormatError`, or `VerifyError`.
- `handled_client_exception_count`: handled malformed-client/protocol rejection evidence such as invalid protocol or player disconnect log lines.
- `backend_or_session_error_count`: backend/session noise such as server-connection handler exceptions or internal backend connection errors.
- `connection_reset_count` and `timeout_count`: transport symptoms counted separately from target crashes.
- `target_failure_class`: one of `clean`, `handled-rejections`, `timeout-heavy`, `connection-reset-heavy`, `fatal-log`, `process-death`, or `unknown`.

Do not treat every Velocity exception log as a crash; use `velocity_fatal_exception_count` and `velocity_process_death` for crash-like target signals. Current `target_failure_class` priority is: `process-death` > `fatal-log` > `connection-reset-heavy` > `timeout-heavy` > `handled-rejections` > `clean` / `unknown`.

## Evaluation lane wrapper

- `scripts/run-eval-lane.sh`
  - Runs a JaCoCo baseline, a bounded JaCoCo-enabled AFLNet campaign, JaCoCo XML comparison, hang artifact analysis, and campaign report generation as one orchestration step.
  - Writes an evaluation directory under `eval-runs/` with:
    - `velocity-jacoco-baseline/`
    - `campaign/`
    - `eval-summary.txt`
    - `eval-metadata.txt`
  - Intended for medium/long evaluation runs where you want report-ready artifacts, not just a smoke verdict.
  - Supports `AFLNET_FEEDBACK_MODE=state-aware|code-only|state-only`.
  - Supports `RUN_BASELINE=0` with `BASELINE_XML=<path>` to reuse one baseline across paired comparison runs.

## Cluster Apptainer wrappers

- `scripts/run-cluster-apptainer.sh <command...>`
  - Cluster-side helper.
  - Loads `apptainer/1.3.6`, binds the staged repo to `/work`, uses `--cleanenv`, and runs the given command under the light experiment image with a container-first PATH.
- `scripts/submit-cluster-eval-job.sh`
  - Cluster-side Slurm submit helper for `scripts/run-eval-lane.sh`.
  - Defaults:
    - `SLURM_PARTITION=cpu`
    - `SLURM_CONSTRAINT=skylake`
    - `SLURM_CPUS_PER_TASK=4`
    - `SLURM_MEM=16G`
  - Supports:
    - `AFLNET_FEEDBACK_MODE=state-aware|code-only|state-only`
    - `CAMPAIGN_SECONDS=<seconds>`
    - `RUN_BASELINE=1|0`
    - `BASELINE_XML=<path>` when reusing a baseline
    - `SLURM_TIME=<hh:mm:ss>`
    - `PRIME_CONTAINER_DEPS=1|0`
    - `SLURM_EXCLUSIVE=1` when full-node isolation is worth the queue tradeoff
  - Writes the generated batch script under `slurm-jobs/` before submission.

### Portal / login-shell gotcha

On the UVA CS environment, `portal.cs.virginia.edu` may appear to be missing
Slurm commands if you check it with a bare non-login shell such as:

```bash
ssh uyk5kn@portal.cs.virginia.edu 'which sbatch'
```

That can report a false negative because the Slurm PATH setup happens in a
**login shell**. Use one of these instead:

```bash
ssh uyk5kn@portal.cs.virginia.edu "bash -lc 'which sbatch && which squeue && which sinfo'"
ssh uyk5kn@portal.cs.virginia.edu "bash -lc 'module load java/21; cd /u/uyk5kn/mcfuzz/investigate-aflnet-velocity-jacoco-javagent && scripts/submit-cluster-eval-job.sh'"
```

Practical rule: if `portal` says `sbatch` is missing, retry inside
`bash -lc` before assuming the cluster workflow is broken.

## Campaign interpretability helpers

- `scripts/summarize-campaign-run.sh <run-dir>`
  - Writes `<run-dir>/campaign-report.md` from existing artifacts.
  - Includes verdict, config, AFLNet progress, minimal timeline, feedback metrics, target diagnostics, JaCoCo comparison if present, hang section, caveats, and artifact index.
  - Includes JaCoCo line-location aggregates when the coverage comparison artifact contains them.
  - Hang reporting is transparent aggregate-only in the main report: no black-box hang verdict and no per-sample replay dump.
  - Does not auto-run hang analysis.
- `scripts/analyze-aflnet-hangs.sh <run-dir>`
  - Writes `<run-dir>/hang-analysis.txt` from `aflnet-out/replayable-hangs/`.
  - Artifact-only: counts hangs, hashes/dedupes files, reports size range, first/last artifact times, and sample files.
  - Does not replay hangs or classify target behavior.
- `scripts/classify-aflnet-hang-replays.sh <run-dir> [sample-count]`
  - Replays a deterministic sample from `aflnet-out/replayable-hangs/` with `aflnet-replay`.
  - Uses first/middle/last stratified sampling for larger samples.
  - Assumes a compatible target stack is already listening unless using test/fake replayer environment variables.
  - Writes `<run-dir>/hang-replay-classification.txt` plus per-sample logs under `<run-dir>/hang-replay-logs/`.
  - Parses replay logs for packet counts and `Responses from server:` sequences.
  - Runs `aflnet-replay` with `AFLNET_REPLAY_STRICT=1` so no-response, truncated replay, send failure, and receive failure exits are classified explicitly.
  - Distinguishes replay timeouts, strict no-response exits, malformed replay exits, generic nonzero exits, and `aflnet-replay` segfault exits (`replay_sigsegv_count`).
  - Sample-based classification only; it does not tune AFLNet timeouts or prove all hangs reproduce/non-reproduce.
- `scripts/test-aflnet-replay-hardened.sh`
  - Regression test for `aflnet-replay` strict diagnostics.
  - Verifies no-response and truncated replay files return classified nonzero exits instead of misleading success or segfault.
  - Verifies MC response parsing initializes AFLNet message-code mapping and does not segfault.
- `AFLNET_STATS_LOG_INTERVAL=<seconds>`
  - Optional campaign-runner flag.
  - Writes timestamped compact AFLNet snapshots to `<run-dir>/logs/watch-stats.log`.
  - Default is disabled.

## Non-default JaCoCo reporting lane

These scripts support human-readable coverage reporting and apples-to-apples baseline/campaign comparison. They are not AFLNet mutation feedback and are not part of the default campaign smoke path.

- `scripts/test-velocity-jacoco-baseline.sh`
  - Runs the whole Velocity repo test suite with JaCoCo using a generated Gradle init script.
  - Reports over all compiled main classes from included Velocity Gradle projects.
  - Writes XML/HTML/exec artifacts and `coverage-summary.txt` under `coverage-runs/`.
  - Requires nonzero JaCoCo counters but sets no coverage threshold.
- `scripts/test-velocity-dual-agent-compatibility.sh`
  - Runs the selected Velocity proxy compatibility subset with JaCoCo first and `afl-mc-agent` second.
  - Verifies both agents can coexist on meaningful protocol/proxy tests.
- `scripts/test-aflnet-campaign-jacoco-smoke.sh`
  - Non-default campaign smoke with `ENABLE_JACOCO=1`.
  - Uses the default `JACOCO_WINDOW_MODE=whole-process` behavior.
  - Mirrors the default campaign shape, then intentionally stops Velocity after confirming it survived so JaCoCo can dump coverage.
  - Labels JaCoCo coverage as whole-process: startup, preflight, AFLNet campaign traffic, and teardown are included.
  - Does not change `scripts/test-aflnet-campaign-smoke.sh` default behavior.
- `scripts/test-aflnet-campaign-jacoco-epoch-smoke.sh`
  - Non-default campaign smoke with `ENABLE_JACOCO=1 JACOCO_WINDOW_MODE=campaign-epoch`.
  - Dumps and resets JaCoCo after startup/preflight, then dumps campaign coverage before teardown.
  - Generates the report from `jacoco-campaign.exec` and keeps `jacoco-startup-preflight.exec` as diagnostic evidence.
- `scripts/test-aflnet-campaign-jacoco-window-mode-comparison.sh`
  - Runs short whole-process and campaign-epoch smokes back-to-back.
  - Asserts campaign-epoch remains nonzero but does not exceed whole-process on coarse JaCoCo counters, and is strictly smaller on at least one coarse metric.
- `scripts/compare-jacoco-coverage.sh [--details-dir <dir>] <baseline-jacoco.xml> <campaign-jacoco.xml>`
  - Emits coarse counter comparison plus class/package covered-line deltas.
  - Emits JaCoCo source-line-location aggregate metrics from `package/sourcefile/line` entries.
  - With `--details-dir`, writes covered/missed line detail files including campaign-only and baseline-only covered lines.
  - Emits no thresholds and no improvement claim.
- `JACOCO_WINDOW_MODE=whole-process|campaign-epoch`
  - Optional flag for `scripts/run-aflnet-campaign-smoke.sh` when `ENABLE_JACOCO=1`.
  - `whole-process` keeps the original dump-on-exit behavior.
  - `campaign-epoch` uses JaCoCo `tcpserver` control plus explicit dump/reset so startup/preflight and teardown are excluded from the reported campaign exec.
- `scripts/test-jacoco-coverage-comparison.sh`
  - Fixture test for coarse and aggregate JaCoCo XML comparison behavior.
- `scripts/test-jacoco-line-coverage-comparison.sh`
  - Fixture test for line-location JaCoCo detail files.
- `scripts/spike-jazzer-jacoco-feasibility.sh`
  - Additive feasibility runner for `velocity-jazzer-integration` that wraps existing Jazzer run scripts with a JaCoCo javaagent.
  - Produces a non-default spike directory containing `jazzer.exec`, JaCoCo XML/HTML report, copied Jazzer logs/summary, and `feasibility-summary.txt`.
  - Purpose is architecture decision support (can Jazzer fuzz runs emit JaCoCo XML in the same style), not production fuzz orchestration.
- `scripts/test-jazzer-jacoco-feasibility-spike.sh`
  - Integration-style test for the feasibility runner through the public script interface.
  - Uses a short time budget and asserts non-empty JaCoCo exec/XML plus a PASS feasibility summary.
- `scripts/cross-fuzzer-normalize-coverage.py`
  - Read JaCoCo XML paths from a run-manifest CSV (columns `label,engine,config,jacoco_xml`), filter to Velocity project packages, and emit unified root/module/package coverage tables plus package/engine overlap tables.
  - Supports `--project-prefix` and `--module-rules-file` for customization.
  - Additive: no engine fuzz-target changes; works purely on output artifacts.
- `scripts/test-cross-fuzzer-normalize-coverage.sh`
  - Fixture-based integration test for the cross-fuzzer normalizer.
  - Verifies module coverage metrics are nonzero, engine-overlap tables include both engines, and the normalizer handles JaCoCo XML package-name slash/dot normalization.

## Phase 4 current paths

1. **Default public green path** — `scripts/test-full-stack-smoke.sh`
   - Normal correctness/tracer-bullet test.
   - Starts the full stack, uses the javaagent, replays one real seed, and verifies state-transition extraction.
   - Currently relies on the exact-class workaround: `com.velocitypowered.proxy.protocol.packet.title.GenericTitlePacket` is excluded from instrumentation.

2. **Diagnostic known-bug reproduction** — `scripts/test-title-packet-cluster-repro.sh`
   - Not a correctness test and not part of the normal green product path.
   - Passes when the current known no-exclusion `GenericTitlePacket` failure is reproduced.

3. **Non-default desired-future compatibility target** — `scripts/test-title-packet-no-exclusion-desired.sh`
   - Defines the exit condition for removing the `GenericTitlePacket` exclusion.
   - Expected to fail today.
   - Must not be added to the default test path until the compatibility issue is fixed.
