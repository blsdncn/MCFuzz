/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
package agent;

import instrumentor.EdgeInstrumentor;

import java.lang.instrument.ClassFileTransformer;
import java.security.ProtectionDomain;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * ClassFileTransformer that instruments matching classes for AFL edge coverage.
 *
 * <p>Uses glob-style include/exclude patterns to decide which classes to instrument.
 * Only classes whose internal name matches an include pattern (and no exclude pattern)
 * are rewritten.
 */
public final class AflClassTransformer implements ClassFileTransformer {

    private final String[] includePatterns;
    private final String[] excludePatterns;
    private final EdgeInstrumentor instrumentor;
    private final AtomicInteger classCount = new AtomicInteger(0);
    private final AtomicInteger edgeCount = new AtomicInteger(0);

    public AflClassTransformer(String[] includePatterns, String[] excludePatterns) {
        this.includePatterns = includePatterns != null ? includePatterns : new String[0];
        this.excludePatterns = excludePatterns != null ? excludePatterns : new String[0];
        this.instrumentor = new EdgeInstrumentor();
    }

    @Override
    public byte[] transform(ClassLoader loader,
                            String internalClassName,
                            Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain,
                            byte[] classfileBuffer) {
        // Never instrument ourselves
        if (internalClassName != null && internalClassName.startsWith("afl/")) {
            return null;
        }
        if (internalClassName != null && internalClassName.startsWith("agent/")) {
            return null;
        }
        if (internalClassName != null && internalClassName.startsWith("instrumentor/")) {
            return null;
        }

        if (!shouldInstrument(internalClassName)) {
            return null;
        }

        try {
            int edgesBefore = instrumentor.getNextEdgeId();
            byte[] instrumented = instrumentor.instrument(internalClassName, classfileBuffer);
            int edgesAfter = instrumentor.getNextEdgeId();
            int newEdges = edgesAfter - edgesBefore;

            classCount.incrementAndGet();
            edgeCount.addAndGet(newEdges);

            System.out.println("[afl-mc-agent] Instrumented " + internalClassName.replace('/', '.')
                    + " (" + newEdges + " edges, total " + edgesAfter + ")");

            return instrumented;
        } catch (Exception e) {
            System.err.println("[afl-mc-agent] Failed to instrument " + internalClassName + ": " + e.getMessage());
            e.printStackTrace();
            return null; // return original on failure
        }
    }

    /**
     * Check if a class should be instrumented based on include/exclude patterns.
     */
    public boolean shouldInstrument(String internalClassName) {
        if (internalClassName == null) {
            return false;
        }
        String dotted = internalClassName.replace('/', '.');

        // Check excludes first
        for (String pattern : excludePatterns) {
            if (matchesGlob(dotted, pattern)) {
                return false;
            }
        }

        // Check includes
        for (String pattern : includePatterns) {
            if (matchesGlob(dotted, pattern)) {
                return true;
            }
        }

        // No include matched → don't instrument
        return false;
    }

    /**
     * Simple glob matching: {@code *} matches any sequence of characters.
     */
    static boolean matchesGlob(String text, String pattern) {
        if (pattern.equals("*")) {
            return true;
        }
        if (pattern.endsWith(".*")) {
            String prefix = pattern.substring(0, pattern.length() - 1);
            return text.startsWith(prefix);
        }
        if (pattern.endsWith("**")) {
            String prefix = pattern.substring(0, pattern.length() - 2);
            return text.startsWith(prefix);
        }
        return text.equals(pattern);
    }

    public int getClassCount() {
        return classCount.get();
    }

    public int getEdgeCount() {
        return edgeCount.get();
    }
}
