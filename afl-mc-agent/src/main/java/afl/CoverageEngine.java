/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
package afl;

/**
 * Internal engine for AFL-style edge coverage.
 *
 * <p>Not part of the public API — instrumented bytecode calls
 * {@link AflCoverage#hit(int)} which delegates here.
 */
public interface CoverageEngine {

    /** Record a hit on the given edge ID. Must be thread-safe. */
    void hit(int edgeId);

    /** Reset per-thread state (prevLoc). Does NOT clear the bitmap. */
    void reset();

    /**
     * Return a copy of the current bitmap for inspection/testing.
     *
     * @return a defensive copy of the coverage bitmap bytes
     */
    byte[] snapshot();

    /**
     * Create the default production engine (SHM-backed).
     *
     * <p>If {@code __AFL_SHM_ID} is not set, falls back to a no-op engine
     * so the agent can be attached outside of AFLNet without crashing.
     */
    static CoverageEngine createDefault() {
        String shmIdEnv = System.getenv("__AFL_SHM_ID");
        if (shmIdEnv != null && !shmIdEnv.isEmpty()) {
            try {
                return new ShmCoverageEngine(shmIdEnv);
            } catch (Exception e) {
                System.err.println("[afl-mc-agent] Failed to attach SHM, falling back to no-op: " + e.getMessage());
            }
        }
        return new NoOpCoverageEngine();
    }

    /** Create a local byte[]-backed engine for testing. */
    static CoverageEngine createLocal(int size) {
        return new LocalCoverageEngine(size);
    }
}
