/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
package afl;

/**
 * Local byte[]-backed coverage engine for unit testing.
 *
 * <p>Uses a plain Java {@code byte[]} instead of shared memory,
 * so tests can run without AFLNet or JNI.
 */
public final class LocalCoverageEngine implements CoverageEngine {

    public static final int HASH_CONST = ShmCoverageEngine.HASH_CONST;

    private final byte[] bitmap;
    private final int mask;
    private final ThreadLocal<Integer> prevLoc;

    public LocalCoverageEngine(int size) {
        if (size <= 0 || (size & (size - 1)) != 0) {
            throw new IllegalArgumentException("Size must be a positive power of two, got: " + size);
        }
        this.bitmap = new byte[size];
        this.mask = size - 1;
        this.prevLoc = ThreadLocal.withInitial(() -> 0);
    }

    @Override
    public void hit(int edgeId) {
        int curLoc = (edgeId * HASH_CONST) >>> 16;
        int prev = prevLoc.get();
        int idx = (curLoc ^ prev) & mask;

        byte counter = bitmap[idx];
        int unsigned = counter & 0xFF;
        if (unsigned < 0xFF) {
            bitmap[idx] = (byte)(unsigned + 1);
        }

        prevLoc.set(curLoc >>> 1);
    }

    @Override
    public void reset() {
        prevLoc.set(0);
    }

    @Override
    public byte[] snapshot() {
        return bitmap.clone();
    }
}
