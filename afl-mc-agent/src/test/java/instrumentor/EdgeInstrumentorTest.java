/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
package instrumentor;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.InputStream;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class EdgeInstrumentorTest {

    @Test
    void testSmokeTestInstrumentation() throws IOException {
        // Load the original SmokeTest class bytes
        byte[] original = loadClassBytes("test.SmokeTest");
        assertNotNull(original, "Failed to load SmokeTest.class");

        // Instrument
        EdgeInstrumentor instrumentor = new EdgeInstrumentor();
        byte[] instrumented = instrumentor.instrument("test/SmokeTest", original);
        assertNotNull(instrumented);
        assertTrue(instrumented.length > original.length, "Instrumented class should be larger");

        // Inspect probes in the instrumented output
        List<ProbeInspector.ProbeLocation> probes = ProbeInspector.findProbes(instrumented);
        Map<String, List<ProbeInspector.ProbeLocation>> byMethod =
                ProbeInspector.findProbesByMethod(instrumented);

        // SmokeTest has: <init>(), main(String[]), doWork(int)
        // <init> and <clinit> should be skipped
        assertFalse(byMethod.containsKey("<init>()V"),
                "Constructor should not be instrumented");

        // doWork(int) has 4 basic blocks (method entry, true block, else block, merge)
        List<ProbeInspector.ProbeLocation> doWorkProbes = byMethod.get("doWork(I)V");
        assertNotNull(doWorkProbes, "doWork should have probes");
        assertEquals(4, doWorkProbes.size(), "doWork should have 4 basic blocks");

        // main(String[]) has 4 basic blocks (method entry, loop target, loop body, after loop)
        List<ProbeInspector.ProbeLocation> mainProbes = byMethod.get("main([Ljava/lang/String;)V");
        assertNotNull(mainProbes, "main should have probes");
        assertEquals(4, mainProbes.size(), "main should have 4 basic blocks");

        // Verify edge IDs are sequential starting from 0
        List<Integer> sortedIds = probes.stream()
                .map(ProbeInspector.ProbeLocation::edgeId)
                .sorted()
                .toList();
        for (int i = 0; i < sortedIds.size(); i++) {
            assertEquals(i, sortedIds.get(i),
                    "Edge IDs should be sequential starting from 0");
        }

        // Verify total edge count matches instrumentor
        assertEquals(instrumentor.getNextEdgeId(), probes.size(),
                "Instrumentor edge count should match discovered probes");
    }

    @Test
    void testNoInstrumentationForEmptyClass() {
        // A minimal class with no methods (impossible in valid Java, but test edge case)
        // Instead, test that an interface or abstract class with no code doesn't crash
        byte[] tinyClass = createMinimalClassBytes();
        EdgeInstrumentor inst = new EdgeInstrumentor();
        byte[] result = inst.instrument("Tiny", tinyClass);
        assertNotNull(result);
        assertEquals(0, inst.getNextEdgeId(), "No edges for class with no code");
    }

    @Test
    void testConstructorSkipped() throws IOException {
        // Verify that constructors are explicitly skipped
        byte[] original = loadClassBytes("test.SmokeTest");
        EdgeInstrumentor inst = new EdgeInstrumentor();
        byte[] instrumented = inst.instrument("test/SmokeTest", original);

        Map<String, List<ProbeInspector.ProbeLocation>> byMethod =
                ProbeInspector.findProbesByMethod(instrumented);

        assertFalse(byMethod.containsKey("<init>()V"),
                "Constructor must not be instrumented");
    }

    @Test
    void testTryCatchClassLoadsWithoutVerifyError() {
        // A class with try-catch-finally — historically tricky for ASM instrumentation
        byte[] original = createClassWithTryCatch();
        EdgeInstrumentor inst = new EdgeInstrumentor();
        byte[] instrumented = inst.instrument("TryCatchTest", original);

        // The real test: can the JVM load this without VerifyError?
        TestClassLoader loader = new TestClassLoader();
        Class<?> cls = loader.defineClass("TryCatchTest", instrumented);
        assertNotNull(cls);

        // Should have probes in the method
        assertTrue(inst.getNextEdgeId() > 0, "Should have instrumented blocks");
    }

    @Test
    void testSwitchClassLoadsWithoutVerifyError() {
        // A class with a switch statement — generates TABLESWITCH or LOOKUPSWITCH
        byte[] original = createClassWithSwitch();
        EdgeInstrumentor inst = new EdgeInstrumentor();
        byte[] instrumented = inst.instrument("SwitchTest", original);

        TestClassLoader loader = new TestClassLoader();
        Class<?> cls = loader.defineClass("SwitchTest", instrumented);
        assertNotNull(cls);
        assertTrue(inst.getNextEdgeId() > 0, "Should have instrumented blocks");
    }

    @Test
    void testEdgeIdUniquenessAcrossClasses() {
        // Edge IDs should be globally sequential when using the same instrumentor
        EdgeInstrumentor inst = new EdgeInstrumentor();

        byte[] dummy1 = createMinimalClassWithOneMethod();
        byte[] dummy2 = createMinimalClassWithOneMethod();

        inst.instrument("Dummy1", dummy1);
        int afterFirst = inst.getNextEdgeId();

        inst.instrument("Dummy2", dummy2);
        int afterSecond = inst.getNextEdgeId();

        assertTrue(afterSecond > afterFirst,
                "Edge IDs should increment across classes");
    }

    // --- Test helpers ---

    private byte[] loadClassBytes(String className) throws IOException {
        String path = className.replace('.', '/') + ".class";
        try (InputStream is = getClass().getClassLoader().getResourceAsStream(path)) {
            if (is == null) {
                return null;
            }
            return is.readAllBytes();
        }
    }

    private byte[] createMinimalClassBytes() {
        // A minimal valid class: public class Tiny { }
        org.objectweb.asm.ClassWriter cw = new org.objectweb.asm.ClassWriter(0);
        cw.visit(org.objectweb.asm.Opcodes.V21, org.objectweb.asm.Opcodes.ACC_PUBLIC,
                "Tiny", null, "java/lang/Object", null);
        cw.visitEnd();
        return cw.toByteArray();
    }

    private byte[] createMinimalClassWithOneMethod() {
        org.objectweb.asm.ClassWriter cw = new org.objectweb.asm.ClassWriter(0);
        cw.visit(org.objectweb.asm.Opcodes.V21, org.objectweb.asm.Opcodes.ACC_PUBLIC,
                "Dummy", null, "java/lang/Object", null);

        org.objectweb.asm.MethodVisitor mv = cw.visitMethod(
                org.objectweb.asm.Opcodes.ACC_PUBLIC, "foo", "()V", null, null);
        mv.visitCode();
        mv.visitInsn(org.objectweb.asm.Opcodes.RETURN);
        mv.visitMaxs(0, 1);
        mv.visitEnd();

        cw.visitEnd();
        return cw.toByteArray();
    }

    private byte[] createClassWithTryCatch() {
        org.objectweb.asm.ClassWriter cw = new org.objectweb.asm.ClassWriter(0);
        cw.visit(org.objectweb.asm.Opcodes.V21, org.objectweb.asm.Opcodes.ACC_PUBLIC,
                "TryCatchTest", null, "java/lang/Object", null);

        org.objectweb.asm.MethodVisitor mv = cw.visitMethod(
                org.objectweb.asm.Opcodes.ACC_PUBLIC + org.objectweb.asm.Opcodes.ACC_STATIC,
                "main", "([Ljava/lang/String;)V", null,
                new String[]{"java/lang/Exception"});
        mv.visitCode();

        org.objectweb.asm.Label tryStart = new org.objectweb.asm.Label();
        org.objectweb.asm.Label tryEnd = new org.objectweb.asm.Label();
        org.objectweb.asm.Label catchBlock = new org.objectweb.asm.Label();
        org.objectweb.asm.Label done = new org.objectweb.asm.Label();

        mv.visitTryCatchBlock(tryStart, tryEnd, catchBlock, "java/lang/RuntimeException");

        mv.visitLabel(tryStart);
        mv.visitFieldInsn(org.objectweb.asm.Opcodes.GETSTATIC, "java/lang/System", "out", "Ljava/io/PrintStream;");
        mv.visitLdcInsn("try");
        mv.visitMethodInsn(org.objectweb.asm.Opcodes.INVOKEVIRTUAL, "java/io/PrintStream", "println", "(Ljava/lang/String;)V", false);
        mv.visitLabel(tryEnd);
        mv.visitJumpInsn(org.objectweb.asm.Opcodes.GOTO, done);

        mv.visitLabel(catchBlock);
        mv.visitFrame(org.objectweb.asm.Opcodes.F_SAME1, 0, null, 1, new Object[]{"java/lang/RuntimeException"});
        mv.visitFieldInsn(org.objectweb.asm.Opcodes.GETSTATIC, "java/lang/System", "out", "Ljava/io/PrintStream;");
        mv.visitLdcInsn("catch");
        mv.visitMethodInsn(org.objectweb.asm.Opcodes.INVOKEVIRTUAL, "java/io/PrintStream", "println", "(Ljava/lang/String;)V", false);

        mv.visitLabel(done);
        mv.visitFrame(org.objectweb.asm.Opcodes.F_SAME, 0, null, 0, null);
        mv.visitInsn(org.objectweb.asm.Opcodes.RETURN);
        mv.visitMaxs(2, 1);
        mv.visitEnd();

        cw.visitEnd();
        return cw.toByteArray();
    }

    private byte[] createClassWithSwitch() {
        org.objectweb.asm.ClassWriter cw = new org.objectweb.asm.ClassWriter(0);
        cw.visit(org.objectweb.asm.Opcodes.V21, org.objectweb.asm.Opcodes.ACC_PUBLIC,
                "SwitchTest", null, "java/lang/Object", null);

        org.objectweb.asm.MethodVisitor mv = cw.visitMethod(
                org.objectweb.asm.Opcodes.ACC_PUBLIC + org.objectweb.asm.Opcodes.ACC_STATIC,
                "pick", "(I)I", null, null);
        mv.visitCode();

        org.objectweb.asm.Label case0 = new org.objectweb.asm.Label();
        org.objectweb.asm.Label case1 = new org.objectweb.asm.Label();
        org.objectweb.asm.Label case2 = new org.objectweb.asm.Label();
        org.objectweb.asm.Label defaultLabel = new org.objectweb.asm.Label();
        org.objectweb.asm.Label done = new org.objectweb.asm.Label();

        mv.visitVarInsn(org.objectweb.asm.Opcodes.ILOAD, 0);
        mv.visitTableSwitchInsn(0, 2, defaultLabel, case0, case1, case2);

        mv.visitLabel(case0);
        mv.visitFrame(org.objectweb.asm.Opcodes.F_SAME, 0, null, 0, null);
        mv.visitInsn(org.objectweb.asm.Opcodes.ICONST_0);
        mv.visitJumpInsn(org.objectweb.asm.Opcodes.GOTO, done);

        mv.visitLabel(case1);
        mv.visitFrame(org.objectweb.asm.Opcodes.F_SAME, 0, null, 0, null);
        mv.visitInsn(org.objectweb.asm.Opcodes.ICONST_1);
        mv.visitJumpInsn(org.objectweb.asm.Opcodes.GOTO, done);

        mv.visitLabel(case2);
        mv.visitFrame(org.objectweb.asm.Opcodes.F_SAME, 0, null, 0, null);
        mv.visitInsn(org.objectweb.asm.Opcodes.ICONST_2);
        mv.visitJumpInsn(org.objectweb.asm.Opcodes.GOTO, done);

        mv.visitLabel(defaultLabel);
        mv.visitFrame(org.objectweb.asm.Opcodes.F_SAME, 0, null, 0, null);
        mv.visitInsn(org.objectweb.asm.Opcodes.ICONST_M1);

        mv.visitLabel(done);
        mv.visitFrame(org.objectweb.asm.Opcodes.F_SAME, 0, null, 0, null);
        mv.visitInsn(org.objectweb.asm.Opcodes.IRETURN);
        mv.visitMaxs(1, 1);
        mv.visitEnd();

        cw.visitEnd();
        return cw.toByteArray();
    }

    static class TestClassLoader extends ClassLoader {
        Class<?> defineClass(String name, byte[] b) {
            return defineClass(name, b, 0, b.length);
        }
    }
}
