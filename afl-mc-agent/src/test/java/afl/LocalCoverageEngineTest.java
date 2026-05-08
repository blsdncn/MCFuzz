/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
package afl;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class LocalCoverageEngineTest {

    @Test
    void testHitAndSnapshot() {
        LocalCoverageEngine engine = new LocalCoverageEngine(65536);

        // Hit a few edges
        engine.hit(5);
        engine.hit(5); // same edge again
        engine.hit(7);

        byte[] snapshot = engine.snapshot();

        // The exact indices depend on the hash function, but we can verify
        // that some bytes are non-zero and the array has the right size
        int nonZeroCount = 0;
        for (byte b : snapshot) {
            if (b != 0) nonZeroCount++;
        }

        assertEquals(65536, snapshot.length);
        assertTrue(nonZeroCount > 0, "Expected some non-zero bytes after hits");
    }

    @Test
    void testReset() {
        LocalCoverageEngine engine = new LocalCoverageEngine(65536);

        engine.hit(42);
        engine.reset();
        engine.hit(42);

        // After reset, the prevLoc starts fresh, so the same edgeId
        // may map to a different index. The important thing is that
        // reset doesn't crash and the second hit works.
        byte[] snapshot = engine.snapshot();
        assertEquals(65536, snapshot.length);
    }

    @Test
    void testNoOpEngine() {
        NoOpCoverageEngine engine = new NoOpCoverageEngine();
        engine.hit(999);
        engine.reset();
        assertEquals(0, engine.snapshot().length);
    }

    @Test
    void testCounterDoesNotWrapAt127() {
        LocalCoverageEngine engine = new LocalCoverageEngine(65536);

        // Hit the same edge exactly 127 times — counter should be 127
        for (int i = 0; i < 127; i++) {
            engine.hit(99);
            engine.reset();
        }

        byte[] snapshot = engine.snapshot();
        int idx = ((99 * LocalCoverageEngine.HASH_CONST) >>> 16) & (65536 - 1);
        byte counter = snapshot[idx];

        assertEquals(127, counter,
                "Counter should be exactly 127, got: " + (counter & 0xFF));

        // One more hit should become 128, not wrap to -128
        engine.hit(99);
        engine.reset();
        snapshot = engine.snapshot();
        counter = snapshot[idx];
        assertEquals((byte)128, counter,
                "Counter should be 128 (0x80), got: " + (counter & 0xFF));
    }

    @Test
    void testCounterSaturatesAt255() {
        LocalCoverageEngine engine = new LocalCoverageEngine(65536);

        // Hit the same edge 255 times — counter should reach 255
        for (int i = 0; i < 255; i++) {
            engine.hit(42);
            engine.reset();
        }

        byte[] snapshot = engine.snapshot();
        int idx = ((42 * LocalCoverageEngine.HASH_CONST) >>> 16) & (65536 - 1);
        byte counter = snapshot[idx];

        assertEquals(-1, counter,
                "Counter should be 255 (0xFF = -1 as signed byte), got: " + (counter & 0xFF));

        // One more hit should stay at 255
        engine.hit(42);
        engine.reset();
        snapshot = engine.snapshot();
        counter = snapshot[idx];
        assertEquals(-1, counter,
                "Counter should stay saturated at 255, got: " + (counter & 0xFF));
    }

    @Test
    void testIndependentCountersPerEdge() {
        LocalCoverageEngine engine = new LocalCoverageEngine(65536);

        // Hit edge 10 one time, edge 20 two times, edge 30 three times
        engine.hit(10);
        engine.reset();

        engine.hit(20);
        engine.reset();
        engine.hit(20);
        engine.reset();

        engine.hit(30);
        engine.reset();
        engine.hit(30);
        engine.reset();
        engine.hit(30);
        engine.reset();

        byte[] snapshot = engine.snapshot();
        int idx10 = ((10 * LocalCoverageEngine.HASH_CONST) >>> 16) & (65536 - 1);
        int idx20 = ((20 * LocalCoverageEngine.HASH_CONST) >>> 16) & (65536 - 1);
        int idx30 = ((30 * LocalCoverageEngine.HASH_CONST) >>> 16) & (65536 - 1);

        assertEquals(1, snapshot[idx10], "Edge 10 should have count 1");
        assertEquals(2, snapshot[idx20], "Edge 20 should have count 2");
        assertEquals(3, snapshot[idx30], "Edge 30 should have count 3");
    }

    @Test
    void testAflCoverageFacade() {
        // Swap in a local engine for testing
        CoverageEngine local = CoverageEngine.createLocal(1024);
        AflCoverage.setEngine(local);

        AflCoverage.hit(1);
        AflCoverage.hit(2);
        AflCoverage.hit(1); // duplicate

        byte[] snapshot = AflCoverage.engine.snapshot();
        int nonZero = 0;
        for (byte b : snapshot) {
            if (b != 0) nonZero++;
        }
        assertTrue(nonZero > 0);

        // Reset and verify it still works
        AflCoverage.reset();
        AflCoverage.hit(3);
    }
}
