/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Java agent entry point. Instruments Velocity classes for AFL-style
 * edge coverage.
 */
package agent;

import afl.AflCoverage;

import java.lang.instrument.Instrumentation;

/**
 * Premain entry point for the AFL Minecraft coverage agent.
 *
 * <p>Usage:
 * <pre>{@code
 *   java -javaagent:afl-mc-agent.jar \
 *        -jar velocity.jar
 * }</pre>
 *
 * <p>System properties:
 * <ul>
 *   <li>{@code afl.include} — comma-separated class name patterns to instrument (default: {@code com.velocitypowered.*})</li>
 *   <li>{@code afl.exclude} — comma-separated class name patterns to skip (default: empty)</li>
 * </ul>
 */
public final class AflMcAgent {

    private AflMcAgent() {}

    public static void premain(String agentArgs, Instrumentation inst) {
        System.out.println("[afl-mc-agent] Starting AFL Minecraft coverage agent");

        // Read configuration from system properties
        String includeProp = System.getProperty("afl.include", "com.velocitypowered.*");
        String excludeProp = System.getProperty("afl.exclude", "");

        String[] includes = splitCommas(includeProp);
        String[] excludes = splitCommas(excludeProp);

        System.out.println("[afl-mc-agent] Include patterns: " + String.join(", ", includes));
        if (excludes.length > 0) {
            System.out.println("[afl-mc-agent] Exclude patterns: " + String.join(", ", excludes));
        }

        // Print which engine we attached to
        System.out.println("[afl-mc-agent] Engine: " + AflCoverage.getEngine().getClass().getSimpleName());

        // Create and register the transformer
        AflClassTransformer transformer = new AflClassTransformer(includes, excludes);
        inst.addTransformer(transformer, true);

        // Retransform already-loaded classes that match
        if (inst.isRetransformClassesSupported()) {
            int retransformCount = 0;
            for (Class<?> cls : inst.getAllLoadedClasses()) {
                if (cls.getName() != null && transformer.shouldInstrument(cls.getName().replace('.', '/'))) {
                    try {
                        inst.retransformClasses(cls);
                        retransformCount++;
                    } catch (Exception e) {
                        System.err.println("[afl-mc-agent] Failed to retransform " + cls.getName() + ": " + e.getMessage());
                    }
                }
            }
            if (retransformCount > 0) {
                System.out.println("[afl-mc-agent] Retransformed " + retransformCount + " already-loaded classes");
            }
        }

        // Shutdown hook to print stats
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("[afl-mc-agent] Shutdown: instrumented " + transformer.getClassCount()
                    + " classes, " + transformer.getEdgeCount() + " total edges");
        }));

        System.out.println("[afl-mc-agent] Agent ready");
    }

    private static String[] splitCommas(String s) {
        if (s == null || s.trim().isEmpty()) {
            return new String[0];
        }
        String[] parts = s.split(",");
        for (int i = 0; i < parts.length; i++) {
            parts[i] = parts[i].trim();
        }
        return parts;
    }
}
