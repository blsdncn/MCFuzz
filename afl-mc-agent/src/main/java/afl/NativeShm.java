/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
package afl;

/**
 * JNI bridge to POSIX shared memory ({@code shmget} / {@code shmat}).
 *
 * <p>The native library must be loaded before use. In production this is
 * done automatically by the agent; in tests it must be loaded explicitly
 * or the {@link LocalCoverageEngine} should be used instead.
 */
final class NativeShm {

    static {
        // Try to load the native library from java.library.path.
        // In the shadow JAR, the .so is extracted to a temp file and loaded.
        System.loadLibrary("aflmcshm");
    }

    private NativeShm() {}

    /**
     * Attach to a SysV shared memory segment.
     *
     * @param shmId the shared memory identifier
     * @return the base address of the attached segment, or 0 on failure
     */
    static native long attach(int shmId);
}
