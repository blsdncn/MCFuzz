/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Test utility that inspects instrumented bytecode to verify probe placement.
 *
 * <p>Scans a {@code .class} file for calls to {@code AflCoverage.hit(int)} and
 * reports where they were found. This is a second-pass ASM visitor — it does
 * not instrument, it only reads.
 */
package instrumentor;

import org.objectweb.asm.*;

import java.util.*;

/**
 * Inspects instrumented class files and extracts probe metadata.
 */
public final class ProbeInspector {

    private ProbeInspector() {}

    /**
     * Scan instrumented bytecode and return all probes found.
     *
     * @param classBytes instrumented class file bytes
     * @return list of probes, sorted by edge ID
     */
    public static List<ProbeLocation> findProbes(byte[] classBytes) {
        ClassReader cr = new ClassReader(classBytes);
        ProbeCollector collector = new ProbeCollector();
        cr.accept(collector, 0);
        return collector.probes;
    }

    /**
     * Scan instrumented bytecode and return probes grouped by method.
     *
     * @param classBytes instrumented class file bytes
     * @return map from "methodName+descriptor" to list of probes in that method
     */
    public static Map<String, List<ProbeLocation>> findProbesByMethod(byte[] classBytes) {
        List<ProbeLocation> probes = findProbes(classBytes);
        Map<String, List<ProbeLocation>> byMethod = new LinkedHashMap<>();
        for (ProbeLocation p : probes) {
            byMethod.computeIfAbsent(p.methodName() + p.methodDesc(), k -> new ArrayList<>()).add(p);
        }
        return byMethod;
    }

    public record ProbeLocation(
            String className,
            String methodName,
            String methodDesc,
            int edgeId,
            int bytecodeOffset
    ) {}

    private static final class ProbeCollector extends ClassVisitor {
        final List<ProbeLocation> probes = new ArrayList<>();
        String currentClass;
        String currentMethod;
        String currentDesc;

        ProbeCollector() {
            super(Opcodes.ASM9);
        }

        @Override
        public void visit(int version, int access, String name, String signature,
                          String superName, String[] interfaces) {
            this.currentClass = name;
        }

        @Override
        public MethodVisitor visitMethod(int access, String name, String descriptor,
                                         String signature, String[] exceptions) {
            this.currentMethod = name;
            this.currentDesc = descriptor;
            return new MethodVisitor(Opcodes.ASM9) {
                private int lastLdcValue = -1;
                private int bytecodeOffset = 0;

                @Override
                public void visitFrame(int type, int numLocal, Object[] local,
                                       int numStack, Object[] stack) {
                    // Frames don't consume opcode space in our counting
                }

                @Override
                public void visitInsn(int opcode) {
                    bytecodeOffset++;
                    lastLdcValue = -1; // reset — LDC value only valid before INVOKESTATIC
                }

                @Override
                public void visitIntInsn(int opcode, int operand) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitVarInsn(int opcode, int varIndex) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitTypeInsn(int opcode, String type) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitFieldInsn(int opcode, String owner, String name, String descriptor) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitMethodInsn(int opcode, String owner, String name,
                                            String descriptor, boolean isInterface) {
                    if ("afl/AflCoverage".equals(owner) && "hit".equals(name)
                            && "(I)V".equals(descriptor)) {
                        if (lastLdcValue != -1) {
                            probes.add(new ProbeLocation(
                                    currentClass,
                                    currentMethod,
                                    currentDesc,
                                    lastLdcValue,
                                    bytecodeOffset
                            ));
                        }
                    }
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitInvokeDynamicInsn(String name, String descriptor,
                                                   Handle bootstrapMethodHandle,
                                                   Object... bootstrapMethodArguments) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitJumpInsn(int opcode, Label label) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitLdcInsn(Object value) {
                    if (value instanceof Integer) {
                        lastLdcValue = (Integer) value;
                    } else {
                        lastLdcValue = -1;
                    }
                    bytecodeOffset++;
                }

                @Override
                public void visitIincInsn(int varIndex, int increment) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitTableSwitchInsn(int min, int max, Label dflt, Label... labels) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitLookupSwitchInsn(Label dflt, int[] keys, Label[] labels) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitMultiANewArrayInsn(String descriptor, int numDimensions) {
                    bytecodeOffset++;
                    lastLdcValue = -1;
                }

                @Override
                public void visitLabel(Label label) {
                    // Labels are metadata, not real instructions
                }

                @Override
                public void visitLineNumber(int line, Label start) {
                    // Line numbers are metadata
                }
            };
        }
    }
}
