/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * ASM-based edge coverage instrumentor.
 *
 * <p>Identifies basic blocks in each method using ASM's {@link Analyzer},
 * then inserts {@code AflCoverage.hit(edgeId)} at the start of each block.
 * The edge ID is a globally-unique sequential integer.
 *
 * <p>This is a simplified replacement for Jazzer's EdgeCoverageInstrumentor
 * that does not require patched JaCoCo internals.
 */
package instrumentor;

import afl.AflCoverage;
import org.objectweb.asm.*;
import org.objectweb.asm.tree.*;
import org.objectweb.asm.tree.analysis.*;

import java.util.*;

/**
 * Instruments Java bytecode for AFL-style edge coverage.
 *
 * <p>Usage:
 * <pre>{@code
 *   EdgeInstrumentor inst = new EdgeInstrumentor();
 *   byte[] instrumented = inst.instrument("com/example/MyClass", originalBytes);
 *   int edgesAdded = inst.getNextEdgeId(); // total edges instrumented
 * }</pre>
 */
public final class EdgeInstrumentor {

    private int nextEdgeId;

    public EdgeInstrumentor(int initialEdgeId) {
        this.nextEdgeId = initialEdgeId;
    }

    public EdgeInstrumentor() {
        this(0);
    }

    /**
     * Instrument the given class file for edge coverage.
     *
     * @param internalClassName class name in internal form (e.g. {@code com/example/MyClass})
     * @param bytecode original class file bytes
     * @return instrumented class file bytes
     */
    public byte[] instrument(String internalClassName, byte[] bytecode) {
        ClassReader cr = new ClassReader(bytecode);
        ClassNode cn = new ClassNode(Opcodes.ASM9);
        cr.accept(cn, ClassReader.EXPAND_FRAMES);

        for (MethodNode mn : cn.methods) {
            instrumentMethod(internalClassName, mn);
        }

        try {
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_FRAMES);
            cn.accept(cw);
            return cw.toByteArray();
        } catch (ArrayIndexOutOfBoundsException e) {
            // Some synthetic or hand-crafted classes can defeat ASM's frame recomputation.
            // Fall back to preserving existing frames and recomputing only max stack/locals.
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
            cn.accept(cw);
            return cw.toByteArray();
        }
    }

    private void instrumentMethod(String className, MethodNode mn) {
        if (mn.instructions == null || mn.instructions.size() == 0) {
            return; // abstract or native method
        }

        // Find basic block starts using ASM Analyzer
        Set<AbstractInsnNode> blockStarts = findBlockStarts(className, mn);
        if (blockStarts.isEmpty()) {
            return;
        }

        boolean isConstructor = "<init>".equals(mn.name);
        boolean isStaticInit = "<clinit>".equals(mn.name);
        if (isConstructor || isStaticInit) {
            return; // Skip constructors and static initializers for now
        }

        // Insert AflCoverage.hit(edgeId) at each block start
        AbstractInsnNode[] insns = mn.instructions.toArray();
        int inserted = 0;
        int insIdx = 0;
        for (AbstractInsnNode insn : insns) {
            if (blockStarts.contains(insn)) {
                // Skip inserting before super()/this() in constructors
                if (isConstructor && isBeforeSuperCall(insn)) {
                    continue;
                }

                // Find the next real (executable) instruction to insert before.
                // Labels, frames, and line numbers don't generate bytecode.
                // Inserting before them can place probes in unreachable padding
                // inserted by ClassWriter.COMPUTE_FRAMES.
                AbstractInsnNode target = insn;
                while (target != null && isMetadataNode(target)) {
                    target = target.getNext();
                }
                if (target == null) {
                    continue; // no executable instruction after this block start
                }

                int edgeId = nextEdgeId++;
                InsnList probe = new InsnList();
                probe.add(new LdcInsnNode(edgeId));
                probe.add(new MethodInsnNode(
                        Opcodes.INVOKESTATIC,
                        "afl/AflCoverage",
                        "hit",
                        "(I)V",
                        false
                ));
                mn.instructions.insertBefore(target, probe);
                inserted++;
            }
            insIdx++;
        }

        mn.maxStack = Math.max(mn.maxStack + 1, 1);
    }

    /**
     * Check if this instruction is before the super() or this() call in a constructor.
     * In constructors, the first real instruction must be aload_0 followed by
     * invokespecial to the superclass or another constructor.
     */
    private boolean isBeforeSuperCall(AbstractInsnNode insn) {
        // Check if this is aload_0
        if (insn.getOpcode() != Opcodes.ALOAD || !(insn instanceof VarInsnNode) || ((VarInsnNode) insn).var != 0) {
            return false;
        }
        // Check if next instruction is invokespecial
        AbstractInsnNode next = insn.getNext();
        if (next instanceof MethodInsnNode) {
            MethodInsnNode minsn = (MethodInsnNode) next;
            return minsn.getOpcode() == Opcodes.INVOKESPECIAL && "<init>".equals(minsn.name);
        }
        return false;
    }

    /**
     * Find all basic block starts in a method.
     *
     * <p>A basic block starts at:
     * <ul>
     *   <li>Method entry</li>
     *   <li>A label that is the target of a jump instruction</li>
     *   <li>The instruction immediately after a conditional branch</li>
     *   <li>The instruction immediately after a return/throw</li>
     *   <li>A catch handler label</li>
     * </ul>
     */
    private Set<AbstractInsnNode> findBlockStarts(String className, MethodNode mn) {
        Set<AbstractInsnNode> starts = new LinkedHashSet<>();
        Set<LabelNode> jumpTargets = new HashSet<>();

        // First pass: collect all jump targets
        for (AbstractInsnNode insn : mn.instructions) {
            if (insn instanceof JumpInsnNode) {
                jumpTargets.add(((JumpInsnNode) insn).label);
            } else if (insn instanceof TableSwitchInsnNode) {
                TableSwitchInsnNode ts = (TableSwitchInsnNode) insn;
                jumpTargets.add(ts.dflt);
                jumpTargets.addAll(ts.labels);
            } else if (insn instanceof LookupSwitchInsnNode) {
                LookupSwitchInsnNode ls = (LookupSwitchInsnNode) insn;
                jumpTargets.add(ls.dflt);
                jumpTargets.addAll(ls.labels);
            }
        }

        // Also collect catch handler labels
        if (mn.tryCatchBlocks != null) {
            for (TryCatchBlockNode tcb : mn.tryCatchBlocks) {
                jumpTargets.add(tcb.handler);
            }
        }

        // Second pass: identify block starts
        boolean prevWasBranch = true; // method entry is a block start
        for (AbstractInsnNode insn : mn.instructions) {
            if (prevWasBranch) {
                starts.add(insn);
                prevWasBranch = false;
            }

            if (insn instanceof LabelNode && jumpTargets.contains(insn)) {
                starts.add(insn);
            }

            int opcode = insn.getOpcode();
            if (opcode >= Opcodes.IRETURN && opcode <= Opcodes.RETURN) {
                prevWasBranch = true;
            } else if (opcode == Opcodes.ATHROW) {
                prevWasBranch = true;
            } else if (insn instanceof JumpInsnNode) {
                if (opcode == Opcodes.GOTO) {
                    prevWasBranch = true;
                } else {
                    // Conditional branch: fall-through continues, target is block start
                    prevWasBranch = true;
                }
            } else if (insn instanceof TableSwitchInsnNode || insn instanceof LookupSwitchInsnNode) {
                prevWasBranch = true;
            }
        }

        return starts;
    }

    private boolean isMetadataNode(AbstractInsnNode node) {
        return node instanceof LabelNode
            || node instanceof FrameNode
            || node instanceof LineNumberNode;
    }

    public int getNextEdgeId() {
        return nextEdgeId;
    }
}
