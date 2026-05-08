/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
package afl;

import sun.misc.Unsafe;

/**
 * Production coverage engine backed by AFLNet's POSIX shared memory segment.
 *
 * <p>Attaches to the SHM identified by {@code __AFL_SHM_ID} via JNI,
 * then uses {@link Unsafe} for fast byte-level increments.
 */
public final class ShmCoverageEngine implements CoverageEngine {

    /** AFLNet bitmap size: 2^16 = 65536 bytes. */
    public static final int MAP_SIZE = 1 << 16;
    /** AFL hash constant from aflnet/config.h. */
    public static final int HASH_CONST = 0xa5b35705;

    private final long shmBase;
    private final ThreadLocal<Integer> prevLoc;

    /**
     * Attach to the AFLNet SHM segment.
     *
     * @param shmIdEnv the value of the {@code __AFL_SHM_ID} environment variable
     */
    public ShmCoverageEngine(String shmIdEnv) {
        int shmId;
        try {
            shmId = Integer.parseInt(shmIdEnv);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("Invalid __AFL_SHM_ID: " + shmIdEnv, e);
        }
        this.shmBase = NativeShm.attach(shmId);
        if (shmBase == 0L) {
            throw new IllegalStateException("shmat() failed for shm_id=" + shmId);
        }
        this.prevLoc = ThreadLocal.withInitial(() -> 0);
    }

    @Override
    public void hit(int edgeId) {
        int curLoc = (edgeId * HASH_CONST) >>> 16;
        int prev = prevLoc.get();
        int idx = (curLoc ^ prev) & (MAP_SIZE - 1);

        long addr = shmBase + idx;
        byte counter = UnsafeHolder.UNSAFE.getByte(addr);
        int unsigned = counter & 0xFF;
        if (unsigned < 0xFF) {
            UnsafeHolder.UNSAFE.putByte(addr, (byte)(unsigned + 1));
        }

        prevLoc.set(curLoc >>> 1);
    }

    @Override
    public void reset() {
        prevLoc.set(0);
    }

    @Override
    public byte[] snapshot() {
        byte[] copy = new byte[MAP_SIZE];
        for (int i = 0; i < MAP_SIZE; i++) {
            copy[i] = UnsafeHolder.UNSAFE.getByte(shmBase + i);
        }
        return copy;
    }

    /** Lazy holder for Unsafe to avoid early initialization. */
    private static final class UnsafeHolder {
        static final Unsafe UNSAFE;
        static {
            try {
                java.lang.reflect.Field f = Unsafe.class.getDeclaredField("theUnsafe");
                f.setAccessible(true);
                UNSAFE = (Unsafe) f.get(null);
            } catch (Exception e) {
                throw new RuntimeException("Failed to obtain sun.misc.Unsafe", e);
            }
        }
    }
}
