/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
package afl;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

/**
 * Optional javaagent-owned edge metrics artifact.
 *
 * <p>This is source-isolated from AFLNet's aggregate bitmap artifacts: it records only calls that
 * pass through {@link AflCoverage#hit(int)}. It is disabled unless {@code afl.edgeMetricsFile} is
 * set, so it does not affect the normal fuzzing hot path unless explicitly requested.
 */
final class EdgeMetrics {

    private static final int MAP_SIZE = ShmCoverageEngine.MAP_SIZE;
    private static final int HASH_CONST = ShmCoverageEngine.HASH_CONST;

    private final Path outputFile;
    private final byte[] bitmap;
    private final ThreadLocal<Integer> prevLoc;
    private long hitCount;

    private EdgeMetrics(Path outputFile) {
        this.outputFile = outputFile;
        this.bitmap = new byte[MAP_SIZE];
        this.prevLoc = ThreadLocal.withInitial(() -> 0);
    }

    static EdgeMetrics createFromSystemProperties() {
        String path = System.getProperty("afl.edgeMetricsFile", "").trim();
        if (path.isEmpty()) {
            return null;
        }
        EdgeMetrics metrics = new EdgeMetrics(Path.of(path));
        metrics.startPeriodicWriter();
        Runtime.getRuntime().addShutdownHook(new Thread(metrics::writeQuietly, "afl-edge-metrics-writer"));
        return metrics;
    }

    synchronized void hit(int edgeId) {
        int curLoc = (edgeId * HASH_CONST) >>> 16;
        int prev = prevLoc.get();
        int idx = (curLoc ^ prev) & (MAP_SIZE - 1);

        int unsigned = bitmap[idx] & 0xFF;
        if (unsigned < 0xFF) {
            bitmap[idx] = (byte) (unsigned + 1);
        }
        hitCount++;
        prevLoc.set(curLoc >>> 1);
    }

    void reset() {
        prevLoc.set(0);
    }

    private void startPeriodicWriter() {
        Thread writer = new Thread(() -> {
            while (true) {
                try {
                    Thread.sleep(1000);
                    writeQuietly();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }, "afl-edge-metrics-periodic-writer");
        writer.setDaemon(true);
        writer.start();
    }

    private synchronized void writeQuietly() {
        try {
            write();
        } catch (IOException e) {
            System.err.println("[afl-mc-agent] Failed to write edge metrics: " + e.getMessage());
        }
    }

    private void write() throws IOException {
        Path parent = outputFile.getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }

        int nonzero = 0;
        for (byte cell : bitmap) {
            if (cell != 0) {
                nonzero++;
            }
        }
        double density = (nonzero * 100.0) / MAP_SIZE;

        String content = "edge_coverage_metric_status=available\n"
                + "edge_coverage_metric_source=javaagent-edge-metrics\n"
                + "edge_coverage_total_cells=" + MAP_SIZE + "\n"
                + "edge_coverage_nonzero_cells=" + nonzero + "\n"
                + "edge_coverage_hit_count=" + hitCount + "\n"
                + "edge_coverage_density_percent=" + String.format(Locale.ROOT, "%.4f", density) + "\n";
        Files.writeString(outputFile, content, StandardCharsets.UTF_8);
    }
}
