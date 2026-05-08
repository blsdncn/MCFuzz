/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
package afl;

/**
 * No-op coverage engine for when the agent is attached outside AFLNet.
 *
 * <p>All operations are free. Used as a fallback when {@code __AFL_SHM_ID}
 * is not present in the environment.
 */
public final class NoOpCoverageEngine implements CoverageEngine {
    @Override
    public void hit(int edgeId) {
        // intentionally empty
    }

    @Override
    public void reset() {
        // intentionally empty
    }

    @Override
    public byte[] snapshot() {
        return new byte[0];
    }
}
