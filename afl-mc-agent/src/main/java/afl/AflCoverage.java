/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Static facade for AFL-style edge coverage. Instrumented bytecode calls
 * AflCoverage.hit(edgeId) at every control-flow edge. The actual engine
 * is swappable for testing.
 */
package afl;

/**
 * Public API for AFL-style edge coverage tracking.
 *
 * <p>This class is called directly from instrumented bytecode at every
 * control-flow edge. The {@code hit()} method is {@code static} so that
 * the JVM JIT can inline it into the instrumented caller — zero virtual
 * dispatch on the hot path.
 *
 * <p>The underlying {@link CoverageEngine} is held in a package-private
 * static field and can be swapped for testing via
 * {@code AflCoverage.setEngine(...)}.
 */
public final class AflCoverage {

    private AflCoverage() {}

    /** The current engine. Package-private for test access. */
    static volatile CoverageEngine engine;

    private static final EdgeMetrics edgeMetrics;

    static {
        // Default to SHM backend in production.
        // Falls back to a no-op engine if SHM attach fails (e.g., not running under AFLNet).
        engine = CoverageEngine.createDefault();
        edgeMetrics = EdgeMetrics.createFromSystemProperties();
    }

    /**
     * Record a hit on the given edge ID.
     *
     * <p>This is the hot path. It is deliberately a single static method
     * so the JIT can inline it into instrumented bytecode with no virtual
     * dispatch overhead.
     *
     * @param edgeId globally unique edge identifier assigned by the bytecode instrumentor
     */
    public static void hit(int edgeId) {
        EdgeMetrics metrics = edgeMetrics;
        if (metrics != null) {
            metrics.hit(edgeId);
        }
        engine.hit(edgeId);
    }

    /**
     * Reset coverage state for the current thread.
     *
     * <p>Clears the per-thread {@code prevLoc} used in the AFL edge formula.
     * Called automatically when a new Minecraft connection is established,
     * or can be called manually between test cases.
     */
    public static void reset() {
        EdgeMetrics metrics = edgeMetrics;
        if (metrics != null) {
            metrics.reset();
        }
        engine.reset();
    }

    /**
     * Swap the coverage engine. Used only for testing.
     *
     * @param newEngine the engine to install
     */
    public static void setEngine(CoverageEngine newEngine) {
        engine = newEngine;
    }

    /** Return the current engine for inspection. */
    public static CoverageEngine getEngine() {
        return engine;
    }
}
